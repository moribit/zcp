#!/usr/bin/env python3
"""Authorized peer benchmark. Temporary binary, random file, dedicated receiver.
No SSH/firewall configuration is changed. Uses the current SSH configuration.
"""
import argparse,csv,hashlib,os,pathlib,random,re,resource,selectors,shlex,socket,subprocess,time
from benchmark import ROOT,fixture

def main():
    a=argparse.ArgumentParser();a.add_argument("--host",required=True);a.add_argument("--address",required=True)
    a.add_argument("--binary",type=pathlib.Path,default=ROOT/"zig-out/bin/zcp");a.add_argument("--peer-binary",type=pathlib.Path,default=ROOT/"zig-out/linux/bin/zcp")
    a.add_argument("--file",type=pathlib.Path,default=ROOT/".bench/remote-input.bin");a.add_argument("--size-mib",type=int,default=512)
    a.add_argument("--repeats",type=int,default=3);a.add_argument("--suite",choices=["smoke","all","peer-test","case"],default="all");a.add_argument("--csv",type=pathlib.Path,default=ROOT/"benchmarks/remote.csv")
    a.add_argument("--transfer-timeout",type=int,default=60)
    a.add_argument("--continue-on-error",action="store_true")
    a.add_argument("--max-connections",type=int,default=8);a.add_argument("--case-connections",type=int,default=1);a.add_argument("--case-integrity",choices=["off","on"],default="off");a.add_argument("--case-backend",choices=["generic","zero-copy"],default="generic")
    a.add_argument("--port",type=int,default=19090);a.add_argument("--build-mode",default="ReleaseSafe");o=a.parse_args()
    ssh=["ssh","-o","BatchMode=yes","-o","ConnectTimeout=10",o.host]
    def command(args,**kw):return subprocess.run(ssh+[shlex.join(args)],check=True,capture_output=True,text=True,timeout=60,**kw)
    work=command(["mktemp","-d","/tmp/zcp-bench.XXXXXXXX"]).stdout.strip()
    if not re.fullmatch(r"/tmp/zcp-bench\.[A-Za-z0-9]+",work):raise RuntimeError("unexpected temporary path")
    receiver=None;pid=None
    try:
        subprocess.run(["scp","-o","BatchMode=yes",str(o.peer_binary.resolve()),f"{o.host}:{work}/zcp"],check=True,timeout=60)
        command(["chmod","700",work+"/zcp"])
        if o.suite=="peer-test":
            subprocess.run(["scp","-o","BatchMode=yes",str(ROOT/"tests/integration.py"),f"{o.host}:{work}/integration.py"],check=True,timeout=60)
            checked=command(["env","ZCP_BINARY="+work+"/zcp","python3",work+"/integration.py"])
            print(checked.stdout+checked.stderr,flush=True)
            return
        o.file.parent.mkdir(parents=True,exist_ok=True);fixture(o.file,o.size_mib*1048576)
        with o.file.open("rb") as input_file: sourcehash=hashlib.file_digest(input_file,"sha256").hexdigest()
        cases=[("generic",1048576,1,1,"off")]
        if o.suite=="all":
            cases=[("generic",1048576,1,1,"off"),("generic",1048576,1,1,"on"),("generic",4194304,1,1,"off"),("generic",4194304,4,1,"off"),("generic",1048576,4,1,"on"),("zero-copy",4194304,1,1,"off")]
            cases += [("generic",1048576,1,c,i) for c in (2,4,8) if c<=o.max_connections for i in ("off","on")]
        if o.suite=="case":cases=[(o.case_backend,1048576,1,o.case_connections,o.case_integrity)]
        else:cases.append(("scp",0,0,1,"ssh"))
        rng=random.Random(20261005);schedule=[]
        for repeat in range(o.repeats):
            ordered=cases.copy();rng.shuffle(ordered);schedule += [(repeat+1,case) for case in ordered]
        o.csv.parent.mkdir(parents=True,exist_ok=True)
        with o.csv.open("w",newline="") as f:
            fields="repeat,environment,build_mode,file_size,elapsed_s,wall_s,MB_s,MiB_s,buffer_size,buffer_count,connections,backend,integrity,sender_user_s,sender_system_s,sha256_verified,status,error".split(",")
            writer=csv.DictWriter(f,fields);writer.writeheader()
            for repeat,(backend,size,buffers,connections,integrity) in schedule:
                print(f"starting repeat{repeat} {backend} size={size} buffers={buffers} connections={connections} integrity={integrity}",flush=True)
                try:
                    dest=work+"/"+o.file.name;cpu=resource.getrusage(resource.RUSAGE_CHILDREN)
                    if backend=="scp":
                        before=time.perf_counter();result=subprocess.run(["scp","-o","BatchMode=yes","-o","Compression=no",str(o.file.resolve()),f"{o.host}:{dest}"],capture_output=True,text=True,timeout=o.transfer_timeout)
                        if result.returncode:raise RuntimeError(result.stderr)
                        command(["python3","-c","import os,sys;f=open(sys.argv[1],'rb');os.fsync(f.fileno())",dest])
                        wall=time.perf_counter()-before;seconds=wall;after=resource.getrusage(resource.RUSAGE_CHILDREN)
                    else:
                        remote="echo ZCP_PID=$$ >&2; exec "+shlex.join([work+"/zcp","receive","--port",str(o.port),"--bind","0.0.0.0" if ":" not in o.address else "::","--output",work,"--once"])
                        receiver=subprocess.Popen(ssh+[remote],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                        sel=selectors.DefaultSelector();sel.register(receiver.stderr,selectors.EVENT_READ);ready=False;startup=[];deadline=time.monotonic()+15
                        while time.monotonic()<deadline:
                            if not sel.select(1):continue
                            raw=os.read(receiver.stderr.fileno(),4096)
                            if not raw:break
                            startup.append(raw.decode())
                            accumulated="".join(startup)
                            match=re.search(r"ZCP_PID=(\d+)",accumulated)
                            if match:pid=int(match[1])
                            if "Listening:" in accumulated:ready=True;break
                        sel.close()
                        if not ready:raise RuntimeError("receiver startup failed: "+"".join(startup))
                        endpoint=f"[{o.address}]:{o.port}" if ":" in o.address else f"{o.address}:{o.port}"
                        before=time.perf_counter();result=subprocess.run([str(o.binary.resolve()),"send","--buffer-size",str(size),"--buffers",str(buffers),"--connections",str(connections),"--io",backend,"--integrity",integrity,endpoint,str(o.file.resolve())],capture_output=True,text=True,timeout=o.transfer_timeout)
                        wall=time.perf_counter()-before;after=resource.getrusage(resource.RUSAGE_CHILDREN)
                        _,errors=receiver.communicate(timeout=30);pid=None
                        if result.returncode:raise RuntimeError(result.stderr+errors)
                        if receiver.returncode:raise RuntimeError(errors)
                        seconds=float(re.search(r"Elapsed:\s+([0-9.]+)",result.stderr)[1])
                    actual=command(["sha256sum",dest]).stdout.split()[0]
                    if actual!=sourcehash:raise RuntimeError("SHA256 mismatch")
                    command(["python3","-c","import os,sys;os.unlink(sys.argv[1])",dest])
                    n=o.file.stat().st_size
                    writer.writerow(dict(zip(fields,[repeat,"remote-"+o.address,o.build_mode,n,seconds,wall,n/seconds/1e6,n/seconds/1048576,size,buffers,connections,backend,integrity,after.ru_utime-cpu.ru_utime,after.ru_stime-cpu.ru_stime,True,"ok",""])));f.flush()
                    print(f"repeat{repeat} {backend} {size//1024}KiB x{buffers} c{connections} {integrity}: {n/seconds/1e6:.2f} MB/s (SHA256 OK)",flush=True)
                except Exception as err:
                    if pid is not None:
                        try:command(["kill","--",str(pid)])
                        except Exception:pass
                        pid=None
                    if receiver is not None and receiver.poll() is None:
                        receiver.terminate()
                        try:receiver.communicate(timeout=5)
                        except subprocess.TimeoutExpired:receiver.kill();receiver.communicate()
                    command(["python3","-c","import os,sys;p=sys.argv[1];os.unlink(p) if os.path.exists(p) else None",work+"/"+o.file.name])
                    writer.writerow({"repeat":repeat,"environment":"remote-"+o.address,"build_mode":o.build_mode,"file_size":o.file.stat().st_size,"buffer_size":size,"buffer_count":buffers,"connections":connections,"backend":backend,"integrity":integrity,"sha256_verified":False,"status":"failed","error":str(err)})
                    f.flush();print("FAILED: "+str(err).splitlines()[0],flush=True)
                    if not o.continue_on_error:raise

    finally:
        if pid is not None:
            try:command(["kill","--",str(pid)])
            except Exception:pass
        if receiver is not None and receiver.poll() is None:
            receiver.terminate()
            try:receiver.communicate(timeout=5)
            except subprocess.TimeoutExpired:receiver.kill();receiver.communicate()
        command(["python3","-c","import shutil,sys;shutil.rmtree(sys.argv[1])",work])
if __name__=="__main__":main()

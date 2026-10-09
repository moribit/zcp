#!/usr/bin/env python3
"""Repeatable real-file benchmarks; loopback results are not LAN throughput."""
import argparse, csv, os, pathlib, random, re, resource, socket, subprocess, tempfile, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
def port():
    with socket.socket() as s: s.bind(("127.0.0.1",0)); return s.getsockname()[1]
def fixture(path, size):
    if path.exists():
        if not path.is_file(): raise ValueError("fixture must be a regular file")
        return
    with path.open("wb") as f:
        left = size
        while left:
            block = os.urandom(min(left,4*1024*1024)); f.write(block); left -= len(block)
def local_run(binary, source, flags):
    with tempfile.TemporaryDirectory(prefix="zcp-bench-") as output:
        p = port()
        receiver = subprocess.Popen([str(binary),"receive","--bind","127.0.0.1","--port",str(p),"--output",output,"--once"],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            ready = receiver.stderr.readline()
            if "Listening:" not in ready: raise RuntimeError(ready+receiver.stderr.read())
            cpu = resource.getrusage(resource.RUSAGE_CHILDREN)
            before = time.perf_counter()
            sent = subprocess.run([str(binary),"send",*flags,f"127.0.0.1:{p}",str(source)],capture_output=True,text=True,timeout=180)
            wall = time.perf_counter()-before
            try: _, errors = receiver.communicate(timeout=20)
            except subprocess.TimeoutExpired:
                receiver.kill(); receiver.communicate(); raise
            if sent.returncode or receiver.returncode: raise RuntimeError(sent.stderr+errors)
            if (pathlib.Path(output)/source.name).stat().st_size != source.stat().st_size: raise RuntimeError("wrong output size")
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            seconds = float(re.search(r"Elapsed:\s+([0-9.]+)",sent.stderr)[1])
            return seconds, wall, after.ru_utime-cpu.ru_utime, after.ru_stime-cpu.ru_stime
        finally:
            if receiver.poll() is None:
                receiver.kill();receiver.communicate()

def main():
    a = argparse.ArgumentParser()
    a.add_argument("--binary",type=pathlib.Path,default=ROOT/"zig-out/bin/zcp")
    a.add_argument("--file",type=pathlib.Path,default=ROOT/".bench/input.bin")
    a.add_argument("--size-mib",type=int,default=512)
    a.add_argument("--repeats",type=int,default=3)
    a.add_argument("--suite",choices=["baseline","resume","integrity","pipeline","zero-copy","parallel","all"],default="all")
    a.add_argument("--csv",type=pathlib.Path,default=ROOT/"benchmarks/results.csv")
    a.add_argument("--build-mode",default="ReleaseSafe")
    o = a.parse_args(); o.file.parent.mkdir(parents=True,exist_ok=True); fixture(o.file,o.size_mib*1048576)
    cases=[]
    if o.suite in ("baseline","all"):
        cases += [("phase1",s,1,1,"generic","off",False) for s in (65536,262144,1048576,4194304,16777216)]
    if o.suite in ("resume","all"): cases += [("phase2",1048576,1,1,"generic","off",True)]
    if o.suite in ("integrity","all"): cases += [("phase3",1048576,1,1,"generic",i,False) for i in ("off","on")]
    if o.suite in ("pipeline","all"): cases += [("phase4",s,b,1,"generic",i,False) for s in (1048576,4194304) for b in (1,2,4) for i in ("off","on")]
    if o.suite in ("zero-copy","all"): cases += [("phase4",s,1,1,"zero-copy","off",False) for s in (1048576,4194304,16777216)]
    if o.suite in ("parallel","all"): cases += [("phase5",1048576,1,c,"generic",i,False) for c in (1,2,4,8) for i in ("off","on")]
    o.csv.parent.mkdir(parents=True,exist_ok=True)
    fields="phase,repeat,environment,build_mode,file_size,elapsed_s,wall_s,MB_s,MiB_s,buffer_size,buffer_count,connections,backend,integrity,resume,user_s,system_s,aggregate_cpu_percent".split(",")
    with o.csv.open("w",newline="") as f:
        writer=csv.DictWriter(f,fieldnames=fields); writer.writeheader()
        schedule=[]
        rng=random.Random(20261005)
        for repeat in range(o.repeats):
            ordered=cases.copy();rng.shuffle(ordered)
            schedule.extend((repeat,case) for case in ordered)
        for repeat,case in schedule:
                phase,size,buffers,connections,backend,integrity,resume=case
                flags=["--buffer-size",str(size),"--buffers",str(buffers),"--connections",str(connections),"--io",backend,"--integrity",integrity]
                if resume: flags += ["--resume"]
                seconds,wall,user,system=local_run(o.binary.resolve(),o.file.resolve(),flags)
                n=o.file.stat().st_size
                row=dict(zip(fields,[phase,repeat+1,"localhost-warm-cache",o.build_mode,n,seconds,wall,n/seconds/1e6,n/seconds/1048576,size,buffers,connections,backend,integrity,resume,user,system,100*(user+system)/wall]))
                writer.writerow(row); f.flush()
                print(f"{phase} {size//1024}KiB x{buffers} c{connections} {backend} {integrity}: {n/seconds/1e6:.1f} MB/s",flush=True)
if __name__ == "__main__": main()

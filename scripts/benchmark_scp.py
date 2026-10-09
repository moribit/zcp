#!/usr/bin/env python3
"""Loopback scp with an ephemeral, key-only localhost sshd. No ~/.ssh changes."""
import argparse,csv,getpass,os,pathlib,resource,socket,subprocess,tempfile,time
from benchmark import ROOT,fixture,port

def main():
    a=argparse.ArgumentParser();a.add_argument("--file",type=pathlib.Path,default=ROOT/".bench/input.bin");a.add_argument("--size-mib",type=int,default=1024);a.add_argument("--repeats",type=int,default=3);a.add_argument("--csv",type=pathlib.Path,default=ROOT/"benchmarks/scp-localhost.csv");o=a.parse_args()
    o.file.parent.mkdir(parents=True,exist_ok=True);fixture(o.file,o.size_mib*1048576)
    with tempfile.TemporaryDirectory(prefix="zcp-sshd-") as work:
        work=pathlib.Path(work);p=port()
        for name in ("host","client"):
            subprocess.run(["ssh-keygen","-q","-t","ed25519","-N","","-f",str(work/name)],check=True)
        config=work/"sshd_config"
        config.write_text(f"Port {p}\nListenAddress 127.0.0.1\nHostKey {work/'host'}\nPidFile {work/'pid'}\nAuthorizedKeysFile {work/'client.pub'}\nStrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nAllowUsers {getpass.getuser()}\nAllowTcpForwarding no\nX11Forwarding no\nPermitTunnel no\nForceCommand internal-sftp\nSubsystem sftp internal-sftp\nLogLevel ERROR\n")
        daemon=subprocess.Popen(["/usr/sbin/sshd","-D","-e","-f",str(config)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            for _ in range(100):
                if daemon.poll() is not None:raise RuntimeError(daemon.stderr.read())
                try:
                    with socket.create_connection(("127.0.0.1",p),timeout=.1):break
                except OSError:time.sleep(.02)
            else:raise RuntimeError("sshd startup timeout")
            o.csv.parent.mkdir(parents=True,exist_ok=True)
            with o.csv.open("w",newline="") as f:
                fields="repeat,environment,file_size,elapsed_s,MB_s,MiB_s,sender_user_s,sender_system_s".split(",");w=csv.DictWriter(f,fields);w.writeheader()
                for repeat in range(o.repeats):
                    dest=work/"received.bin";cpu=resource.getrusage(resource.RUSAGE_CHILDREN);start=time.perf_counter()
                    cmd=["scp","-F","/dev/null","-P",str(p),"-i",str(work/"client"),"-o","BatchMode=yes","-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=/dev/null","-o","Compression=no",str(o.file.resolve()),f"{getpass.getuser()}@127.0.0.1:{dest}"]
                    result=subprocess.run(cmd,capture_output=True,text=True,timeout=180)
                    if result.returncode:raise RuntimeError(result.stderr)
                    # Match zcp's end-to-end durability boundary by syncing output.
                    with dest.open("rb") as received:os.fsync(received.fileno())
                    elapsed=time.perf_counter()-start;after=resource.getrusage(resource.RUSAGE_CHILDREN);n=o.file.stat().st_size
                    if dest.stat().st_size!=n:raise RuntimeError("wrong scp output size")
                    w.writerow(dict(zip(fields,[repeat+1,"localhost-warm-cache",n,elapsed,n/elapsed/1e6,n/elapsed/1048576,after.ru_utime-cpu.ru_utime,after.ru_stime-cpu.ru_stime])));f.flush();dest.unlink()
                    print(f"scp repeat {repeat+1}: {n/elapsed/1e6:.1f} MB/s",flush=True)
        finally:
            daemon.terminate()
            try:daemon.communicate(timeout=5)
            except subprocess.TimeoutExpired:daemon.kill();daemon.communicate()
if __name__=="__main__":main()

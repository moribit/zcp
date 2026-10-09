#!/usr/bin/env python3
import argparse, hashlib, json, os, pathlib, re, socket, struct, subprocess, tempfile, time, unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get("ZCP_BINARY",ROOT/"zig-out/bin/zcp")).resolve()
def free_port():
    with socket.socket() as s: s.bind(("127.0.0.1",0)); return s.getsockname()[1]
def digest(path):
    h=hashlib.sha256()
    with open(path,"rb") as f:
        for b in iter(lambda:f.read(4*1024*1024),b""): h.update(b)
    return h.digest()
def frame(kind,data=b""): return b"ZCP1"+struct.pack("!HHII",1,kind,0,len(data))+data
def exact(s,n):
    out=b""
    while len(out)<n:
        b=s.recv(n-len(out))
        if not b: raise EOFError()
        out+=b
    return out
def recv_frame(s):
    magic,v,kind,flags,n=struct.unpack("!4sHHII",exact(s,16))
    assert magic==b"ZCP1" and v==1 and flags==0
    return kind,exact(s,n)
class Integration(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix="zcp-test-"); self.root=pathlib.Path(self.tmp.name)
        self.output=self.root/"out";self.output.mkdir();self.processes=[]
    def tearDown(self):
        for p in self.processes:
            if p.poll() is None: p.kill()
            p.communicate()
        self.tmp.cleanup()
    def receiver(self):
        port=free_port()
        p=subprocess.Popen([str(BIN),"receive","--bind","127.0.0.1","--port",str(port),"--output",str(self.output),"--once"],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.processes.append(p)
        self.assertIn("Listening:",p.stderr.readline())
        return p,port
    def source(self,name,size):
        path=self.root/name
        with path.open("wb") as f:
            while size:
                n=min(size,4*1024*1024);f.write(os.urandom(n));size-=n
        return path
    def send(self,path,port,*options):
        return subprocess.run([str(BIN),"send",*options,f"127.0.0.1:{port}",str(path)],capture_output=True,text=True,timeout=60)
    def transfer(self,path,*options):
        r,port=self.receiver();s=self.send(path,port,*options);_,e=r.communicate(timeout=15)
        self.assertEqual(s.returncode,0,s.stderr+e);self.assertEqual(r.returncode,0,e)
        self.assertEqual(digest(path),digest(self.output/path.name))
        return s.stderr
    def test_small_empty_and_names(self):
        for name,n in (("empty",0),("日本語 video.mp4",17003),("one",1)):
            with self.subTest(name=name):self.transfer(self.source(name,n),"--integrity","on")
    def test_large_file(self):self.transfer(self.source("large.mp4",int(os.environ.get("ZCP_LARGE_MIB","64"))*1024*1024+73),"--buffer-size","256K")
    def test_parallel_reconstruction_pipeline_integrity(self):
        for c in (2,4,8):
            for integrity in ("off","on"):
                with self.subTest(connections=c,integrity=integrity):self.transfer(self.source(f"parallel{c}-{integrity}.mp4",16*1024*1024+137),"--connections",str(c),"--buffers","4","--buffer-size","256K","--integrity",integrity)
    def test_zero_copy(self):self.transfer(self.source("zero-copy.mp4",32*1024*1024+17),"--io","zero-copy","--integrity","off")
    def test_killed_processes_resume(self):
        source=self.source("resume.mp4",256*1024*1024+71)
        r,port=self.receiver()
        s=subprocess.Popen([str(BIN),"send","--connections","4","--buffer-size","64K","--integrity","on",f"127.0.0.1:{port}",str(source)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.processes.append(s);deadline=time.monotonic()+10;progress=0
        while time.monotonic()<deadline:
            states=list(self.output.glob("*.state"))
            if states:
                with states[0].open("rb") as f:
                    f.seek(512);b=f.read(16)
                if len(b)==16:
                    progress,complement=struct.unpack("!QQ",b)
                    if progress>0 and complement==(progress ^ ((1<<64)-1)): break
            if s.poll() is not None: self.fail("transfer completed before interruption")
            time.sleep(.001)
        self.assertGreater(progress,0);s.kill();r.kill();s.communicate();r.communicate()
        self.assertFalse((self.output/source.name).exists())
        bad_receiver,bad_port=self.receiver()
        bad=self.send(source,bad_port,"--resume","--connections","4","--buffer-size","256K","--integrity","off")
        bad_receiver.communicate(timeout=10);self.assertNotEqual(bad.returncode,0);self.assertIn("ResumeMetadataMismatch",bad.stderr)
        result=self.transfer(source,"--resume","--connections","4","--buffer-size","256K","--integrity","on")
        self.assertGreater(int(re.search(r"Resumed:\s+(\d+)",result)[1]),0)
        if os.environ.get("ZCP_RESUME_REPORT"):
            skipped=int(re.search(r"Resumed:\s+(\d+)",result)[1]);elapsed=float(re.search(r"Elapsed:\s+([0-9.]+)",result)[1])
            report={"file_size":source.stat().st_size,"resume_offset_total":skipped,"transferred_bytes":source.stat().st_size-skipped,"elapsed_s":elapsed,"MB_s":(source.stat().st_size-skipped)/elapsed/1e6,"buffer_size":262144,"buffers":1,"connections":4,"backend":"generic","integrity":"on","sha256_verified":True}
            pathlib.Path(os.environ["ZCP_RESUME_REPORT"]).write_text(json.dumps(report,indent=2)+"\n")
    def test_corrupted_chunk_rejected(self):
        r,port=self.receiver();control=socket.create_connection(("127.0.0.1",port),timeout=5)
        self.addCleanup(control.close)
        identity=b"C"*32
        control.sendall(frame(1,b"\0"*32+struct.pack("!H",65535)))
        metadata=identity+struct.pack("!QI HBB",4,65536,1,1,0)+b"corrupt.mp4"
        control.sendall(frame(2,metadata));self.assertEqual(recv_frame(control),(2,b""))
        data=control
        data.sendall(frame(4,struct.pack("!QQ",0,4)));self.assertEqual(recv_frame(data)[0],3)
        # Hash of GOOD computed with Zig 0.17 std.hash.XxHash64(seed=0).
        corrupted=bytearray(b"GOOD");corrupted[2]^=1
        data.sendall(frame(5,struct.pack("!QQ",0,0xf88df0af9e300c69)+corrupted))
        kind,message=recv_frame(data);self.assertEqual(kind,7);self.assertIn(b"CorruptedChunk",message)
        r.communicate(timeout=10);self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.output/"corrupt.mp4").exists())
    def test_resume_identity_not_filename(self):
        # Seed a syntactically valid unrelated partial transfer with the same name.
        r,port=self.receiver();c=socket.create_connection(("127.0.0.1",port),timeout=5)
        c.sendall(frame(1,b"\0"*32+struct.pack("!H",65535)))
        c.sendall(frame(2,b"X"*32+struct.pack("!QI HBB",100,65536,1,0,0)+b"same.mp4"));self.assertEqual(recv_frame(c)[0],2)
        c.close();r.kill();r.communicate()
        result=self.transfer(self.source("same.mp4",100),"--resume")
        self.assertIn("Resumed:     0 bytes",result)
    def test_control_disconnect_before_parallel_workers(self):
        r,port=self.receiver();c=socket.create_connection(("127.0.0.1",port),timeout=5)
        c.sendall(frame(1,b"\0"*32+struct.pack("!H",65535)))
        c.sendall(frame(2,b"W"*32+struct.pack("!QI HBB",100,65536,4,0,0)+b"missing-workers.mp4"));recv_frame(c);c.close()
        _,errors=r.communicate(timeout=10);self.assertIn("UnexpectedEof",errors)
    def test_existing_destination_error(self):
        source=self.source("exists.mp4",1024);(self.output/source.name).write_bytes(b"keep")
        r,port=self.receiver();sent=self.send(source,port);r.communicate(timeout=10)
        self.assertNotEqual(sent.returncode,0);self.assertIn("DestinationExists",sent.stderr)
        self.assertEqual((self.output/source.name).read_bytes(),b"keep")
    def test_bad_protocol_and_sender_errors(self):
        r,port=self.receiver();s=socket.create_connection(("127.0.0.1",port),timeout=5)
        s.sendall(b"WRNG"+struct.pack("!HHII",1,1,0,34));self.assertIn(b"BadMagic",recv_frame(s)[1]);s.close();r.communicate(timeout=10)
        sent=self.send(self.root/"absent",port);self.assertNotEqual(sent.returncode,0);self.assertIn("FileNotFound",sent.stderr)
        p=subprocess.run([str(BIN),"send","--io","zero-copy","--integrity","on","127.0.0.1:1","file"],capture_output=True,text=True)
        self.assertIn("IncompatibleZeroCopy",p.stderr)
    def test_worker_disconnect_recoverable(self):
        r,port=self.receiver();c=socket.create_connection(("127.0.0.1",port),timeout=5)
        identity=b"D"*32;c.sendall(frame(1,b"\0"*32+struct.pack("!H",65535)))
        c.sendall(frame(2,identity+struct.pack("!QI HBB",100,65536,1,0,0)+b"drop.mp4"));recv_frame(c)
        c.sendall(frame(4,struct.pack("!QQ",0,100)));recv_frame(c);c.close();_,errors=r.communicate(timeout=10)
        self.assertIn("UnexpectedEof",errors)
        self.assertFalse((self.output/"drop.mp4").exists())
if __name__=="__main__":
    parser=argparse.ArgumentParser(add_help=False);parser.add_argument("--large-mib",type=int);parser.add_argument("--resume-report");parser.add_argument("--binary",type=pathlib.Path)
    options,remaining=parser.parse_known_args()
    if options.binary:BIN=options.binary.resolve()
    if options.large_mib:os.environ["ZCP_LARGE_MIB"]=str(options.large_mib)
    if options.resume_report:os.environ["ZCP_RESUME_REPORT"]=options.resume_report
    unittest.main(argv=[__file__,*remaining],verbosity=2)

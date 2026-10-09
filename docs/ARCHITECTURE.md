# Architecture

|Module|Responsibility|
|---|---|
|`main.zig`|process Initとトップレベルerror/exit|
|`cli.zig`|arguments、bounds、memory cap、backend互換性|
|`protocol.zig`|versioned wire codec、frame bounds、filename validation|
|`transport.zig`|std.Io TCP connection、exact reads、writes|
|`sender.zig`|metadata/source identity、range workers、resume、最終commit|
|`receiver.zig`|listen、session、range受信、checkpoint、atomic publication|
|`transfer.zig`|range partition、chunk framing、serial buffered baseline|
|`integrity.zig`|xxHash64 chunk verification、BLAKE3 source identity|
|`io/generic.zig`|serial/pipelined positional reads、bounded buffer pool|
|`io/zero_copy.zig`|typed OS sendfile calls、partial progress/error handling|
|`progress.zig`|転送量・時間・速度・payload RAM表示|
|`scripts/benchmark*.py`|再現可能なlocalhost/remote/scp比較とCSV|
|`tests/integration.py`|localhost fault/kill/data reconstruction tests|

std.process.Initの`io`をI/Oと同期処理に明示的に渡す。0.17の`std.Io.Group.concurrent`・`std.Io.Queue(usize)`を使う。concurrentを選ぶ理由は、producer/consumerのbounded queueに実際の同時進行が必要で、`async`には並行実行保証がないため。実行環境はstd.Io.Threaded。Threadedのconnect timeout optionは宣言されていますが実装はpanic/TODOであるため使用しない。独自event loopや古いstd.net/std.fs互換レイヤーは用いない。

buffer count=1はread→hash→vectored sendの単純経路。count>1は事前allocationしたslot poolとfree/ready index queuesを使う。producerがpositional readとhashを行い、consumerがTCPへ送る。queuesにはslot indexだけをコピーし、payloadはコピーしない。queue backpressureによりmemoryは一定で、network error時はqueue closeとgroup cancelでproducerを終了する。

receiverはconnectionごとに1 bufferを持ち、read→verify→pwrite→checkpointを行う。受信側のdisk writeはそのconnection内では直列。並列rangeは重ならず、shared fileのpread/pwriteでglobal seek cursorを使わない。file全体をRAMへ保持せず、再構築のための2回目のcopyも不要。

single connectionでは別control socket/worker threadを作らない。parallelではcontrol socket + N data sockets。各taskのerrorはtask固有slotへ保存し、Group.await後に集約する。control EOFがaccept/receiveをキャンセルし、staging fileは保持する。receiverは1 sessionずつ処理するためsession mapや複雑なper-file共有状態を避ける。

zero-copyはgenericとは別経路。0.17のThreaded.netWriteFileはTODO/Unimplemented。File.Writer側のmacOS sendfileもunbuffered readerでassertすることを確認したため、標準の`std.c.sendfile` typed bindingを直接使う。Linuxはout_fd,in_fd,offset*,count、macOSはin_fd,out_fd,offset,len*,hdtr,flags。macOSはEINTR/EAGAINでも転送済みlenを反映し、Linuxはreturn countと明示offsetを使う。short transfers、EINTR、EOF、broken pipe、unsupportedを扱う。genericへの暗黙fallbackは行わない。

native sendfileはblocking syscallで、std.Io cancelは呼び出し間で確認する。呼び出しそのもののinterruptをIo runtimeに登録する仕組みは使っていないため、stalled peerのnative taskは即時cancelを保証しない。zero-copyは明示的な比較オプションとし、デフォルトにはしない。generic pathを残す。

Linux spliceはfile→pipe→socketでpipe管理・追加syscallが必要で、この用途の単純なsendfileに対する優位性を確認していないため実装しない。macOS/Linuxのsendfileを比較対象に残すが、名称だけで高速と判断しない。

調査した一次資料はインストール済み0.17.0のstd source（`Io.zig`, `Io/Threaded.zig`, `Io/net.zig`, `Io/File/Writer.zig`, `c.zig`）。公開参照：[std.Io](https://github.com/ziglang/zig/blob/0.17.0/lib/std/Io.zig)、[Threaded](https://github.com/ziglang/zig/blob/0.17.0/lib/std/Io/Threaded.zig)、[net](https://github.com/ziglang/zig/blob/0.17.0/lib/std/Io/net.zig)。公開docsの宣言だけで動作を推測せず、実際にビルド・転送して利用可能性を確認した。

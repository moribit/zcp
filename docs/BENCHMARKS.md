# Benchmark report — 2026-10-05

本レポートの数値は実測だけを使用する。localhost、公開サーバー経路、1GbE LANを区別する。指定された`root@mimoc.jp`はLinux x86_64の公開サーバー（172.233.92.197）であり、この経路をLANと呼ばない。1GbE LANの50/80/100 MB/s達成は未検証。

## 測定環境・手順

送信元はApple M2 / 16 GB / macOS 27.0 / Zig 0.17.0。受信peerはLinux x86_64、glibc 2.36。peerにZig 0.17はないため、手元でx86_64-linux-muslをクロスビルドしたstatic executableを使う。macOS、Linuxとも統合テストを実行した。

圧縮なしの実ファイルを使い、fixtureを計測前に作る。sourceはwarm cache。転送はreceiverのfile fsync・rename・ACKまで含む。scpは`Compression=no`とし、受信後にfsyncしてからwall clockを止める。remote scpのfsyncには追加SSH起動時間も含む。zcp CSVはCLI elapsedとprocess wall timeの両方を残す。各remote成功転送は独立したSHA-256で一致検証する。ファイル全体をRAMに保持しない。

初期Phase 1/2/3/4の探索は512 MiB、最終localhost比較は1 GiB、remote探索は512/256 MiB、remote反復比較は128 MiB。source sizeはCSVに記録する。異なるサイズ・異なる時間帯の結果を同一条件のbefore/afterとして扱わない。反復比較は固定seedで順序をshuffleし、中央値とmin/maxを示す。ネットワークの時間変動は制御できないため、remoteの小差に因果関係を主張しない。

## 保存データ

- `phase1-before.csv`：最適化追加前の64K〜16M serial OFF。
- `phase2.csv`：resume negotiation有効で新規転送した場合のthroughput。実際の途中再開は`resume-test.json`で別途計測。
- `phase3-before.csv`：pipeline追加前のintegrity OFF/ON。
- `phase4-after.csv`：pipeline追加後のsize/count/ON/OFF探索。
- `exploratory-contended.csv`：探索用。Linuxのクロスコンパイルが一部重なったため**最終比較には使わない**。
- `scp-localhost.csv`：1 GiB実scp 3回。
- `remote-smoke.csv`：512 MiB、generic 1 connection OFFとscpの初回実測。
- `remote-release-safe.csv`：途中でtimeoutした探索。成功した行のみ保持。完走データの代替にしない。
- `remote-release-safe-final.csv`：成功と失敗をともに記録した反復比較。
- `final-release-safe.csv`, `final-release-fast.csv`：完成版localhost比較。

初期実装は最初からversioned range protocolとcheckpoint/hashの拡張点を備えていた。探索時は1 data TCP + control TCP、完成版のsingle pathは1 TCPだけを使う。初期CSVは開発過程の記録として保存し、完成版の性能は完成版CSVを優先する。

## 完成版localhost・build mode比較

1 GiB、ReleaseSafeは全31条件×3回=93試行すべて成功。ReleaseFastはserial integrity OFF/ONを各3回比較。localhost scpは240.32 MB/s（238.91〜240.92）。NICを通らないため以下をLANの達成値として使わない。

|方式|buffer size/count|integrity|Median MB/s|Min–max MB/s|
|---|---|---|---:|---:|
|generic serial|64K / 1|OFF|1698.95|1495.58–1718.86|
|generic serial|256K / 1|OFF|1893.00|1857.24–2308.23|
|generic serial|1M / 1|OFF|2023.42|1932.16–2132.71|
|generic serial|4M / 1|OFF|1855.97|557.03–2289.94|
|generic serial|16M / 1|OFF|1970.90|576.68–2129.98|
|phase3 serial|1M / 1|OFF|1884.18|1289.15–2269.09|
|phase3 serial|1M / 1|ON|1864.29|1659.81–2317.55|
|phase4 serial|1M / 1|ON|1893.57|1832.68–2102.94|
|phase4 pipeline|1M / 2|ON|2265.94|1876.78–2284.28|
|phase4 pipeline|1M / 4|ON|1840.70|1444.58–2136.78|
|phase4 serial|4M / 1|OFF|2100.50|1843.35–2125.64|
|phase4 pipeline|4M / 4|OFF|2123.07|1870.55–2466.14|
|phase4 zero-copy|4M / 1|OFF|1929.90|1902.19–2098.48|
|phase5 single|1M / 1|ON|1895.41|1832.54–2404.89|
|phase5 parallel x2|1M / 1|ON|1466.90|1027.16–1539.34|
|phase5 parallel x4|1M / 1|ON|1652.21|1532.77–1682.73|
|phase5 parallel x8|1M / 1|ON|1567.99|1482.38–1686.48|

同一設定を複数Phaseのcaseに含めたため、serialの各行は同じコードの別試行である。これらの差をPhaseの変更効果とは扱わない。完全なOFF/ON・count 1/2/4・parallel 1/2/4/8・zero-copy 1M/4M/16Mの値はCSVと`summarize.py`で確認できる。

phase3の中央値ではintegrity ONはOFFより1.1%低下し、送受信aggregate CPU中央値は64.8%→86.4%。hashのCPUコストはあるが、この測定のwall throughput低下は小さかった。1M pipeline count2 ONはserialに対して+19.7%、count4は-2.8%。4M pipeline count4 OFFは+1.1%、4M zero-copy OFFは-8.1%。parallel ON x2/x4/x8はsingleに対して-22.6%/-12.8%/-17.3%。それぞれ試行範囲を併記し、特に小差に強い因果主張をしない。大きなバッファ・多数バッファ・多数接続に単調な改善はない。

|Build mode（phase3 serial 1M）|OFF median MB/s|ON median MB/s|ON aggregate CPU median|
|---|---:|---:|---:|
|ReleaseSafe|1884.18|1864.29|86.4%|
|ReleaseFast|1795.84|2097.46|97.9%|

FastはONで+12.5%、OFFで-4.7%。別suiteのため時間帯/cache差も含み、あらゆる条件でFastが優位とは確認できていない。**実運用推奨はReleaseSafe**。ReleaseFastは比較用に提供する。localhostのSafe ON=1864.29 MB/sは実localhost scp=240.32 MB/sの7.76xだが、これを公開経路や1GbEの倍率とは混同しない。

実際のresume試験（`resume-test.json`）：256 MiB+71 bytes、4 connections、integrity ON。524288 bytesをcheckpointから省略し、267911239 bytesを0.158168 sで再送、1693.84 MB/s。source全体とのSHA-256一致を確認した。これはlocalhost・単発の再開動作実測であり性能の代表値ではない。別に2 GiB+73 bytesの転送とSHA-256比較も成功した。

## 指定peerの実測

128 MiB × 各条件3試行。以下の中央値は**成功した試行のみ**。失敗を含む実運用の総throughputではない。39試行中33成功・6失敗で、失敗はparallelのTCP timeoutだった。失敗はreceiverのUnexpectedEofを伴った。原因を確定できていない。peerのlocalhostでは8 connectionを含む統合テストが通ったが、これだけでアプリケーション側の問題を完全に否定することはできない。

|方式|buffer size/count|integrity|成功/試行|Median MB/s|Min–max MB/s|
|---|---|---|---:|---:|---:|
|scp|—|SSH|3/3|17.76|11.22–21.49|
|generic single|1M / 1|OFF|3/3|24.83|8.69–33.08|
|generic single（既定）|1M / 1|ON|3/3|30.16|21.48–44.26|
|pipeline single|1M / 4|ON|3/3|27.19|18.61–30.83|
|generic single|4M / 1|OFF|3/3|21.19|21.08–34.25|
|pipeline single|4M / 4|OFF|3/3|20.76|16.23–32.83|
|zero-copy single|4M / 1|OFF|3/3|15.95|9.92–30.41|
|parallel x2|1M / 1|OFF|2/3|32.96|25.25–40.68|
|parallel x2|1M / 1|ON|3/3|24.31|23.94–25.41|
|parallel x4|1M / 1|OFF|2/3|31.18|30.06–32.29|
|parallel x4|1M / 1|ON|2/3|18.27|12.88–23.66|
|parallel x8|1M / 1|OFF|2/3|27.72|15.15–40.29|
|parallel x8|1M / 1|ON|1/3|49.54|成功1件のみ|

指定基準に対して：**scp baseline = 25.00 MB/s、zcp既定 = 30.16 MB/s、speedup = 1.21x**（公開peer経路、成功3試行の中央値）。同じ反復測定での実scp=17.76 MB/sに対しては**1.70x**。初回512 MiBではscp=23.65 MB/s、zcp serial OFF=14.46 MB/sで**0.61x**だった。測定時間帯/サイズで逆転しており、常にscpより速いとは言わない。

8 connection ONの最高49.54 MB/sは指定25 MB/s基準の1.98xだが、成功率1/3のため代表値にも推奨値にも使わない。50/80/100 MB/sは安定達成していない。公開経路でもserialの方が速い試行があり、pipeline・sendfile・parallelに一律の高速化効果は確認できなかった。hash ONがOFFより高い中央値なのも時間変動の影響があり、hashが高速化したという結論ではない。

## 各Phaseでの変更と判断

|Phase|変更前 → 変更|測定・検証|判断|
|---|---|---|---|
|1|read→vectored send、サイズ可変|64K/256K/1M/4M/16M、scp比較|固定サイズの優位を前提にしない|
|2|常に0から → range別checkpointとoffset交渉|fresh resume mode＋プロセスkill後の再開、SHA-256一致|sample/stat identityとmetadata照合でfilenameだけの一致を排除|
|3|checksumなし → chunk xxHash64|同じserial pathでOFF/ON、意図的破損を拒否|全体再readなし。通常はON|
|4|serial → preallocated producer/consumer pool|buffers 1/2/4、1M/4M、OFF/ON|改善が安定しない場合は1 bufferを使う|
|4|buffered → macOS/Linux native sendfile|genericとzero-copy、同じfile/sizeで比較|OFF専用の明示オプション。名前で優位を判断しない|
|5|single TCP → 2/4/8 range workers|ON/OFF、range再構築、resume、local/remote失敗も記録|defaultはsingle。parallelは測定結果に応じて選ぶ|

std.IoのソケットsendFileとconnect timeoutは0.17 Threadedでは未実装だった。File.WriterのmacOS sendfileにもunbuffered readerでassertする経路があり、実転送テストで確認した。zero-copyはstd.cのtyped OS bindingで実装し、genericへの暗黙fallbackを避ける。spliceは効果が確認できていないため追加しない。

## ボトルネックと次の改善

公開サーバー経路では1接続の送信側CPU時間がwall timeよりかなり短く、CPUだけで速度が決まっている状況とは考えにくい。parallelの向上・低下・timeoutと大きな試行間変動があり、回線帯域・RTT/TCP window・loss・接続安定性を優先して確認する。ただしCPU flamegraph、TCP retransmission時系列、peer disk profilingを取得していないため、特定要因を確定したとは言わない。macOSのTCP sendspace/recvspace既定は各131072 bytes、maxsockbufは8388608 bytesだった。kernel autotuningの実windowは別であり、この設定値だけからthroughputを推定しない。

localhostはNICを通らない。page cache、kernel TCP copy、hash、positional write、fsyncとSSD writebackの影響を測っている。繰り返し書き込みによるcache/SSD状態と実行順の影響がある。localhost速度をそのまま1GbEへ投影しない。

100 MB/sへ近づける次の手順：同一スイッチの有線1GbE peerで本scriptを実行し、同じ動画でscpと比較する。次に独立したdisk read/write測定とraw TCP測定でNIC/ディスク/CPUを切り分ける。RTT・loss・cwnd/receive window・CPU profilerを取得してからsocket buffer tuningをA/B比較する。receiverのnetwork/verify/write pipeline、checkpoint batching、より大きいzero-copy frameも候補だが、resume保証・memory上限を保ち、before/afterで効果を確認する。停電resumeにはdata sync後のatomic checkpoint publicationとdirectory syncを別途設計する。

## 再現に使ったバイナリ SHA-256

```text
macOS ReleaseSafe  d043d1d710f2460008e69daad4155a62e726c43a5496ebc9dc0b20a51705f36e
macOS ReleaseFast  ab6d2fb3d6e5b78c94ec691060cb3b82f215f50f129ee8234b1a843e2b05ecbb
Linux ReleaseSafe  cc73908796e7da616c402a49ddcff91dfe88f1ee2946f0aaa1f4fedc09fcb114
Linux ReleaseFast  84cd6874992904a634d1a561656b9781f47b93ddb1aa8bb309f56800c31c29fe
```

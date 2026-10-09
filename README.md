# zcp — Zig 0.17 LAN file transfer

巨大ファイルを圧縮・暗号化せずにTCPで転送するCLIです。Zig **0.17.0**専用、外部パッケージなし。generic経路は`std.Io`、zero-copyは標準ライブラリのOS bindingsとシステムlibcを使います。

```sh
zig build -Doptimize=ReleaseSafe
mkdir -p received
./zig-out/bin/zcp receive --port 9000 --output received
./zig-out/bin/zcp send 192.168.1.10:9000 ./video.mp4
```

指定の公開peerでの反復実測は、既定設定zcp **30.16 MB/s**、同じ比較のscp **17.76 MB/s**（中央値）。指定の25 MB/s基準に対して **1.21x**。LANの50/80/100 MB/s達成は未検証です。詳細とparallel timeoutは下記レポートに記録しています。

既定値は **1 MiB / 1 buffer / 1 connection / generic / integrity ON**。通常はこの設定から始めてください。受信側は転送ごとに処理し、複数ファイルの同時セッションは受け付けません。`--once`で1回の転送後に終了します。既存の完成ファイルを上書きしません。

```sh
# 中断後、同じ送信元ファイル・同じ接続数・同じintegrity modeで再開
./zig-out/bin/zcp send --resume 192.168.1.10:9000 video.mp4

# Disk Read + Hashとネットワーク送信を固定プールで重ねる
./zig-out/bin/zcp send --buffer-size 4M --buffers 4 192.168.1.10:9000 video.mp4

# 複数の範囲を位置指定書き込み。integrity・resumeと併用可能
./zig-out/bin/zcp send --resume --connections 4 192.168.1.10:9000 video.mp4

# macOS/Linux sendfile。チェックサムとは併用できない
./zig-out/bin/zcp send --io zero-copy --integrity off 192.168.1.10:9000 video.mp4

# IPv6の数値アドレスにも対応（DNS解決はしない）
./zig-out/bin/zcp send '[::1]:9000' video.mp4
```

`--buffer-size`はバイト数またはK/M/G（binary units）。64K / 256K / 1M / 4M / 16Mを比較できます。最大16 MiB、`--buffers`は1〜64、`--connections`は1〜8。送信payloadプールは合計512 MiB以下です。転送ループでのallocation、payloadの中間コピーはありません。表示するRAMはpayloadプール量であり、RSS・スレッド・カーネルsocket buffer・page cacheを含みません。

送受信とも転送量、経過秒、MB/s、MiB/s、再開で省略したバイト数を表示します。MB/sはdecimal、GiB/MiBはbinaryです。再開時の速度は**今回送ったバイト数**から計算します。送信計測は接続開始から受信側の最終`fsync`・rename・ACKまで。ファイル識別の最大192 KiBのsample readはその前に実行します。benchmark CSVのwall timeにはプロセス起動と識別も含みます。

## Resumeとintegrity

受信途中は`.zcp-<source-id>-<connections>.part`と`.state`に保存します。source-idはファイルサイズ・inode・mtime・ctime・先頭/中央/末尾sampleをBLAKE3でまとめた32-byte値です。**ファイル名だけでは再開しません**。保存した名前・サイズ・識別情報・接続数・integrity modeも照合します。buffer size/countは再開時に変更できます。接続数・integrity modeを変える場合は最初から送信してください。

各範囲の受信済みoffsetを返し、送信側はpositional read / sendfileのoffsetをそこに設定します。最後まで検証・書き込みが終わったチャンクだけをcheckpointへ反映します。転送途中のkillでは完成ファイルが公開されず、次回は途中から再開できます。`--resume`なしは同じ識別子のpartialを最初から作り直します。

integrity ONは`std.hash.XxHash64`によるチャンク単位の64-bit検証です。受信側は検証後に書き込みます。誤検出確率の目安はランダム破損に対して2^-64で、敵対的改変を防ぐ認証ではありません。BLAKE3は0.17の`std.crypto.hash.Blake3`に存在することを確認し、軽量なファイル識別に使っています。巨大ファイル全体の再読み込みによる最終checksumは行いません。

sample identityは全内容の暗号学的content IDではありません。同じ名前・サイズだけの衝突は避けますが、送信元ファイルを転送中に編集しないでください。転送前後のstat変化は検出して完成を拒否します。受信partialも手動で編集しないでください。

checkpointは**プロセス中断からの再開**向けです。停電・OS crash時のデータ/checkpoint永続化順序は保証しません。完成時はデータを`fsync`しますが、rename後のdirectory fsyncや受信後のbit rot検出は未実装です。完成ACKを失った場合は既存完成ファイルを上書きせず`DestinationExists`になります。

## テスト

```sh
zig build test
python3 tests/integration.py
# 大容量・実際の途中再開時間も記録
python3 tests/integration.py --large-mib 2048 --resume-report benchmarks/resume-test.json
# Linux static binaryのクロスビルド（Linuxで実行する場合）
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl --prefix zig-out/linux
```

unit testsはwire encode/decode・filename・hash corruption・range partition・CLI bounds。localhost integration testsは小/大/空ファイル、日本語名、kill後のresume、破損チャンク、並列復元、pipeline、sendfile、既存ファイル保護、エラー・切断処理を検証します。正常転送はSHA-256で出力と入力を比較します。TCP listen可能な環境が必要です。

## ベンチマークとscp比較

```sh
# 各Phaseを個別に比較。allは全組合せの主要ケース
python3 scripts/benchmark.py --suite baseline --size-mib 1024 --repeats 3
python3 scripts/benchmark.py --suite resume --size-mib 1024 --repeats 3
python3 scripts/benchmark.py --suite integrity --size-mib 1024 --repeats 3
python3 scripts/benchmark.py --suite pipeline --size-mib 1024 --repeats 3
python3 scripts/benchmark.py --suite zero-copy --size-mib 1024 --repeats 3
python3 scripts/benchmark.py --suite parallel --size-mib 1024 --repeats 3
python3 scripts/benchmark.py --suite all --csv benchmarks/my-safe.csv

# localhost scp。sshd/ssh-keygenが必要。一時鍵とloopback専用sshdを終了後に削除
python3 scripts/benchmark_scp.py --size-mib 1024 --repeats 3

# SSH接続できるLinux peerで実ネットワーク比較。受信portへの直接到達が必要
python3 scripts/benchmark_remote.py --host user@peer --address 192.168.1.10 \
  --file .bench/video.bin --size-mib 1024 --repeats 3 --continue-on-error --csv benchmarks/my-lan.csv
```

`python3 scripts/summarize.py benchmarks/my-lan.csv`で中央値・min/max・成功/失敗数をまとめられます。`--transfer-timeout`はscript側の試行上限秒（既定60）で、zcp自身のidle timeoutではありません。

remote scriptは一時Linuxバイナリをscpで配置し、受信プロセスを転送ごとに起動します。ランダムな非圧縮fixtureを使い、generic / pipeline / zero-copy / parallel x2,x4,x8 / integrity OFF,ON / scpを同じ送信元から比較します。各転送後はSHA-256一致を確認し、受信データを削除します。SSH/firewall設定は変更しません。Windows等のpeerを使う場合は対応バイナリと測定方法を用意してください。

Phase 1だけを手動で比べる場合、受信側に`zcp receive`を起動し、同じ動画を次の両方で送ってください。

```sh
/usr/bin/time -p scp -o Compression=no video.mp4 user@192.168.1.10:/path/to/scp-output.mp4
./zig-out/bin/zcp send --integrity off --buffer-size 1M 192.168.1.10:9000 video.mp4
```

scpのthroughputは`file_bytes / wall_seconds / 1e6`。公平な比較ではscp側の受信ファイルもfsyncを終えてから計測を止めます。別名または削除済み出力を使い、同じディスク・同じLAN・同じファイル・同じcache条件で複数回測定してください。既存の`--file`はサイズ指定にかかわらず変更せず、そのまま使用します。`--size-mib`は存在しないfixtureを生成するときだけ使います。圧縮済み動画を`--file`に渡して比較できます。

ReleaseSafe/ReleaseFastも別CSVで比較してください。測定中はコンパイルや別の転送を行わず、順序依存を避けてください。scriptは固定seedで試行順をshuffleします。localhostのCPU欄は送受信子プロセスの合計で100%を超えることがあります。remote欄はsender CPUのみです。

[実測結果・最適化効果・ボトルネック](docs/BENCHMARKS.md)、[wire protocol](docs/PROTOCOL.md)、[architecture](docs/ARCHITECTURE.md)を参照してください。localhostや公開サーバーへの測定を1GbE LANの達成値とは扱いません。

## 利用範囲

信頼できるLANと、自分が管理する出力ディレクトリで使用してください。暗号化・認証・圧縮・帯域制限・転送のidle timeout・複数同時セッション・directory転送はありません。接続はOSの既定timeoutに従います（0.17のThreaded connect timeoutは未実装）。受信側は指定された`--bind`（既定0.0.0.0）で待ち受けます。symlinkを含む攻撃者管理の出力ディレクトリをsandboxとして扱う設計ではありません。portable generic実装はstd.Ioを使いますが、実行検証はmacOS arm64とLinux x86_64です。

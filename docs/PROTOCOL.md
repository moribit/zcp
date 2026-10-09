# zcp binary protocol v1

すべての整数はbig endian。wireへarchitecture依存structをコピーしない。TCPのread/writeはpartialに対応し、必要バイト数まで繰り返す。version不一致・不明type/flags・過大lengthは拒否する。

## Frame header（16 bytes）

|Offset|Width|Field|
|---:|---:|---|
|0|4|Magic ASCII `ZCP1`|
|4|2|Version u16 = 1|
|6|2|Message type u16|
|8|4|Flags u32 = 0（将来用）|
|12|4|Payload length u32|

最大payloadは16 MiB + 16 bytes。データframe以外にはさらに各message固有の上限を適用。

|Type|Name|Payload|
|---:|---|---|
|1|handshake|source-id[32], range-index u16。65535はcontrol|
|2|metadata|下記。応答はzero-length ACK|
|3|resume negotiation|next offset u64, range end u64（16 bytes）|
|4|transfer range|start u64, end u64（16 bytes、end exclusive）|
|5|chunk integrity + data|absolute offset u64, xxHash64 u64, data[]|
|6|completion|zero-length。range completionと全体commitの2段階|
|7|error|ASCII error name、最大256 bytes。接続を閉じる|

## Metadata

|Payload offset|Width|Meaning|
|---:|---:|---|
|0|32|source-id|
|32|8|expected file size u64、最大i64.max|
|40|4|maximum data chunk bytes u32、1〜16 MiB|
|44|2|data connection count u16、1〜8|
|46|1|integrity mode u8、0=off / 1=xxHash64|
|47|1|resume request u8、0/1|
|48|1〜255|filename bytes。lengthはframe length-48から得る|

NUL、ASCII control、DEL、slash/backslash、`.`、`..`、空、`.zcp-`始まりを拒否する。通常のUTF-8名・空白は許可する。wire上は終端NULなしのopaque bytes。

source-id = BLAKE3(domain `zcp-source-identity-v1` || size u64 || inode u64 || mtime i128 || ctime i128 || samples)。timesはnanoseconds since Unix epoch。metadata整数もbig endian。samplesはoffset 0、floor(size/2)、max(size-65536,0)から最大65536 bytesずつ。重なったsamplesも順番どおりhashする。これはサイズとsource statを含む安定した再開識別子であり、全ファイルのcontent checksumではない。

## Session

1 connectionの場合、すべて同一TCPで行う：

1. sender → handshake（index=65535）、metadata。
2. receiver → metadata ACK。destination/partial/stateを検証・準備。
3. sender → range [0,size)。receiver → resume offset,end。
4. sender → ordered chunk frames。receiverはoffset・length・hashを検証してpositional writeし、checkpointを更新。
5. sender → range completion。receiver → range completion ACK。
6. senderがsource stat不変を確認し、全体completionを送る。
7. receiverがfile lengthとfsyncを完了し、renamePreserveで完成名へ公開。全体completion ACK。

N>1の場合はcontrol TCPにmetadataと全体completionを載せ、N本のdata TCPを開く。各data TCPはhandshake(source-id,index)、range、resume、chunk、range completion/ACK。同一index重複・別id・不正rangeを拒否する。controlの切断は待機accept・受信workerをキャンセルする。

`base=floor(size/N)`, `extra=size%N`, `start_i=base*i+min(i,extra)`, `end_i=start_i+base+(i<extra)`。これによりfile全体を重複なしで分割する。空rangeもrange completionの往復を行う。Nはdata TCP数で、N=1の実TCP数は1、N>1の実TCP数はN+1。

receiverのresume offsetは同じidentity/size/name/N/integrityの保存状態から取得する。range内かつpartial file size以下のoffsetだけを認める。不正・破断checkpointはrange startに戻す。senderもrange内のoffsetであることを検証する。buffer size/countとI/O backendは再開時に変更可能。integrity ON/OFFは保存metadataと一致が必要。

chunk lengthは16+data_len、data_len>0かつnegotiated最大以下、range endを超えないこと。offsetはreceiverが次に期待するoffsetと厳密一致。hashは`std.hash.XxHash64.hash(0,data)`のu64値。OFFではhash=0を要求する。hash mismatch時は該当chunkをdiskに書かずcompletionも行わない。xxHashは非暗号学的破損検出であり、peer認証・攻撃防止には使わない。

## Local checkpoint format（wire外）

`.state` offset 0にcanonical metadata、40..44（buffer size）と47（resume request）を0とする。offset 304にmetadata length u16。offset 512+16*iにnext offset u64とbitwise complement u64を置く。更新が破断した場合は一致検査でinvalidとなり、そのrangeを最初から再送する。partialは同じsource-idとNから名を生成し、exclusive advisory lockを保持する。

checksum検証 → data write → checkpoint writeの順。process killでOS page cacheが存続することを前提にする。power loss時のcheckpoint durable orderingはv1の保証に含まない。完成時のfile fsync後にrenameし、stateを削除する。peerのerror/EOF、source stat変化、write error時はpartialを保存し、完成名を公開しない。完成名が既に存在する場合は拒否する。

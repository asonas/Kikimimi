# ADR-0001: CAF LPCM を収録の原本にする

## Status

Accepted — 2026-11-09

## Context

Phase 0 は AAC m4a に直接追記する。SIGINT/SIGTERM による正常な close の成功だけでは、強制終了後の音声を守れない。

2026-11-09、実際の署名付き Phase 0 アプリを LaunchServices 経由で起動して確認した。対象は Chrome、入力は Rubix44 の INPUT 1、60秒指定、保存先は `recordings/kill9-01`。13:43:47 に起動し、約12秒後の13:43:59に PID 12463 へ SIGKILL を送った。録音ログは `build/logs/20261109-134347-12454.stderr.log`。

Phase 0 のソースと起動スクリプトは2026-11-10に撤去した。当時の実装は Git 履歴に残し、現行アプリの強制終了・復元手順は [QA](../qa.md) に移した。以下は生成済み音声を調べたコマンドである。

```sh
afinfo recordings/kill9-01/audio-remote.m4a
afinfo recordings/kill9-01/audio-self.m4a
ffprobe -hide_banner -show_format -show_streams recordings/kill9-01/audio-remote.m4a
ffprobe -hide_banner -show_format -show_streams recordings/kill9-01/audio-self.m4a
```

ビルド・署名検証は成功し、録音ログには `SCStream.startCapture succeeded` が残った。約12秒後の強制終了後、remote は63,420 bytes、self は148,033 bytes存在したが、両方とも `afinfo` は `Fail: AudioFileOpenURL failed`、`ffprobe` は `moov atom not found` / `Invalid data found when processing input` で終了コード1だった。`meta.json` は未生成。`open -W` の終了コード0は録音成功を示さない。

設計時の別実験（今回の再測定ではない）は [probe-work/run-probe.sh](../design/phase1/probe-work/run-probe.sh) と [evidence-a/crash-after-sigkill.swift](../design/phase1/evidence-a/crash-after-sigkill.swift)。[design.md §17](../design/phase1/design.md#17-verified-facts-and-how-so-the-implementer-can-skip-re-checking) によると、AAC m4a は開けず、CAF LPCM int16 は書いた139,200フレーム中135,680フレームを復元できた（末尾約73 ms欠落）。CAF内AACは読めるフレームが0、WAVも長さ0だった。

## Decision

各 Track を CAF・LPCM int16・mono の Spool に追記し、通常停止と起動時復元で同じ冪等な Finalize を使う。Spool はソースのサンプルレートを保持する。AAC変換は48 kHzを上限とする（[高レートの実験](../design/phase1/evidence-a/aac-sample-rates.swift)で96/192 kHzは失敗）。`.m4a.part` に変換・検証してから正式名へ rename し、その後に Spool を削除する。復元は Lease が空いている Session だけを対象とする。

AAC m4aへの直接書き込みは上の実測により却下する。CAF内AACとWAVも実験結果から採用しない。独自ヘッダー付きPCMは専用の読み出し・復元処理が増え、fragmented MP4は耐障害性が未検証なので採用しない（[design.md §15](../design/phase1/design.md#15-alternatives-considered)）。

## Consequences

48 kHz・2 TrackのSpoolで約0.7 GB/時と停止後の変換時間が必要になる。空き5 GB未満では開始しない。約5秒ごとにfsyncする方針だが、そのコストと電源断・カーネルパニック時の損失は未測定であり、SIGKILL実験の保証に含めない。

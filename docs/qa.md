# 録音・書き起こしの確認手順

現行の検証には `mise run test`、`mise run build`、`mise run app` を使う。録音アプリは LaunchServices の `open` 経由で起動し、実行ファイルを直接起動しない。Phase 0 のパッケージと起動スクリプトは撤去済みで、過去の実験は Git 履歴と [ADR-0001](adr/0001-crash-safe-spool.md) に残している。

## 準備

```sh
mise run test
mise run build
mise run app
```

`build` は Debug アプリを生成し、署名と designated requirement を検証する。Bundle ID は `as.ason.InterviewRecorder`。再ビルド後も画面収録・マイクの許可が保持されることを Setup で確認する。

通常起動ではメインウィンドウが開く。設定は Command+, で開く。録音の準備が不足していればメイン上部の「設定を開く」を使い、初回は設定が自動で開く。設定（Setup）の操作、許可ダイアログ、デバイス選択、実録音は人間が行う。headless コマンドはウィンドウを開かず、許可を要求しない。録音可能でなければ `HEADLESS FAILED: notReady(...)` で終了する。画面収録を許可し直した後に再起動が必要と表示された場合は、設定の再起動ボタンを使う。

マイクは明示的に選ぶ。内蔵マイクの確認では蓋を開け、Rubix44 の確認ではデバイスと `INPUT 1` を選ぶ。Setup の名前、UID、入力チャンネル数、メーターを確認する。private aggregate は一覧に出ない。選択済みデバイスが消えてもシステム既定入力へ自動変更しない。

書き起こしには Setup で導入済みのモデルを使う。モデル未導入でも録音はできるが、書き起こしジョブは導入待ちになる。ダウンロードは人間が明示的に開始する。Debug の `IR_MODEL_VARIANT` 上書きを使う場合は Setup の表示を確認し、tiny の結果を本番モデルの結果と混同しない。

## 録音と音源の分離

Chrome で音声を再生し、自分も話しながら実行する。イヤホンを使い、スピーカー音がマイクへ回り込むのを避ける。

```sh
mise run app --headless record --seconds 60 --company smoke --target com.google.Chrome
```

Zoom の確認では `--target us.zoom.xos`、全システム音では `--target all` を使う。会社名は必須、タイトルは `--title QA` で任意指定できる。保存先は設定の録音ルート以下へ自動作成され、同じ会社名・時刻でも既存のフォルダを上書きしない。

表示された `build/logs/*.stderr.log` の最終行を確認する。`open -W` の終了コードはアプリの成功を表さない。成功の目印は `HEADLESS OK record` で、セッションIDとフォルダが出る。record は音声の finalize 後に終了し、書き起こし完了は待たない。

出力フォルダを `session_dir` に設定する。以下の名前は実際に出力されたものへ置き換える。

```sh
session_dir="$HOME/Library/Application Support/InterviewRecorder/Recordings/2026-11-10_1043_smoke2"
afinfo "$session_dir/audio-self.m4a"
afinfo "$session_dir/audio-remote.m4a"
jq '{startedAt,endedAt,endReason,tracks}' "$session_dir/meta.json"
```

確認する内容:

- `audio-self.m4a` は選んだマイク、`audio-remote.m4a` は指定アプリの音で、いずれも mono。別アプリから同時に出した音が remote へ混ざらないことを再生して確認する。
- `meta.json` の `tracks.self.source` に選んだ UID・チャンネルが、`tracks.remote.source` に対象アプリが記録されること。チャンネル省略は全入力のミックスで、指定は1始まり。
- 両トラックの `firstSampleHostSeconds` と `audio.frames > 0`、`audio.sampleRate`、`audio.peakDBFS` を確認する。音声長は `frames / sampleRate`。開始時刻の差は開始オフセットであり、一致を求めない。
- `tracks.*.diagnostics` の `gapCount`、`gapFillFrames`、`overlapDroppedFrames`、`maxAbsDriftSeconds` と `failure` を確認する。失敗していないトラックは、もう一方が失敗しても続く。

SCStream は `.audio` 出力だけを登録し、映像ファイルは生成しない。無音時のバッファ供給や欠落の有無は対象アプリごとに確認する。

## 書き起こしと再書き起こし

録音ログに出たセッションIDを渡す。

```sh
mise run app --headless transcribe 85F87F2C-0396-475A-8B1F-548C75F94E01
```

最終行が `HEADLESS OK transcribe self=<件数> remote=<件数> ...` となり、`segments.json` と `transcript.md` が存在することを確認する。件数だけで判断せず、両音声を聞き、発話の先頭・中間・末尾と話者、タイムスタンプを Markdown と照合する。読み取り時のポリシーで一部の低信頼な発話が非表示になるため、必要なら segments の内容も確認する。

メインウィンドウで録音を選ぶと、Markdownと同じ読み取りポリシーを通した発話を、時刻・話者・本文の一覧で読める。本文を選択してコピーできる。「Markdown をコピー」は、手編集を含めファイルの内容をそのままコピーする。日付が `2026/11/10 10:54` のように表示されることも確認する。

詳細の「再書き起こし」で再実行すると、成功時に旧 Markdown が `transcript.prev.md` へ移る。失敗・キャンセルでは前の成功結果を保持する。モデル導入後は Wi-Fi を切った状態でも同じ書き起こしを確認し、通信の有無は `nettop` 等で別途観測する。通常の書き起こしはローカルのモデル・tokenizer を使い、未導入時に自動ダウンロードしない。

## 停止・終了・強制終了からの復元

正常停止はアプリの「録音を停止」、または headless の指定秒数の完了を使う。通常UIの「終了」は `stopForQuit` を待って終了し、その場では AAC 化せず次回起動で復元する。起動元ターミナルの Ctrl-C をアプリの正常停止として扱わない。

強制終了の確認は、失ってよい確認用セッションで人間が行う。

1. 確認用以外のアプリインスタンスが録音中でないことを確認して通常終了し、`mise run app --headless record --seconds 120 --company killtest --target com.google.Chrome` を実行する。
2. 別端末で、ログに出たフォルダの `capture.lock` を `lsof` で調べ、対象録音アプリの PID を確認する。別インスタンスの PID と取り違えない。
3. 確認した PID に `kill -KILL` を送り、`mise run app` で起動し直す。
4. 元のフォルダに m4a が生成され、`meta.json` が `endReason: recovered` になることを確認する。`afinfo` と再生で長さ・末尾を確認する。
5. 最近の録音に「文字起こし待ち」として現れ、自動では書き起こしを始めないこと。人間が「文字起こし」を押すと完了すること。

別プロセスがリースを保持する録音中のフォルダは、別インスタンスの起動時復元が触らない。復元済みフォルダは、もう一度起動しても音声を失わない。SIGKILL の確認結果は電源断・カーネルパニック時の損失を保証しない。

## 入力の異常・長時間の確認

- Rubix44 の抜き差しと選択チャンネルを確認する。切断や実際の入力フォーマット変更は track failure とし、別デバイスへの自動切り替えやエンジンの自動再起動は行わない。
- 内蔵マイクを選び直し、メーターが動き続けること。`AVAudioEngineConfigurationChange` は、running・同一デバイス・同一入力フォーマットのときだけ無視する。
- 内蔵マイクを蓋を閉じて使う場合のデジタル無音警告、20秒の低レベル警告を確認する。実機の挙動は機種・設定に依存する。
- 5分の Meet/Zoom 通話で音声分離と Markdown の発話を照合する。長時間のドリフトは診断値と実際の発話時刻の両方で評価する。
- Setup を開いたまま話し、メーターが毎秒初期化されないこと。選んでいないデバイスの出現でプレビューが再起動しないこと。閉じたとき・録音開始時にはプレビューが止まること。

## 2026-11-10 の実機結果

リードとユーザーが内蔵マイク＋Chromeで実行。サンプルレートはすべて48,000 Hz。peak は最終 m4a を読み取った値で、表では小数第3位に丸めた。

| セッション | トラック | frames | 長さ（秒） | peakDBFS |
| --- | --- | ---: | ---: | ---: |
| `2026-11-10_1040_smoke`（30秒指定） | self | 1,344,000 | 28.000 | -20.228 |
| 同上 | remote | 1,441,920 | 30.040 | -1.633 |
| `2026-11-10_1043_smoke2`（60秒指定） | self | 2,884,800 | 60.100 | -14.078 |
| 同上 | remote | 2,882,880 | 60.060 | -1.888 |
| `2026-11-10_1049_killtest`（強制終了後の復元） | self | 2,299,200 | 47.900 | -22.353 |
| 同上 | remote | 2,293,440 | 47.780 | -1.722 |

録音フォルダは `~/Library/Application Support/InterviewRecorder/Recordings/` 以下。証拠は各 `meta.json` と以下のローカルログにある。

- 30秒: `build/logs/20261110-104009-959.stderr.log`。self は remote より約0.1秒早く始まったが約2秒短かった。両トラックの gapCount/overlapDroppedFrames は0、failureなし。この差は1回だけ発生し、原因は未確定。
- 60秒: `build/logs/20261110-104351-3028.stderr.log`。両トラックの長さはほぼ一致し、gapCount/overlapDroppedFrames は0。2秒の差は再現しなかった。fake で末尾20×4800フレームを stop 時に追加するテストも、CAF・AACとも全300バッファを保持した。
- 書き起こし: `build/logs/20261110-104506-3470.stderr.log`。導入済み turbo で self 8・remote 27セグメントが得られた。segments の実範囲は self 0〜60.100秒、remote 約0.127〜42.227秒。初回30秒の self 0・remote 3件が末尾だけとなった件は、60秒の追試で再現せず、リードは初回の録音内容・スピーカー再生の影響と判断して比較調査を中止した。
- 復元: `build/logs/20261110-104903-4960.stderr.log`（録音）と `20261110-105012-5723.stderr.log`（再起動）。リードが約45秒付近で kill -9 を送り、再起動後に約47.8秒の音声が復元された。内訳は表のとおり。`endReason: recovered`、`endedAt: 2026-11-10T01:49:50Z` を確認。起動時には書き起こしを始めなかった。

内蔵マイクのメーターが -120 固定だった件は修正済み。`build/logs/20261110-091505-78178.stderr.log` では、開始約69ms後の構成変更通知を致命的に扱い、running=true のまま0チャンクで終了していた。修正後の `20261110-091841-80783.stderr.log` では device=110・48kHz・1ch が不変で running=true の通知を無視し、4800フレームを受信、2秒後も稼働した。一時計測ログはソースから除去済み。

SETUP 行の反復は1秒poll内の無条件ログだった。状態変更時のみ出力するよう改め、プレビューキーからデバイス一覧全体を外した。private aggregate は composition の private キーで除外する。

この日の実機確認だけでは、Rubix44 の再確認、Zoom/Meet の5分通話、通信不発生の実測、長時間ドリフトまで確認済みとはしない。

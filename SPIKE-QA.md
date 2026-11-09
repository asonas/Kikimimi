# Phase 0 録音確認

## 起動と権限

1. `./scripts/build-app.sh` を実行する。固定の Bundle ID は `as.ason.InterviewRecorder`。署名の既定値は `Apple Development: Yuya Fujiwara (55CYFEJC5B)` で、環境変数 `CODE_SIGN_IDENTITY` で変更できる。Hardened Runtime とタイムスタンプを有効にし、`com.apple.security.device.audio-input=true` の entitlement を付ける。
2. Zoom を起動し、イヤホンを使って通話へ参加する。録音する相手へ事前に確認する。
3. `./scripts/run.sh --app us.zoom.xos --duration 300 --out "$PWD/recordings/zoom-01"` を実行する。出力先は毎回新しい絶対パスを使う。
4. 表示された stderr ログを確認する。初回は画面収録権限を要求し、最大60秒、1秒間隔で許可を待つ。許可された場合も再起動が必要な旨を記録して終了する。macOS の許可ダイアログと「システム設定 > プライバシーとセキュリティ」で InterviewRecorderSpike を許可し、再実行する。マイクのダイアログも人間が許可する。マイクは要求の結果を待ってから判断する。
5. `open -W` 自体の終了コードは録音アプリの終了コードを表さないため、成功はログの `Finished:` と `meta.json` の `errors: []` で判定する。

画面収録が未許可の段階ではマイクを要求しない。マイクを拒否した場合は不足権限をログに出して終了する。権限未許可時に音声ファイルは作成しない。

## 音声と時刻

`./scripts/run.sh --list-input-devices` は入力デバイスの名前、UID、入力ch数、システム既定かどうかを stdout に出して終了する。権限は要求しない（stdout の保存先はスクリプトの表示を参照）。

`--input-device Rubix44 --input-channel 1` で Rubix44 の INPUT 1 だけを mono に保存できる。デバイスは名前の完全一致または UID 一致を優先し、一致しなければ名前の部分一致で選ぶ。候補が複数ある場合や見つからない場合は一覧を含むエラーになる。チャンネルは1始まりで、範囲外はエラーになる。両オプションを省略するとシステム既定入力を従来どおり mono 変換する。

例: `./scripts/run.sh --app com.google.Chrome --input-device Rubix44 --input-channel 1 --duration 5 --out "$PWD/recordings/task04-01"`

`meta.json` の `self.inputDeviceUID` と `self.inputChannel`（未指定なら null）、およびトップレベルの `inputDeviceName` が実際の入力と一致することを確認する。

1. 通話相手の声と自分の声を交互に入れる。同時に別アプリから音を出す。
2. `audio-remote.m4a` に Zoom の音だけ、`audio-self.m4a` にマイク音だけが入ることを再生して確認する。イヤホン使用でスピーカーからの回り込みを避ける。
3. `meta.json` の両トラックについて `firstSampleHostTimeSeconds`、`sampleRate`、`sourceChannels`、`channels: 1`、`frames > 0` を確認する。開始時刻は SCStream の synchronizationClock から host clock へ変換した値と、マイクの hostTime を秒へ変換した値。別々に開始するため値の一致は求めず、差を開始オフセットとして扱う。
4. 入力デバイス名・対象アプリ・録音秒数を確認する。音声ごとの収録長は `frames / sampleRate`。長時間のクロックずれやサンプル欠落の補正はこのスパイクにはない。
5. Chrome も `--app com.google.Chrome` で同様に確認する。`--app` を省略すると全システム音（この録音プロセスを除く）が対象になる。

SCStreamOutput は `.audio` だけを登録している。映像出力は登録せず、設定上は 2 × 2、1 fps。実際に映像出力なしで録音できるかは権限許可後に確認する。

## 停止と再ビルド

1. `--duration 300` で起動し、stderr ログ冒頭の `InterviewRecorderSpike PID:` を確認する。別端末から `kill -INT <PID>` を送り、両 m4a が再生でき、meta.json が保存されることを確認する。新しい出力先で `kill -TERM <PID>` も確認する。起動スクリプト上の Ctrl-C は `open` を止めるため、アプリへの SIGINT はこの方法で送る。
2. 許可後に `./scripts/build-app.sh` で再ビルドし、新しい出力先で再録音する。画面収録・マイクの許可が保持され、再度の許可が不要か確認する。
3. 初回拒否状態を再試験する場合のみ、人間が `tccutil reset ScreenCapture as.ason.InterviewRecorder` と `tccutil reset Microphone as.ason.InterviewRecorder` を実行する。自動検証では権限をリセットしていない。

## 自動検証

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` は引数検証、デバイス選択（既定・名前完全一致・UID・部分一致・不明・曖昧）、合成4ch PCM の指定チャンネル抽出、未指定チャンネルの null 出力を検証する。既存の合成ステレオ PCM の mono AAC 保存・再読込・開始ホスト時刻の検証も行う。

Task 01 の署名設定では、実機で全システム音の5秒録音、SIGINT/SIGTERM中断後のファイル生成を確認済み。Task 02 で Bundle ID を `as.ason.InterviewRecorder` に変更し、Hardened Runtime を有効化した後は、ビルド・署名・2件のテスト成功と、`open` 経由の起動で画面収録権限不足をログに出して終了することを確認した。新 Bundle ID での録音、実際の通話分離、拒否後の再許可操作、Zoom通話を含む再ビルド後のTCC保持は上記の手動確認が必要。

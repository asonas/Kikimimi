# ADR-0003: XcodeGen アプリと core/ パッケージに分ける

## Status

Accepted — 2026-11-09

## Context

Phase 0 の手組みアプリバンドルは実験に使えたが、継続開発では署名・entitlement・Run/Archiveを標準のアプリビルドへ委ねたい。一方、ロジックのテストをホストアプリや署名に依存させたくない。[design.md §10・§15・§17](../design/phase1/design.md) と [SYNTHESIS.md](../design/phase1/SYNTHESIS.md) を根拠とする。

## Decision

`App/` を薄いSwiftUIと依存の組み立てに限定し、`project.yml` からXcodeGenでアプリを生成する。ローカルSwiftPMパッケージ `core/` はSwift 6・macOS 14以上を対象とし、三つのターゲットに分ける。

- `RecorderCore`: Foundationだけに依存するドメイン・純粋ロジック・制御・ポート。
- `RecorderAudio`: AVFoundation・CoreAudio・ScreenCaptureKitなど音声ハードウェアのアダプタ。
- `RecorderWhisper`: WhisperKitをimportする唯一のターゲット。モデルのロード・Track処理順・アンロードを隠す。

テストは `core/` の `swift test`、タスクは `mise.toml` の `generate / test / build / app` に集約する。全構成のBundle IDは `as.ason.InterviewRecorder` に統一し、アプリの起動はLaunchServicesの `open -n` を通す。Phase 0 のTCC許可の引き継ぎはアプリ移行時に実機確認する。

## Consequences

署名なしでロジックをテストでき、WhisperKitアダプタもコンパイル検査の対象になる。手組みバンドルと全コードをアプリターゲットへ置く案は採用しない。WhisperKitをアプリだけに置いてパッケージの再ビルドを避ける案も、設計時の計測が約10秒だったため、アダプタを検査できる利点を優先して却下した。import境界はアーキテクチャテストで検査する。

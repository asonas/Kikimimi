# ADR-0002: 録音と書き起こしを別の状態機械にする

## Status

Accepted — 2026-11-09

## Context

前の Session の書き起こしが待機中でも、次の面接は開始できる必要がある。一つの状態遷移を `transcribing` で終える設計では、録音の開始条件に書き起こしの中断処理が入り、復元した Session や再書き起こしの扱いも複雑になる。[design.md §6](../design/phase1/design.md#61-recordingphase-capture-only) と [SYNTHESIS.md](../design/phase1/SYNTHESIS.md) で利用者が分離とpauseなしを決定した。

## Decision

録音の `RecordingPhase` は `idle → preparing → recording → stopping → idle` とし、録音開始・停止・Finalizeだけを扱う。`paused` と `transcribing` は持たない。Phase 1 の休憩は停止して新しい Session を開始する。

書き起こしは別の `TranscriptionService` のキューで管理し、状態を `queued / waiting / running / failed / done` とする。一度に一つの Session を処理し、録音開始時は実行中ジョブをキャンセルしてキューへ戻す。録音中は書き起こしを実行しない。通常停止のFinalize成功後は書き起こしへ登録するが、起動時に復元した Session は自動登録せず、利用者が手動で開始する。失敗も自動再試行しない。

メニューバーの状態は録音・キュー・準備状況から導出する。Session の保存状態はファイルから導出し、書き起こし中には録音用 Lease を取得しない。

## Consequences

次の面接を優先でき、復元・再書き起こしも録音状態から独立して扱える。書き起こしのキャンセル完了までの遅延は実装時に検証する。pauseの追加には二つの音源の再開協調とTrackごとの区間管理が必要になり、Phase 1 の対象外とする。

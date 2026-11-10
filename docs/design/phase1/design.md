# InterviewRecorder Phase 1 (MVP)

Implementation note (2026-11-10): the Phase 0 spike has been retired after real capture, transcription and launch recovery passed QA. Current build/run/test commands and measured results are in [docs/qa.md](../../qa.md). The sketch notes and commit plan below retain the design-time sequence; Phase 0 source paths and old app bundles mentioned there are historical, not current launch instructions.

Companion files, all under this directory:

- `sketch/core/` is a compiling SwiftPM package (Swift 6 language mode, three library targets) holding every type and signature named below. Bodies are `fatalError("not implemented")` except the pure pieces that are the executable spec (`RecordingPhase.applying`, `TrackClock.placement/commit`, `CaptureLease`, `PerTrack`/`SessionMeta` Codable, `DigitalSilenceDetector`, `TranscriptionProgress`, `LaunchMode`/`HeadlessCommand` parsing, `AACFinalizer.outputSampleRate`, `WhisperKitEngine.trackOrder`). `swift test` passes 22 tests there (2 skipped: the gated model test and a disabled placeholder), including 2-hour drift simulations of both signs and the lease's exclusivity. Building the tests also compiles the WhisperKit adapter against WhisperKit 1.1.1.
- `sketch/App/`, `sketch/project.yml` and `sketch/mise.toml` show the app shell, the composition root, the DEBUG headless runner and the task runner. `project.yml` was validated by running XcodeGen 2.46.0 on it (project generated, WhisperKit 1.1.1 resolved through the local package). The `App/*.swift` files are not compiled.
- `probe-work/` holds the two experiments run while designing (kill -9 container probe, AAC encode speed). `evidence-a/` holds two more (AAC sample rates, SIGKILL during write). Their numbers are quoted below.
- The sketch is moved into the repo by commit 2 (`core/`, `mise.toml`) and commit 4 (`App/`, `project.yml`) and deleted from here in those same commits, so the code never exists in two places. After that, references to `sketch/...` below mean the repo's copy.
- `SYNTHESIS.md` records how this design was assembled from two independent candidates and which decisions the user made.

Labels used for API and platform facts: **(V)** verified during design, by reading source, compiling against it, or running an experiment on this machine (macOS 27.2, Apple Silicon). **(R)** recalled, not verified; each has a commit in the plan that turns it into (V) or removes the dependency on it.

---

## 0. Decisions in one screen

1. **Two state machines, not one.** `RecordingPhase` (idle, preparing, recording, stopping) owns capture only. Transcription is a separate job queue (`TranscriptionService`). The menu bar status is *derived* from both. DESIGN.md section 5 has one chain ending in `transcribing`; this design departs from it on purpose (section 6).
2. **No pause in Phase 1.** Illegal states are unrepresentable by construction; adding pause later is one new case plus a per-track interval list. A break means Stop and a new session.
3. **Crash safety by construction.** During capture each track is spooled as **CAF, LPCM int16 mono** (append-only). The AAC `audio-*.m4a` is derived from the spool by one idempotent `finalize`, used by both normal stop and launch recovery. Evidence (V): a `kill -9` during an `AVAudioFile` AAC `.m4a` write leaves a file that cannot be opened; the same kill on CAF LPCM reopens with all but the last ~70 ms. Finalize converts a spool above 48 kHz to 48 kHz before AAC, because the AAC encoder fails at 96 and 192 kHz (V).
4. **Timeline correctness is a pure function, and it never deletes speech for drift.** `TrackClock` places every incoming chunk by host time: missing audio becomes padded silence; a fast device clock (file running ahead of host time) is tolerated and only recorded in diagnostics; only a single-step backward jump (duplicated audio) is trimmed. So file time tracks timeline time through skipped buffers, and a 100 ppm device clock costs at most about 0.7 s of timestamp error over 2 hours instead of cutting a word every half hour.
4b. **Liveness is a kernel fact.** Each capture holds a `flock` lease on `capture.lock` in its session folder until finalize. Launch recovery finalizes only folders whose lease is free, so a second app instance, an Xcode Debug run next to an installed copy, or a DEBUG headless run can never finalize a live interview. No part of the design depends on single-instance enforcement. Transcription does not take the lease (a held lease means "capturing").
5. **Data on disk.** meta.json holds capture facts only (first-sample host time per track; offsets are derived, never stored). segments.json is a flat, session-timeline array `{start, end, speaker, text, + engine confidence fields}` as DESIGN.md section 6 specifies, unfiltered. Filtering, coalescing and Markdown rendering are applied at read time, so a better filter improves old sessions without re-transcribing. A folder's state is derived from which files exist; no status string is stored.
6. **Build shape.** XcodeGen app target `App/` (thin: SwiftUI + composition root) plus a local SwiftPM package `core/` with three targets: `RecorderCore` (Foundation-only logic, orchestration, ports), `RecorderAudio` (hardware adapters), `RecorderWhisper` (the only WhisperKit importer). All tests are `swift test` in `core/`. Tasks live in `mise.toml` (`generate`, `test`, `build`, `app`), as in the user's other apps. One bundle ID, `as.ason.InterviewRecorder`, for every configuration, so the Phase 0 TCC grants carry over.
7. **Transcription.** The `Transcriber` port is session-level: per-track audio URLs plus language in, per-track engine segments in file time out. The WhisperKit adapter owns load, track order (remote then self), sequential processing, incremental audio loading and unload; Core owns which tracks to run, normalization, the timeline and the files. One job at a time, never while a recording is active (cancel and requeue on start). Model install (download plus Core ML prewarm) is an explicit user action; `download: false` means transcription cannot touch the network.
8. **Permissions.** Screen-capture readiness is a pure derivation of `(preflightAtLaunch, preflightNow, requestedBefore, probe)` with an explicit "granted, relaunch needed" state; relaunch is user-initiated and goes through LaunchServices (`/usr/bin/open -n`). Mic input is chosen explicitly and persisted by device UID plus channel; a missing device blocks Start and never falls back to the system default.
9. **Mid-recording failures are per track.** One track dying does not stop the other; both dying stops the session. Failure is recorded in meta.json and shown in the UI.
10. **Minimal liveness guard.** A 1 Hz peak meter per track, a silence flag (20 s below -75 dBFS), and a digital-silence flag on the self track (3 s of samples exactly 0.0 from the device), because Phase 0 showed a mic can yield digital silence for a whole interview without any error.
11. **Verifiable without clicking.** DEBUG builds accept `--headless record ...` and `--headless transcribe <id>`, which call the same controller methods as the UI. They are always launched through LaunchServices (`mise run app --headless ...`), so they exercise the app's own TCC grants.

### Decided with the user

These were open during design and are now settled (see `SYNTHESIS.md`):

1. No pause in Phase 1 (0.2, 6.1).
2. Two machines: the recording phase and the transcription queue (0.1, 6.1, 6.2), a departure from DESIGN.md section 5.
3. Sessions recovered at launch are not transcribed automatically; the user starts them from the menu (6.3).
4. Default model `openai_whisper-large-v3-v20240930_turbo` (7).
5. The spool uses about 0.7 GB per hour for both tracks while recording; Start is refused below 5 GB free (4).

### Departures from DESIGN.md and from Phase 0 (so nobody discovers them by surprise)

- Section 5 state chain: split into two machines (6.1, 6.2). `paused` dropped for Phase 1.
- Section 5 "write audio incrementally": still true, but the incremental file is a CAF spool, not the m4a; the Phase 0 spike's incremental AAC is not crash-safe (3 above).
- Section 5 `Pipeline/` (48 kHz to 16 kHz resample, track clock, file writing): there is no 16 kHz resampling module because WhisperKit resamples to 16 kHz mono itself when it loads audio (V, read from source); the clock and writing live in `RecorderCore/Capture/TrackClock.swift` and `RecorderAudio`. The only resampling the app does is in finalize, above 48 kHz down to 48 kHz for the AAC encoder.
- Section 5 directory names (`App/ Capture/ Pipeline/ Transcribe/ Storage/ Export/`) become SwiftPM targets so the boundaries are enforced by the compiler; `Export/` (Obsidian) is Phase 2 and absent.
- Section 6 `segments.json`: kept as the flat `{start, end, speaker, text}` array, with extra engine confidence fields and `schemaVersion`.
- Section 3 "同一クロック (CACurrentMediaTime 系)": the clock is mach host seconds, as the spike measured.
- Added beyond the Phase 1 list: peak meter, silence and digital-silence flags (justified in 0.10), launch recovery (required by the crash-safety constraint), explicit mic choice, DEBUG headless mode (0.11).

---

## 1. Problem and constraints honored

Record an online interview on the user's Mac with no bot: remote audio and the user's mic as separate tracks, then transcribe locally after the recording into a speaker-labeled `transcript.md`. Nothing leaves the machine. Phase 0 proved SCStream audio-only capture, per-app isolation, Rubix44 channel extraction, host-time first-sample anchoring and TCC retention with Apple Development signing. Constraints carried into this design: Swift 6 strict concurrency, macOS 14+, SwiftUI `LSUIElement` menu bar app, Swift Testing, WhisperKit large-v3-turbo behind a `Transcriber` port, DESIGN.md section 6 folder layout, an implementer that works in small commits from this document, and a user whose git rules require worktrees (every worktree has its own `.build`, so test cost per fresh checkout matters).

---

## 2. Usage (caller's view)

### 2.1 Developer README (goes in the repo's README)

```sh
# One-time
mise install                               # xcodegen, from mise.toml [tools]. mise.toml [env] sets DEVELOPER_DIR to Xcode for every
                                           # task (the active dir on this machine is CommandLineTools; swift test and xcodebuild need Xcode)

# Everything testable without hardware, TCC or signing (offline after the first resolve):
mise run test                              # = swift test --package-path core. Extra arguments are appended:
mise run test --filter RecorderCoreTests

# Build and run the app (Automatic signing, team QYP65434UW, bundle ID as.ason.InterviewRecorder):
mise run build                             # xcodegen generate, xcodebuild Debug into build/development, codesign --verify, print the designated requirement
mise run app                               # open -n -W through LaunchServices; stdout/stderr in build/logs/

# DEBUG headless mode: the same controller calls as the UI, without clicking. Needs Setup completed once in the UI (mic choice).
mise run app --headless record --seconds 30 --company smoke --target com.google.Chrome     # --target all = all system audio
mise run app --headless transcribe 6F1C7E1B-3C0D-4C55-9F5B-0A1B2C3D4E5F                   # a session's meta.id
# The result is the last stderr line, printed when the app exits: "HEADLESS OK ..." or "HEADLESS FAILED: ...".

# Gated tests that need the real model (downloads openai_whisper-tiny, ~75 MB):
IR_INTEGRATION=1 mise run test --filter RecorderWhisperTests
```

Rules for contributors (the agent copies the nearest example, so these are enforced by tests where possible):

- File names inside a session folder appear only in `SessionFolder`. JSON for meta/segments is read and written only in `SessionStore`. WhisperKit is imported only in `RecorderWhisper`. Hardware frameworks are imported only in `RecorderAudio`. An architecture test fails the build otherwise (section 12).
- Anything with a policy (what to drop, when to pad, which state is legal, when a mic is digitally silent, how arguments parse) is a pure function in `RecorderCore` with a table test. The SwiftUI layer contains no conditions beyond reading `phase`, `status`, `readiness`.
- Launch the app only through `mise run app` (LaunchServices). Never run `build/.../InterviewRecorder.app/Contents/MacOS/InterviewRecorder` from a terminal: the terminal (Herdr, Ghostty) has its own Screen Recording grant, so the run would pass or fail on the terminal's TCC state, not the app's.

### 2.2 End-user flow

1. First launch opens **Setup**: four rows (Screen Recording, Microphone, Microphone input, Transcription model). Each row is a button until it is green. Screen Recording shows "Granted. Relaunch needed" with a Relaunch button once macOS reports the grant. The mic input row lists input devices (UID, name, channel count) with a channel picker (Rubix44: INPUT 1) and a live meter so the user sees it move before confirming. The model row shows "Not installed (about 1.6 GB)", a Download button, then download progress, then "Optimizing for this Mac (first time only)", then "Ready".
2. Before an interview the menu shows one line: "Ready" or the first blocker, with a button to fix it.
3. **Start recording** opens a small window: Company (required), Title (optional, e.g. 二次面接), Remote audio from (running meeting apps first, then other running apps, then "All system audio"; default is the last choice). Start creates `2026-11-09_1500_Acme/`. Start is refused with a specific message when less than 5 GB is free.
4. While recording the menu bar icon is a red filled circle, the menu shows elapsed time, two peak meters (自分 / 相手), and **Stop**. An amber badge appears if a track failed, has been silent for 20 s, or the self track has delivered digital silence (every sample exactly 0.0) for 3 s; the last one shows "マイクの入力がデジタル無音です。接続とチャンネルを確認してください" under the 自分 meter.
5. Stop shows "Saving audio" for seconds (AAC encode measured at about 576x realtime, so a 90-minute track takes about 10 s (V)), then the session joins the transcription queue and the icon shows progress. Transcription never starts while a new recording is active.
6. The menu's recent list shows each session's derived state (要保存処理, 文字起こし待ち, 文字起こし中, 完了) with Open transcript, Show in Finder, and Transcribe / Re-transcribe. Sessions recovered after a crash appear here as 文字起こし待ち; the user starts them.

### 2.3 Real call sites

**Start button** (`App/NewRecordingView.swift`). Typed errors map to specific, fixable messages; nothing else happens in the view:

```swift
Button("Start") {
    Task {
        do {
            try await env.recorder.start(SessionDraft(company: company, title: title.nilIfBlank, remote: remote))
            dismiss()
        } catch {                                   // typed: StartError
            alert = StartAlert(error)               // .micMissing(pref) -> "Rubix44 is not connected" [Choose another] [Cancel]
        }                                           // .notReady(blockers) -> opens Setup; .remoteAppNotRunning -> "Chrome is not running"
    }
}
.disabled(!env.readiness.readiness.canRecord || company.isBlank || env.recorder.phase != .idle)
```

**Stop, status, recent list** (`App/MenuView.swift`):

```swift
Button("Stop") { Task { await env.recorder.stop() } }          // returns when phase is .idle again (finalize included)

switch env.status {                                             // AppStatus, derived from phase + jobs + readiness
case .recording(let since, let trackProblem): RecordingRow(since: since, levels: env.recorder.levels, warn: trackProblem)
case .transcribing(let fraction, let queued): ProgressRow(fraction, queued)
...
}
Button("Re-transcribe") { env.transcription.enqueue(listing.ref) }   // idempotent; replaces segments.json only on success
```

**Launch** (`AppEnvironment.live()` end): recovery makes audio safe and visible; it never transcribes:

```swift
launched = Task {
    let recovered = (try? await LaunchRecovery.run(store: store, finalizer: finalizer)) ?? []   // finalize interrupted/unfinalized sessions
    if !recovered.isEmpty { notices.post(.recovered(recovered)) }                                // "前回の録音を回復しました (2)"; user decides to transcribe
    await readiness.refresh()
}
```

**DEBUG headless** (`App/HeadlessRunner.swift`, `#if DEBUG`). A second caller of the same methods, not a second implementation:

```swift
case let .record(draft, seconds):
    await env.launched.value
    guard env.readiness.readiness.canRecord else { fail("notReady \(env.readiness.readiness.blockers)") }   // never requests a permission
    try await env.recorder.start(draft)                  // the Start button's call
    try await Task.sleep(for: .seconds(seconds))
    await env.recorder.stop()                            // the Stop button's call
    ok("\(ref.folder.url.path) \(meta.id)")              // then exit; the enqueued transcription is abandoned, nothing partial is written
case let .transcribe(id):
    env.transcription.enqueue(ref)                       // the Re-transcribe button's call; then observe env.transcription.jobs until .done/.failed
```

**Test call site** (no hardware, no TCC; `RecorderCoreTests/RecordingControllerTests.swift`):

```swift
@Test func micMissingBlocksStartAndCreatesNoFolder() async throws {
    let fx = try Fixture(devices: [.builtIn], micPreference: .rubix44ch1)   // temp-dir SessionStore, FakeBackend, FakeFinalizer
    await #expect(throws: StartError.micMissing(.rubix44ch1)) { try await fx.controller.start(fx.draft) }
    #expect(try await fx.store.list().isEmpty)
    #expect(fx.controller.phase == .idle)
}
```

---

## 3. Shape

### 3.1 Module map (file paths are the repo layout after Phase 1)

```
project.yml                              XcodeGen. xcodeproj is generated and gitignored (as in yohaku).
mise.toml                                tasks generate / test / build / app; [env] DEVELOPER_DIR, APP_PATH (stable Debug product path)
App/                                     target InterviewRecorder (SwiftUI + composition root; no policy)
  InterviewRecorderApp.swift             @main, MenuBarExtra(.window), Window "New Recording", Window "Setup",
                                         AppDelegate (reads LaunchMode once; single-instance nicety; quit handling; starts the headless runner)
  AppEnvironment.swift                   the ONLY file that names concrete types; builds everything; starts LaunchRecovery (`launched`); relaunch()
  HeadlessRunner.swift                   #if DEBUG: runs one HeadlessCommand against env.recorder / env.transcription; prints HEADLESS OK|FAILED
  MenuView.swift NewRecordingView.swift SetupView.swift StatusIcon.swift StartAlert.swift
  Info.plist  InterviewRecorder.entitlements   (generated from project.yml `info:` / `entitlements:`)
core/Package.swift                       package "RecorderKit"; tools 6.0; language mode 6; only dependency: WhisperKit >= 1.1.1 (RecorderWhisper only)
core/Sources/RecorderCore/               Foundation + Observation only
  Domain/Track.swift                     Track (self|remote), PerTrack<V> (sparse, persisted), TrackPair<V> (total, in-memory)
  Domain/Session.swift                   SessionDraft, RemoteSource, SessionFolder (all file names), SessionRef, EndReason, TrackFailure
  Domain/SessionMeta.swift               SessionMeta + CaptureStatus + TrackMeta/TrackSource/TrackAudio/ClockDiagnostics (+ Codable)
  Capture/TrackClock.swift               pure placement/gap policy                                        [implemented]
  Capture/DigitalSilence.swift           DigitalSilenceDetector: self track, >= 3 s of exact 0.0 source samples [implemented]
  Capture/Ports.swift                    CaptureBackend, RunningCapture, CapturePlan, CaptureEvent, AudioFinalizer, InputDeviceCatalog, MicResolution
  Storage/SessionStore.swift             FolderNamer, CaptureLease (flock) [implemented], SessionClassifier, SessionState,
                                         SessionStore (actor; sole owner of meta/segments/transcript files)
  Lifecycle/RecordingPhase.swift         state enum + pure reducer + effects; TrackHealth                    [implemented]
  Lifecycle/RecordingController.swift    @MainActor @Observable owner of `phase`; start/stop/stopForQuit
  Lifecycle/SessionFinalizer.swift       SessionFinalizer (stop and recovery share it) + LaunchRecovery
  Lifecycle/LaunchMode.swift             LaunchMode (normal | relaunched | headless) + HeadlessCommand parsing [implemented]
  Transcript/Segments.swift              EngineSegmentDTO, EngineOutput.normalize, TimelineSegment, SegmentsFile, TranscriberIdentity
  Transcript/TimelineAndReading.swift    SessionTimeline, TimelineBuilder, ReadingPolicy, TranscriptReader, TranscriptRenderer
  Transcript/Transcriber.swift           Transcriber (session-level) + ModelProvider ports, TranscriptionProgress [implemented],
                                         TranscriptionJob, TranscriptionSchedule, TranscriptionService
  Readiness/Readiness.swift              ScreenCaptureAccess.derive, MicAccess, ModelStatus, Readiness, PermissionProbe, ReadinessModel
  Readiness/SettingsAndSilence.swift     Settings, ModelSpec, SettingsStore, SilenceMonitor (levels + digital-silence merge)
  Readiness/AppStatus.swift              AppStatus.derive(phase, jobs, readiness)
core/Sources/RecorderAudio/              AVFoundation, CoreAudio, ScreenCaptureKit; everything internal except `LiveAudio`
  Audio.swift (split per type in the real repo): AudioSource, MicSource, RemoteAppSource, TrackRecorder, SpoolWriter,
  AACFinalizer (48 kHz cap), CoreAudioInputDevices, SystemPermissionProbe, TwoTrackCapture, LiveAudio (the 4 public factories)
core/Sources/RecorderWhisper/WhisperKitEngine.swift   actor WhisperKitEngine: Transcriber, ModelProvider
                                         (per-session load/unload, remote then self, .incremental loading); LiveWhisper.engine(...)
core/Tests/RecorderCoreTests/ (+ Fixtures/)  RecorderAudioTests/  RecorderWhisperTests/ (model test gated)
docs/adr/0001..0003, GLOSSARY.md         per this repo's docs/agents/domain.md
```

Dependency rule: App -> {Core, Audio, Whisper}; Audio -> Core; Whisper -> Core; Core -> nothing. Only `AppEnvironment.swift` mentions Audio/Whisper types.

### 3.2 Interface depth: what each module hides

| Module | Public surface the App uses | Hidden behind it |
|---|---|---|
| `RecordingController` | `phase`, `levels`, `start(draft)`, `stop()`, `stopForQuit()` | readiness gate, mic resolution, remote-app resolution, disk check, folder creation, backend start/rollback, event consumption, silence monitor, reducer and effects, finalize, hook to the queue |
| `TranscriptionService` | `model`, `jobs`, `enqueue`, `cancel`, `installModel`, `setRecordingActive` | scheduling, model gating, silent/missing-track skip, progress combination, DTO normalize, timeline build, atomic save, transcript backup |
| `SessionStore` | `create`, `meta`, `update`, `list`, `state`, `segments`, `saveTranscription`, `rerenderTranscript`, `discardIfEmpty` | folder naming and collisions, JSON schemas and versions, atomic writes, state classification, rendering call |
| `ReadinessModel` | `readiness`, `refresh`, 3 request actions | TCC quirks (request-then-relaunch, probe), polling, device lookup |
| `LiveAudio` | 4 factories | SCStream, AVAudioEngine, CoreAudio, CAF spool, AAC encode and 48 kHz cap, clock policy and digital-silence detector application |
| `LiveWhisper` | 1 factory returning both ports | model layout, install completeness, prewarm, per-session load/unload, track order, incremental loading, VAD options, Swift 5 -> 6 boundary |
| `LaunchMode` | `parse(arguments)`, `skipsSingleInstanceCheck` | flag names, headless argument grammar and validation |

`Transcriber` is one session-level method plus `identity`. `CaptureBackend` is `start` plus the candidate list. These are the swap seams (SpeechAnalyzer; Core Audio Tap) and they are no wider than the swap needs.

### 3.3 Data structures first: access patterns traced

- **"Show me the recent sessions and their state."** `SessionStore.list()` scans `root`, reads each `meta.json`, builds a `FolderInventory` (which spool/m4a/segments files exist), classifies with the pure `SessionClassifier`. No index, no cache: the folder is the truth, so there is nothing to keep in sync, and a few hundred small files is trivial. A user renaming a folder in Finder breaks nothing because identity is `meta.id`.
- **"Produce the transcript."** `meta + segments.json -> TranscriptReader.lines (filter, coalesce) -> TranscriptRenderer`. Pure, so regenerating after a policy change is `rerenderTranscript` with no engine.
- **"Which tracks exist and where do they start."** `meta.tracks[t].firstSampleHostSeconds`. `SessionTimeline.offsets` computes `first - min(first)`. One definition of "duration": `max(offset + audio.durationSeconds)`.
- **"What is the state of this folder."** Derived (table in 6.3). If the answer needed "we will add a status field", the structure would be wrong; it does not.

---

## 4. On-disk format

```
2026-11-09_1500_Acme/
  meta.json               capture facts (SessionStore is the only writer)
  capture.lock            flock held by the capturing process until finalize/quit; the kernel releases it on process death
  audio-self.spool.caf    LPCM int16 mono at the source rate, append-only, exists only between capture start and finalize
  audio-remote.spool.caf
  audio-self.m4a          AAC 64 kbps mono at the spool rate capped at 48 kHz; appears atomically (written as .m4a.part, then renamed)
  audio-remote.m4a
  segments.json           machine-readable source of truth for the transcript (written once per successful transcription)
  transcript.md           rendered view; previous version kept as transcript.prev.md
```

Disk cost while recording (V, measured): the spool is **57 MB per 10 minutes per track = 345 MB per hour per track**, about 0.7 GB per hour for both, transient. The final m4a is 5 MB per 10 minutes per track (30 MB per hour). Start refuses below 5 GB free (`StartError.insufficientDisk`), which covers about 7 hours of spool.

### 4.1 meta.json (schemaVersion 1)

```jsonc
{
  "schemaVersion": 1,
  "id": "6F1C7E1B-3C0D-4C55-9F5B-0A1B2C3D4E5F",       // identity. The folder name is only a label.
  "company": "Acme",
  "title": "二次面接",                                  // optional
  "timeZone": "Asia/Tokyo",                            // so the local date and folder name are re-derivable
  "startedAt": "2026-11-09T06:00:12Z",                 // ISO 8601 UTC, whole seconds
  "endedAt": "2026-11-09T07:28:53Z",                   // absent while capture is in progress
  "endReason": "user",                                 // user | quit | captureLost | recovered. Present iff endedAt is. Decoder rejects half-states.
  "app": { "version": "0.1.0", "build": "1", "os": "27.2" },
  "clock": "mach-host-seconds",                        // firstSampleHostSeconds values are comparable only within one boot
  "tracks": {                                          // a track key is absent only if that source was never part of the session
    "self": {
      "source": { "kind": "mic", "deviceUID": "AppleUSBAudioEngine:...", "deviceName": "Rubix44", "channel": 1, "deviceChannels": 4 },
      "firstSampleHostSeconds": 812345.612,            // written BEFORE the first spool byte (write-ahead); the only owner of this fact
      "audio": { "file": "audio-self.m4a", "sampleRate": 48000, "frames": 255312000, "peakDBFS": -3.2 },   // derived by finalize from the m4a, overwritten every run
      "diagnostics": { "gapFillFrames": 0, "gapCount": 0, "overlapDroppedFrames": 0, "maxAbsDriftSeconds": 0.012 },  // live stop path only; absent after crash recovery
      // "failure": { "code": "deviceLost", "message": "...", "atSeconds": 1834.2 }   key omitted when there is no failure
    },
    "remote": {
      "source": { "kind": "app", "bundleID": "com.google.Chrome", "name": "Google Chrome" },   // or { "kind": "allSystemAudio" }
      "firstSampleHostSeconds": 812345.431,
      "audio": { "file": "audio-remote.m4a", "sampleRate": 48000, "frames": 255320000, "peakDBFS": -11.8 },
      "diagnostics": { ... }
    }
  }
}
```

Invariants: `endedAt` and `endReason` are both present or both absent. `audio` is absent until finalize and is always recomputable from the files. `audio.sampleRate` and `audio.frames` describe the m4a (the encoded rate, at most 48 kHz), so `frames / sampleRate` is the track's duration whatever the source rate was. Offsets are not stored: here the remote track started 0.181 s earlier, so timeline origin is the remote's first sample and `self` has offset 0.181. A file with `schemaVersion` greater than the app supports classifies as `.unusable` and is never rewritten. Unknown extra keys are ignored on read. `meta.tracks[*].audio.isEffectivelySilent` is `peakDBFS <= -70`.

Transcription provenance is deliberately not in meta.json (it describes the segments, so it lives in segments.json). This is what makes "re-transcribe" a pure replacement of two files.

### 4.2 segments.json (schemaVersion 1)

```jsonc
{
  "schemaVersion": 1,
  "createdAt": "2026-11-09T07:41:02Z",
  "transcriber": { "engine": "whisperkit", "engineVersion": "1.1.1",
                   "model": "openai_whisper-large-v3-v20240930_turbo", "language": "ja", "chunking": "vad" },
  "tracks": { "self": "transcribed", "remote": "transcribed" },   // transcribed | skippedSilent | skippedNoAudio  ("no segments" is distinguishable from "not run")
  "segments": [                                                   // session-timeline seconds (t=0 = earliest first sample), total order (start, end, remote-before-self, index)
    { "start": 192.411, "end": 197.020, "speaker": "remote", "text": "では、まず自己紹介からお願いします。",
      "avgLogprob": -0.18, "noSpeechProb": 0.01, "compressionRatio": 1.31 },
    { "start": 220.804, "end": 224.150, "speaker": "self",   "text": "はい、藤原と申します。", "avgLogprob": -0.22, "noSpeechProb": 0.02, "compressionRatio": 1.2 }
  ]
}
```

This follows DESIGN.md section 6 (`{start, end, speaker, text}` array, flat, merged), adds the engine confidence fields, and is **unfiltered**: hallucination dropping, symbol-only dropping and coalescing happen in `TranscriptReader` at render time. The field stays `speaker` (DESIGN.md section 6), with values `self | remote` in Phase 1; Phase 3 diarization adds an optional `speakerIndex` beside it. A consumer that wants the clean view reads transcript.md; one that wants engine output reads this file and needs nothing from meta.json.

Rejected on the way here: per-track segments in track-local time plus offsets in meta.json. It is lossless but forces every consumer (Phase 2 Obsidian export, scripts) to join two files and reapply offsets, which leaks the offset rule. The offset is fixed at capture and never changes, so applying it once when the transcript is written loses nothing.

### 4.3 transcript.md

```markdown
---
type: interview-log
company: "Acme"
date: "2026-11-09"
duration: "01:28:41"
---

# Acme 二次面接（2026-11-09）

[00:03:12 相手] では、まず自己紹介からお願いします。
[00:03:40 自分] はい、藤原と申します。……
```

Front-matter strings are emitted as YAML double-quoted scalars with escaping (a company named `A: B "x"` must not break the YAML). Date is in `meta.timeZone`. Duration is `SessionTimeline.duration`, not wall clock. Timestamps are `floor(start)` as `HH:MM:SS`; hours are not wrapped at 24. Consecutive same-speaker segments merge into one line when the gap is under 2 s and the line stays under 45 s; the policy lives in `ReadingPolicy`, one list, one place.

Re-transcribing replaces transcript.md and keeps exactly one previous version as `transcript.prev.md`. Phase 1's transcript.md lives in the app's folder and is not meant to be edited there (Phase 2 copies it to Obsidian), so there is no hand-edit detection; Phase 2 revisits that when it overwrites the Obsidian copy.

---

## 5. The capture pipeline

```
SCStream audio ──┐                                     ┌─ level events (1 Hz peak) ─────────────▶ RecordingController ─▶ SilenceMonitor ─▶ phase/UI
                 ├─▶ AudioSource ─▶ TrackRecorder ─────┤                                                ▲
AVAudioEngine ───┘   (timestamped    │  willWriteFirstSample (await meta.json write)   then             │
                      mono chunks)   ├─ DigitalSilenceDetector (self only, SOURCE samples) ─ digitalSilence events
                                     ├─ TrackClock.placement ─▶ SpoolWriter ─▶ audio-<t>.spool.caf
                                     └─ source throws ─▶ close spool, emit .trackFailed
stop():  stop sources, drain, close spools ─▶ SessionFinalizer.run ─▶ AACFinalizer (≤ 48 kHz) ─▶ audio-<t>.m4a (+ meta.audio) ─▶ enqueueTranscription
```

- **One recorder for both sources.** `AudioSource` yields `AsyncThrowingStream<AudioChunk>` (mono Float samples, source rate, host seconds of the first sample). Mic and remote differ only in how chunks are produced (Phase 0 code: `extractChannel`, `CMSyncConvertTime`, `inputFormat(forBus: 0)`). A Phase 2 Core Audio Tap backend is another `AudioSource`. Using `AsyncStream.yield` in the realtime callbacks avoids the spike's lock-and-write-on-callback pattern; the buffering policy is unbounded, so audio is never dropped for backpressure, and disk work happens on the consumer task.
- **Write-ahead.** `TrackRecorder` awaits `plan.willWriteFirstSample(track, hostSeconds)` before creating the spool. The controller implements it as a `store.update` of `firstSampleHostSeconds`. So meta.json always has the anchor for any audio that exists, and recovery needs nothing from the dead process. This keeps one writer for meta.json (no split ownership with the capture layer).
- **`TrackClock`** (pure, implemented and tested). `drift = chunkHost - (first + framesPlaced/rate)`. The policy is deliberately **asymmetric, because losing speech is worse than a timestamp that is a few hundred ms off**:
  - `drift > +tolerance` (default 0.1 s, more than one 85 ms buffer): host time ran ahead of the file, audio is missing. Pad that much silence (`padSilence`). Never loses speech; a device clock 100 ppm slow gets about 7 small pads over 2 h (about 0.7 s total).
  - `drift < -tolerance` by slow accumulation (a device clock running fast, so the file runs ahead of host time): **keep appending**, only record it in `maxAbsDriftSeconds`. About 0.72 s ahead after 2 h at 100 ppm.
  - A single-step backward jump (drift falls by more than `backwardJump`, default 0.5 s, between consecutive chunks: duplicated or re-delivered audio, a timestamp reset): trim that much from the head of the chunk (`dropLeading`, capped at the chunk length).
  A symmetric policy (drop audio whenever drift passes -tolerance) was rejected: a 50-100 ppm fast clock would then cut about 100 ms of speech every 17-35 minutes. The diagnostics (`gapCount`, `gapFillFrames`, `overlapDroppedFrames`, `maxAbsDriftSeconds`) are stored so the constants can be tuned from real recordings. It is unknown (R, untestable without a live call) whether SCStream delivers buffers during silence; the clock makes the answer irrelevant for correctness.
- **Digital silence** (`DigitalSilenceDetector`, pure, implemented and tested). The self track's detector receives every chunk's samples **before** `TrackClock` places it, so it sees only what the device delivered. A run of consecutive samples exactly equal to 0.0 lasting 3 s of source frames turns it on; the first non-zero sample turns it off. Padded silence is never fed to it, so a gap fill neither triggers nor resets it (feeding padded zeros would warn on every gap). A real mic has a noise floor and never produces exact zeros for 3 s; the clamshell built-in mic in Phase 0 did. The remote track is not watched (`forTrack(.remote)` is nil): it is legitimately exact silence while nobody talks. Changes are emitted as `CaptureEvent.digitalSilence(track, active:)`.
- **Durability beyond `kill -9`.** (V) only `kill -9` was tested; power loss or a kernel panic can also lose unflushed page cache, which was not measured. `SpoolWriter` calls `fsync` about every 5 s of audio (R: cost not measured, expected negligible at 96 KB/s) to bound that loss; the recovered CAF is still readable up to the last flushed byte.
- **Sample-rate change.** The spool's rate is fixed at the first chunk. A chunk with a different rate fails that track (`formatChanged`), as the spike did, except the other track keeps recording and the spool is closed cleanly.
- **Sample rate above 48 kHz.** The spool keeps the source rate (a Rubix44 can run at 96 kHz). `AACFinalizer` converts a spool above 48 kHz to 48 kHz with `AVAudioConverter` before writing AAC, because the encoder fails at 96 and 192 kHz and succeeds at 44.1 and 48 kHz (V, `evidence-a/aac-sample-rates.swift`). Rates at or below 48 kHz are encoded unchanged. The verify step compares the m4a's frames with the spool's frames converted to the output rate.
- **Level and silence.** Each recorder reports the peak per second. `SilenceMonitor` (pure) is the single owner of a track's non-failure health: it turns level events into `live` / `silent` (below -75 dBFS for 20 s) and merges the digital-silence signal with precedence `digitallySilent > silent > live > waitingForAudio`. `silent` is informational: the remote track is normally silent before the interviewer joins. `digitallySilent` is a device problem and gets a specific message. At finalize the overall `peakDBFS <= -70` marks a track as effectively silent and transcription skips it.

### 5.1 Failure matrix while recording

| Event | Detected by | Result |
|---|---|---|
| Mic device unplugged / aggregate device change | `AVAudioEngineConfigurationChange`, stream error | `me` track `failed(deviceLost)`; spool closed; remote continues; amber icon; failure written to meta.json |
| Mic sample rate changes (Bluetooth profile switch) | chunk rate differs from the spool's, or config change | `failed(formatChanged)`, same handling |
| Mic delivers digital silence (clamshell built-in mic, a wrong or dead channel) | `DigitalSilenceDetector` on source samples, 3 s | `me` health `digitallySilent`; amber badge plus "マイクの入力がデジタル無音です"; recording continues (the user decides) |
| Target app quits (Zoom ends, Chrome closed, relaunch gets a new PID) | `SCStreamDelegate.didStopWithError`, app absent | `remote` track `failed(targetAppQuit)`; mic continues. No auto re-attach in Phase 1; `TrackClock` already supports resuming a source into the same spool later (the gap is padded) |
| Screen-recording permission revoked | SCStream stop error | `failed(streamStopped)` on remote |
| Disk full | spool write throws | `failed(writeFailed)` on that track |
| Both tracks failed | reducer rule | phase goes to `stopping(.captureLost)`, finalize keeps whatever audio exists |
| App crash or `kill -9` (V) | next launch | recovery (section 6.3) |
| Power loss, kernel panic | next launch | same recovery, but only up to the last flushed byte (R: not tested; mitigated by periodic `fsync`) |
| App quit while `preparing` | `applicationShouldTerminate` | `stopForQuit` awaits the in-flight start, then stops; the quit reply always fires (10 s timeout) |
| System sleep | clocks keep host time | the gap becomes padded silence; not a design target |

---

## 6. State models

### 6.1 `RecordingPhase` (capture only)

```
              startRequested                 prepared(ref)                   stopRequested(reason)
   idle ─────────────────────▶ preparing ───────────────────▶ recording ──────────────────────────▶ stopping
     ▲                           │ prepareFailed                 │ trackHealthChanged (both failed ─▶ stopping(.captureLost))     │
     │◀──────────────────────────┘                               │                                                                │ captureStopped
     │                                                                                                                            ▼
     │◀───────────────── finalizeSucceeded (effect: enqueueTranscription) / finalizeFailed ◀──────── (effect: finalize)  stopping
     │◀───────────────── captureStopped when reason == .quit (finalize deferred to next launch)
```

- States carry exactly what is valid in them: `idle` nothing, `preparing(SessionDraft)`, `recording(ref, startedAt, health: TrackPair<TrackHealth>)`, `stopping(ref, reason)`. `TrackHealth` is `waitingForAudio | live | silent | digitallySilent | failed`. There is no `failed` phase (start failures are *thrown* to the UI as `StartError`; mid-capture failures are per-track `TrackHealth.failed`; post-capture problems are the folder's `SessionState`) and no `transcribing` or `paused`.
- `applying(event) -> Transition(kind: moved | ignored | illegal, phase, effects)` is pure and total. `ignored` is a benign late event; `illegal` is a caller bug (start while recording); the controller logs it and keeps the state. Effects (`prepare`, `stopCapture`, `finalize`, `enqueueTranscription`) are named by the reducer and executed by the controller, so policy ("both tracks dead means stop", "quit skips the encode") is table-testable.
- **Owner and observation.** `RecordingController` is `@MainActor @Observable` and the only writer of `phase` (`private(set)`). SwiftUI reads `env.recorder.phase` through Observation; there is no publisher plumbing. Effects that suspend are `await`ed inside the controller, so there is no re-entrancy window: a second `start` during `preparing` is `illegal` by the table. The DEBUG headless runner calls the same `start` and `stop`, so it goes through the same table.
- **Pause is not in Phase 1 (decided).** Reasons: two independent sources would need coordinated stop/start with new first-sample anchors, the timeline would need a pause-interval list, and the actual need ("go off the record for a moment") is better met by muting in the meeting app, or by stopping and starting a new session. The model is ready for it: add `case paused(...)` plus `intervals` in `Recording`, and `TrackClock` already represents "a stretch of no samples" as padded silence.

### 6.2 Transcription jobs (separate machine)

`TranscriptionJobState`: `queued | waiting(recordingInProgress | modelNotReady) | running(fraction) | failed(message) | done`. `TranscriptionSchedule.next(jobs:recordingActive:modelReady:)` is the pure policy: recording active means cancel the running job (it returns to `queued`; audio untouched, nothing partial on disk) and wait; model not ready means wait; otherwise the oldest queued job runs. One job at a time; a job is one session-level `Transcriber.transcribe` call, so cancelling it cancels both tracks at once, and the adapter has already released the model when the call returns or throws. Failed jobs are never retried automatically. Sessions recovered at launch are never enqueued automatically (decided); the user starts them from the menu.

`enqueue` is synchronous: when it returns, the job is in `jobs` as `queued` (or `waiting`). A caller that needs to wait for the result (only the DEBUG headless runner) observes `jobs` until that ref is `done` or `failed`; there is no second "transcribe and wait" API.

Why separate (the departure from DESIGN.md section 5, decided): (a) interview N+1 can start while N is still queued, and running Whisper during a live call risks the call itself, so the policy is "never both"; folding `transcribing` into `RecordingPhase` forces either refusing to record or smuggling a cancel into one enum. (b) Recovery and re-transcribe operate on folders that were never "recording" in this process. (c) The icon is a derived `AppStatus`, so no code keeps two machines in sync.

Transcription does not take the session's `CaptureLease`. The classifier reads a held lease as "capturing", so a lease during transcription would show a transcribing session as recording. One instance runs one job at a time, so two instances transcribing the same folder only happens during development (for example a headless `transcribe` beside the menu bar app); the result is still correct because each writes segments.json atomically and the last writer wins.

### 6.3 Folder state, derived (`SessionClassifier`), and crash recovery

| Evidence in the folder | `SessionState` |
|---|---|
| meta unreadable, or schemaVersion newer than supported | `.unusable(reason)` (never touched) |
| `capture.lock` is held (`CaptureLease.isHeld`) by any process | `.capturing` (live; recovery never touches it, whichever instance owns it) |
| lock free, and (`capture == .inProgress`, or any spool file exists, or a track has `firstSampleHostSeconds` but no final m4a) | `.needsFinalize` (interrupted, or stopped with the encode deferred) |
| no final audio at all | `.unusable("no audio")` |
| final audio and a valid segments.json | `.transcribed` |
| final audio, no valid segments.json | `.readyToTranscribe` |

`SessionFinalizer.run` is the one path from "capture ended" to "final m4a plus finished meta", used by `stop()` and `LaunchRecovery`. Per track it decides only from which files exist: m4a present means complete by construction (it is renamed into place only after the encode was verified), so delete any leftover spool; spool only means truncate to whole frames, encode to `.m4a.part` (converting to 48 kHz first if the spool is above 48 kHz), verify, rename, then delete the spool; `.part` present means stale, delete and redo. Crash at every point:

| Crash point | On disk | What the next launch does |
|---|---|---|
| after `create`, before capture starts | meta `.inProgress`, no audio, lock free | no audio at all: the folder is removed (nothing to lose). Never when the lock is held. |
| during capture, process dead | meta `.inProgress` + anchors, spools, lock free | recovery takes the lease, then `finalize(.recovered)`: encode, `endedAt = startedAt + max(offset + duration)` |
| during capture, process ALIVE (second instance launching, Xcode Debug next to an installed copy, a headless run) | same files, lock held | `.capturing`: skipped untouched |
| after capture stop, before finalize (or quit) | meta finished, spools | finalize |
| during encode | spool + `.part` | delete `.part`, re-encode |
| after rename, before spool delete | spool + m4a | delete spool |
| after finalize | m4a, meta finished | `readyToTranscribe`, listed in the menu; **not auto-transcribed** (decided: a model crash must not become a crash loop, and a launch right before an interview must not start a CPU/ANE-heavy job) |
| during transcription | no segments.json (or the old one) | unchanged; `saveTranscription` writes only at the end |
| between segments.json and transcript.md | valid segments.json, stale/missing transcript.md | `rerenderTranscript` (no engine) |

**Re-transcribe idempotency.** `enqueue(ref)` on a queued/running ref is a no-op; on a `.transcribed` ref it re-runs. Output files are replaced atomically only after success; the old transcript.md moves to `transcript.prev.md`. A failed or cancelled run leaves the previous good result intact.

### 6.4 Menu bar status (derived, never stored)

`AppStatus.derive(phase, jobs, readiness)`: recording (red, amber badge if any track is `failed`, `silent` or `digitallySilent`) wins over preparing, saving (stopping), transcribing(fraction, queued), needsAttention, idle. The user must never wonder whether it is recording, so a live recording outranks everything.

---

## 7. Transcription

- **Port (session level).** `Transcriber.transcribe(TranscribeRequest(audio: PerTrack<URL>, language), progress: (Track, Double)) -> PerTrack<[EngineSegmentDTO]>`, each track's segments in that file's own time; plus `identity(language:)`. Core decides *which* tracks go in the request: a track with no audio is `skippedNoAudio`, an effectively silent one (`peakDBFS <= -70`) is `skippedSilent`, both recorded in segments.json and never sent. The adapter decides *how* to run them: model load, track order, sequential or parallel, unload. Those are engine resource policies (WhisperKit wants one instance and sequential tracks; a SpeechAnalyzer engine might run both at once), so they sit behind the port and Core never manages model memory. The DTO mirrors the engine's fields (Floats). `EngineOutput.normalize` (pure, in Core, applied per track) does the interpretation: strip control tokens (`<|ja|>`, `<|12.34|>`), trim/collapse whitespace, drop empty text, replace NaN/inf, clamp into `0...duration`, round to ms. The adapter's per-track body is a one-line `map`, so everything that can be wrong about the engine's output is testable under `swift test`.
- **WhisperKit adapter: one instance, remote then self, unload per session.** `WhisperKitEngine.transcribe` loads the model, runs the requested tracks in the order `remote`, `self` (`trackOrder`, tested), one at a time, and unloads before returning, also on throw and cancel. Reasons for sequential: one large-v3-turbo instance is already about 1.6 GB of weights plus Core ML working memory; two instances double that and contend for the same ANE/GPU, so parallel does not finish sooner and it hurts a concurrent call. Consequence of per-session unload: consecutive queued sessions load the model once each (R: seconds once the first-time Core ML specialization is done), and an idle menu bar app never holds the model.
- **Incremental audio loading.** The adapter passes `AudioInputOptions(audioLoadingMode: .incremental)` to `transcribe(audioPath:audioInputOptions:decodeOptions:)` (V, compiled against 1.1.1). On the default path WhisperKit loads the whole file as one 16 kHz mono Float buffer: 90 min = 90 x 60 x 16000 x 4 B = 346 MB per track (computed). On the incremental path segment times are corrected to absolute file time (`updateSegmentTimings`; read from the 1.1.1 source during design, confirmed at runtime by the gated test in commit 19).
- **Progress.** The adapter calls `progress(track, fraction)`: `(t, 0)` when a track starts, `(t, 1)` when it ends, and in between samples of `kit.progress.fractionCompleted`. The incremental path passes no segment callback, so in-track progress is coarse (R: how smoothly `kit.progress` moves; commit 19 measures it). `TranscriptionProgress` (pure, Core, tested) weights tracks by duration, ignores NaN and backward steps, and does not depend on the order the adapter chose, so the bar is monotone across the two files.
- **Cancellation.** The adapter checks `Task` cancellation between tracks, and WhisperKit honors it inside a track (R: latency). Core writes only after the whole call succeeded, so a cancelled job leaves nothing. If commit 19 finds in-track cancellation slow, the fallback lives in the adapter, because it owns the track boundaries: finish the current track, then throw `.cancelled`.
- **Options.** `language = "ja"`, `detectLanguage = false` (a self track that starts in silence must not be language-sniffed), `skipSpecialTokens = true`, `chunkingStrategy = .vad` (skips long silences, which is where Whisper hallucinates; the self track is mostly silence while the interviewer talks). All settable properties (V, compiled).
- **Hallucination handling is a read-time policy** (`ReadingPolicy`): drop `noSpeechProb > 0.6 && avgLogprob < -1.0`, `compressionRatio > 2.4`, symbol-only text, and a short stock-phrase list only when confidence is low (so a real "ありがとうございました" at the end of an interview survives).
- **Model install** (`ModelProvider`): `status()` is true only if `installed.json` (written by us after success) names this variant and every required entry exists (`AudioEncoder.mlmodelc`, `MelSpectrogram.mlmodelc`, `TextDecoder.mlmodelc`, `TextDecoderContextPrefill.mlmodelc`, `config.json`, `generation_config.json` (V, from the repo listing)). `install(progress)`: `WhisperKit.download(variant:downloadBase:progressCallback:)` (progress is `(Progress) -> Void` (V, compiled)) into `Application Support/InterviewRecorder/Models`, then `ModelStatus.optimizing` while a prewarm load pays the first-time Core ML specialization (R: that it is slow enough to need a visible state), then write the marker. It is user-initiated; **the app makes no other network call**. Transcription constructs WhisperKit with `download: false` from the recorded folder, so it can never fetch. An install and a transcription never overlap: the schedule runs a job only when the model is ready.
- **Model identity (decided).** Default `openai_whisper-large-v3-v20240930_turbo`. (V) The repo has six folders matching large-v3 and turbo; WhisperKit's variant glob is `*<variant>/*`, so this full folder name is unambiguous (the `_632MB` sibling does not match, and a bare `large-v3_turbo` would also match the distil folder). (V) Its config.json has 32 encoder and 4 decoder layers and 128 mel bins, which is the large-v3-turbo shape. The exact string is stored in `Settings.modelVariant` and in every segments.json (`transcriber.model`). The quantized `_632MB` sibling (about 630 MB) was not chosen; its Japanese accuracy relative to this one is unmeasured (section 16).

---

## 8. Permissions and onboarding

```swift
ScreenCaptureAccess.derive(preflightAtLaunch:, preflightNow:, requestedBefore:, probe:) ->
   .notGranted(requestedBefore)      // button: "Request" (system dialog) the first time, then "Open System Settings"
   .grantedNeedsRelaunch             // preflight flipped true during this run; capture will not work until relaunch
   .grantedButFailing(code)          // preflight true but SCShareableContent probe failed (stale TCC row after re-sign, pending OS re-confirmation)
   .ready
```

- **Request then relaunch (Phase 0 fact).** `requestScreenCapture()` calls `CGRequestScreenCaptureAccess()` and persists `requestedBefore`; it never exits. While the Setup window is visible the model polls preflight every second (and on `didBecomeActive`). When preflight turns true the row becomes "Granted. Relaunch needed" with a **user-initiated** Relaunch button. Quitting right after the request is what recorded "Denied (System Set)" in Phase 0, so the app never does that automatically.
- **Relaunch goes through LaunchServices.** `AppEnvironment.relaunch()` runs `/usr/bin/open -n <bundle path> --args --relaunch`, then `NSApp.terminate(nil)`. Starting our own executable directly could change the process TCC holds responsible (R, recalled); `open` makes the new instance a normal app launch. The new instance parses `LaunchMode.relaunched` and skips the single-instance nicety, because the old instance may still be exiting.
- **Single instance is a nicety, not a guarantee.** The AppDelegate activates an already running instance and quits itself only in `LaunchMode.normal`. Relaunch and DEBUG headless runs start a second instance on purpose. `LSMultipleInstancesProhibited` is not set, because it could refuse exactly those `open -n` launches (R). Correctness never depends on instance count (the lease, 0.4b).
- **Headless runs never request permissions.** If readiness has blockers, `--headless record` prints them and ends with `HEADLESS FAILED`; it does not call `CGRequestScreenCaptureAccess()` (requesting and then exiting records a denial, as above). Grants are made once through the Setup window.
- **Functional probe.** When preflight is true, `screenProbe()` runs a real `SCShareableContent` call. This is the ground truth for "capture will work" and also fires any OS re-confirmation prompt *before* the interview, not at Start (R: recent macOS releases re-confirm screen recording periodically; this is a proposal, not a verified behavior). Probing is skipped when preflight is false so it cannot raise an unexpected prompt.
- **Microphone** has four real states (`AVCaptureDevice.authorizationStatus`) and `requestAccess` works without relaunch.
- **Mic input** is a separate readiness row: `MicResolution.resolve(preference, available)` returns `.use`, `.notChosen`, `.deviceMissing`, or `.channelOutOfRange`. There is no system-default mode (Phase 0: the built-in mic is digitally silent in clamshell). Setup preselects nothing; the user confirms a device and channel while watching the meter.
- **Readiness** = `{screen, mic, micDevice, model}` -> `blockers` (screen, mic permission, mic not chosen, mic missing). The model never blocks recording: audio is safe on disk and transcription waits. Start is enabled iff `blockers.isEmpty`. Free disk is checked at Start (`insufficientDisk`), not as a readiness row.
- Same bundle ID, team and Automatic signing as the spike, so the existing grants should carry over; commit 4 checks this explicitly (`codesign -d -r-` designated requirement equal to the spike's, and the Setup window opening already green).

---

## 9. Answers to the open questions

1. **Project/build shape.** XcodeGen app target for the shell (signing, Info.plist, entitlements, Hardened Runtime, Run from Xcode, later notarization) plus a local SwiftPM package `core/` for everything testable, following YoruMimizuku's `path: core` precedent rather than a root package beside the app. Pure modules live in `RecorderCore` and run under `swift test` in seconds with no signing or TCC. WhisperKit is a dependency of only `RecorderWhisper`; fetch-and-build of WhisperKit 1.1.1 (its only dependency without `BUILD_ALL` is swift-argument-parser) was measured at about 10 s of build time here, which is why it can sit in the package and keep the adapter compile-checked and testable. Single bundle ID in all configs (TCC continuity). Tasks are `mise.toml` (`generate`, `test`, `build`, `app`), like YoruMimizuku. The app target does not set `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` (yohaku does) so nothing is main-actor by accident. The spike target stays until real capture passes QA, then is deleted (git keeps it).
2. **Lifecycle.** Two machines (6.1, 6.2); no pause; `RecordingController` owns `phase`, UI observes via Observation; illegal states are unrepresentable through payload-carrying cases and a total pure reducer.
3. **Crash and recovery, re-transcribe.** Sections 6.3 and 3.3: derived `SessionState`, one idempotent `SessionFinalizer`, launch recovery that finalizes but never transcribes, atomic replacement for re-transcribe.
4. **Data shapes.** Identity is `meta.id` (UUID); the folder is `yyyy-MM-dd_HHmm_<company>` in the start-time zone. Sanitizing (pure, table-tested): NFC-normalize; replace `/ \ : * ? " < > |` and control characters with `-`; collapse whitespace to `_`; trim leading and trailing `-`, `_`, `.`; keep Japanese and other letters; truncate to 40 grapheme clusters without splitting one; empty becomes `untitled`; on collision (case-insensitive, as APFS) append `-2`, `-3`, and reserve the name with a non-intermediate `createDirectory` so two concurrent starts cannot collide. meta.json and segments.json schemas are in section 4. The merge: offsets are `first - min(first)`; each track's engine segments are shifted by its offset and merged with the total order `(start, end, remote-before-self, index)`.
5. **Transcriber boundary.** Section 7: session-level port, DTO out, normalize in Core, load/order/sequential/unload in the adapter, explicit install with `ModelStatus` progress including an `optimizing` phase, `download: false` at run time.
6. **Permissions and onboarding.** Section 8: pure `ScreenCaptureAccess.derive`, user-initiated relaunch through `open -n` only after preflight turns true, polling while Setup is visible, functional probe, readiness rows gate Start.
7. **Mic device selection.** `Settings.mic = MicPreference(deviceUID, deviceName, channel?)`, resolved by UID only at Start. Missing device, unconfirmed choice, or a channel beyond the device's count throws a specific `StartError` before any folder exists; the UI offers "Choose another". No default fallback. Mid-recording loss is the failure matrix in 5.1; a device that delivers exact zeros is flagged within 3 s.

---

## 10. Project and build detail

- `core/Package.swift` (in `sketch/core/Package.swift`): tools 6.0, `swiftLanguageModes: [.v6]`, macOS 14, three library products, three test targets. `RecorderCoreTests` has a `Fixtures` resource folder for golden JSON/Markdown.
- `project.yml` (in `sketch/project.yml`): team `QYP65434UW`, Automatic signing, Hardened Runtime, unsandboxed (like yohaku; the app needs mic and ScreenCaptureKit and the user's disk), `LSUIElement`, an `AppDelegate` single-instance check as a nicety only in `LaunchMode.normal` (two menu bar icons are confusing; recovery safety does not depend on it, it comes from the flock lease), no `LSMultipleInstancesProhibited` (section 8), `NSMicrophoneUsageDescription` (Japanese), entitlement `com.apple.security.device.audio-input`. No `com.apple.security.network.client` question arises because the app is unsandboxed; the privacy property "no network except the model download" is enforced by `download: false` and by code review rule 1, not by the sandbox.
- `mise.toml` (in `sketch/mise.toml`, same layout as YoruMimizuku's): `[tools] xcodegen`, `[env] DEVELOPER_DIR` (Xcode) plus project names and `APP_PATH = build/development/Build/Products/Debug/InterviewRecorder.app`. Tasks: `generate` (xcodegen), `test` (`swift test --package-path core`), `build` (depends on generate; xcodebuild Debug with Apple Development signing into `build/development`, `codesign --verify --deep --strict`, `codesign -d -r-`), `app` (`open -n -W --stdout/--stderr build/logs/... <APP_PATH> --args`, then prints the tail of the stderr log). (V) mise appends a task's extra arguments to the last line of its script and consumes a leading `--`, so the line that takes arguments is always last: `mise run test --filter X`, `mise run app --headless ...`.
- Run location: launch the Debug product from that one stable path through `mise run app`. Delete the old `build/InterviewRecorderSpike.app` in commit 4 so Launch Services has one app for the bundle ID.
- Logging: `os.Logger(subsystem: "as.ason.InterviewRecorder")`; transcript text, company names and file names are never logged unredacted. The headless runner's stderr lines are the exception (DEBUG only, local log files under `build/logs`).
- Docs per `docs/agents/domain.md`: add `GLOSSARY.md` (Session, Track, Spool, Finalize, Timeline, Reading policy, Digital silence, Headless run) and ADRs 0001 (crash-safe spool and why direct AAC was rejected, with the probe result), 0002 (two machines, no pause), 0003 (package/app shape).

### 10.1 DEBUG headless mode

- **Grammar** (`LaunchMode.parse`, `HeadlessCommand.parse`; pure, compiled in every configuration, table-tested): everything after `--headless` is the command; words before the first recognized flag (argv[0], Xcode's `-NSDocumentRevisionsDebugMode YES`) are ignored.
  - `--headless record --seconds <n> --company <name> --target <bundleID|all> [--title <t>]` -> `.record(SessionDraft, seconds:)`. `--target all` is `.allSystemAudio`; a bundle ID becomes `.app(bundleID:, name: bundleID)` and the controller matches running candidates by bundle ID only, taking the display name from the candidate.
  - `--headless transcribe <meta.id>` -> `.transcribe(sessionID:)`.
- **Runner** (`App/HeadlessRunner.swift`, `#if DEBUG`): awaits `env.launched` (launch recovery plus the first readiness refresh), then calls exactly what the buttons call: `recorder.start(draft)`, sleep, `recorder.stop()`; or `store.list()` to find the ref, `transcription.enqueue(ref)`, then observes `jobs`. It prints one stderr line per step and ends with `HEADLESS OK <details>` or `HEADLESS FAILED: <reason>`, then exits; `open -W` does not pass the exit status through, so that line is the result. It opens no window and requests no permission. In Release builds `.headless` is ignored and the app launches normally.
- **Preconditions.** The mic choice comes from `Settings` (Setup completed once in the UI). `record` exits after finalize and abandons the transcription the stop hook enqueued (nothing partial is written; run `transcribe` next). A headless run may coexist with the menu bar instance: the lease keeps recovery off a live session in either instance.
- **Launch only through LaunchServices** (`mise run app --headless ...` = `open -n ... --args --headless ...`). A binary started from a terminal inherits the terminal's Screen Recording grant (Herdr, Ghostty have it), so it would neither reproduce the app's TCC state nor prove the grant carried over.

---

## 11. Implementation commits (ordered; each is small and independently verifiable)

`T` = `mise run test` green. `H` = a headless run through `mise run app --headless ...` whose last log line is `HEADLESS OK`. `M` = manual check by the human.

**Launchable from commit 4 on.** Every commit from 4 leaves `mise run app` able to launch and open Setup. Until its own commit implements it, a stub that launch can reach does the harmless minimum instead of `fatalError`: initializers store their arguments (`SessionStore`, `RecordingController`, `TranscriptionService`, `ReadinessModel`); queries return empty or "nothing yet" (`LaunchRecovery.run` and `SessionStore.list` return `[]`, `CoreAudioInputDevices.inputDevices()` returns `[]`, `WhisperKitEngine.status()` returns `.notInstalled`, `TranscriptionService.jobs` stays empty); commands reached through hooks are no-ops (`TranscriptionService.setRecordingActive`, `enqueue`). Only stubs that nothing calls yet keep `fatalError`. Each commit below replaces the minimum with the real body.

1. **ADRs, GLOSSARY, probe sources.** Re-run the kill -9 probe against the actual Phase 0 spike `.app` and record the result in ADR-0001 next to `probe-work/` and `evidence-a/`. This historical experiment is recorded in [ADR-0001](../../adr/0001-crash-safe-spool.md); current recovery checks use [QA](../../qa.md). Verify: ADR exists; M: the spike's m4a after `kill -9` is unreadable (confirms the (V) result on the real path).
2. **`core/` from the sketch, and mise.** Copy all of `docs/design/phase1/sketch/core/` to `core/` (every stub and every existing test), and in the same commit delete `docs/design/phase1/sketch/core` so the code exists in one place. Copy `sketch/mise.toml` to `mise.toml` and delete `sketch/mise.toml`. Add the architecture test (banned imports; file-name string literals outside `SessionFolder`, matched as Swift string literals only, because comments in Core legitimately mention `meta.json` and `.m4a`) and `.gitignore` entries (`*.xcodeproj/`, `build/`, `.build/`). Root spike package untouched. Verify: T (the sketch's 22 tests pass and 2 are skipped, plus the architecture test passes); `mise run test --filter RecorderCoreTests` runs only Core. From here on, every commit fills `fatalError` bodies in `core/`; nothing is ported from the sketch again.
3. **Readiness, pure.** `ScreenCaptureAccess.derive`, `MicAccess`, `MicResolution.resolve`, `Readiness.blockers`, `ModelStatus`, `AppStatus.derive` + table tests. Verify: T.
4. **App shell + TCC continuity (highest early risk).** Copy `sketch/project.yml` and `sketch/App/` to the repo root and delete them from the sketch (then `docs/design/phase1/sketch/` is gone). `SystemPermissionProbe`, `ReadinessModel`, `SettingsStore` (UserDefaults JSON; Setup and the mic picker persist through it), launch-reachable stubs at their harmless minimum (see above), Setup window with the four rows (model row static), `AppDelegate` reading `LaunchMode` (a malformed `--headless` command prints `HEADLESS FAILED` and exits 2), `AppEnvironment.relaunch()` (`open -n <bundle> --args --relaunch`, then terminate). `HeadlessRunner.swift` stays a stub until commit 11. Delete `build/InterviewRecorderSpike.app`. Verify: `mise run build` succeeds and prints the designated requirement; M: it equals the spike's (`codesign -d -r- build/InterviewRecorderSpike.app` before deleting it); `mise run app` opens Setup with Screen Recording and Microphone already green (no new prompts); after revoking and re-granting, the row shows `grantedNeedsRelaunch`, Relaunch starts a new instance that stays up (not swallowed by the single-instance check), and the row is `ready`.
5. **Session domain + meta.json.** `Session.swift`, `SessionMeta.swift`, golden-fixture round trips, half-finished-capture rejection, newer-schema handling. Verify: T.
6. **FolderNamer, CaptureLease, SessionClassifier, SessionStore.** Temp-dir tests including concurrent `create` (each returns a held lease), atomic update, list over garbage, `discardIfEmpty` refusal, classification with the lock held vs free. Verify: T.
7. **SilenceMonitor.** Level rule and the digital-silence merge with its precedence. (`TrackClock`, `CaptureLease` and `DigitalSilenceDetector` are already implemented and tested since commit 2.) Verify: T.
8. **SpoolWriter + AACFinalizer.** Float to int16 clamp, silence insert, periodic `fsync`, truncated-tail reopen, 96 kHz spool encodes to a 48 kHz m4a (verify uses the converted frame count), finalize state matrix {spool}, {spool + .part}, {spool + m4a}, {m4a}, {none}, run-twice equality, peak dBFS of a -6 dBFS sine. Verify: T.
9. **SessionFinalizer + LaunchRecovery** with a fake `AudioFinalizer`. Verify: T (crash-point table from 6.3 as tests, including "lock held means untouched" with a second `CaptureLease` holder standing in for another instance).
10. **RecordingPhase table test + RecordingController** with `FakeBackend`, including `.digitalSilence` events reaching `TrackHealth.digitallySilent` through `SilenceMonitor`. Verify: T.
11. **DEBUG headless runner.** `HeadlessRunner.run`, `env.launched`, the AppDelegate branch for `LaunchMode.headless`. Capture is not live yet, so this commit verifies the runner's own paths. Verify: `xcodebuild -showBuildSettings -configuration Debug` lists `DEBUG` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS` (resolves the (R) in project.yml); `mise run app --headless transcribe 00000000-0000-0000-0000-000000000000` ends `HEADLESS FAILED: unknown session`; `mise run app --headless record --seconds 1 --company x --target all` ends with `HEADLESS FAILED: notReady(...)` listing `micNotChosen`, and no permission dialog appears; `mise run app --headless bogus` ends `HEADLESS FAILED: unknownSubcommand`.
12. **TrackRecorder + AudioSource** with a scripted fake source: write-ahead ordering, gap fill from scripted times, digital silence evaluated on source samples (a scripted gap neither triggers nor resets it), source error closes the spool. Verify: T.
13. **MicSource + CoreAudioInputDevices + mic picker in Setup.** M: choose Rubix44 INPUT 1 in Setup; the meter moves; 60 s into a spool; unplug mid-run gives `deviceLost`; `kill -9` then relaunch recovers an m4a.
14. **RemoteAppSource + TwoTrackCapture + Start/Stop UI.** Verify: H `mise run app --headless record --seconds 30 --company smoke --target com.google.Chrome` (Chrome playing audio, talking into the mic): two m4a files, both `firstSampleHostSeconds` set, offsets plausible, `gapCount` logged. H with the built-in mic chosen in Setup and the lid closed: the per-second log shows `me` as `digitallySilent` within about 3 s, while a real mic never shows it. M: [QA matrix](../../qa.md) (Chrome-only isolation, Zoom, 5 minutes). Record in the QA doc whether SCStream delivered buffers during silence (resolves an (R) item).
15. **Menu polish.** Elapsed time, meters, amber badge, New Recording window, recent list, quit handling (`stopForQuit`). Verify: `kill -9` the app during `mise run app --headless record --seconds 120 ...`, then `mise run app`: the session is listed as 文字起こし待ち with m4a files. M: quit during a UI recording, then relaunch yields m4a files.
16. **Pure transcript pipeline.** `EngineOutput.normalize`, `TimelineBuilder`, `ReadingPolicy`/`TranscriptReader`, `TranscriptRenderer` + golden Markdown (Japanese, YAML escaping, 90-minute timestamps). Verify: T.
17. **TranscriptionSchedule + TranscriptionService + `saveTranscription`/`rerenderTranscript`** with a session-level `FakeTranscriber`: silent and missing tracks are recorded and never sent, per-track normalize, progress through `TranscriptionProgress`, cancel-on-record, failure keeps the old result, re-transcribe backup. Verify: T.
18. **WhisperKitEngine install/status + Setup model row.** M: install the tiny model first via an env override, then the real variant; interrupt the download and resume; confirm no network use after install (`nettop` or Little Snitch).
19. **WhisperKitEngine.transcribe + gated integration test** with a `say -v Kyoko` fixture. Establishes: file-relative times on the incremental path under VAD, cancel latency under 5 s with the model unloaded afterwards, how usable `kit.progress` is. If cancel is slow, implement the adapter fallback (finish the current track, then `.cancelled`). Verify: `IR_INTEGRATION=1 mise run test --filter RecorderWhisperTests`; H `mise run app --headless transcribe <id from commit 14>` writes segments.json and transcript.md; the same with Wi-Fi off still succeeds.
20. **End-to-end wiring.** stop -> finalize -> enqueue -> transcript.md; Re-transcribe button. Verify: H `record --seconds 60` then H `transcribe <id>`; M: a real 5-minute Meet call; read transcript.md against audio.
21. **Retire the spike (completed 2026-11-10).** Delete root `Package.swift`, `Sources/InterviewRecorderSpike`, its tests and `scripts/` (build-app.sh, run.sh, stop.sh, Info.plist, entitlements). The old Phase 0 QA file is replaced by [docs/qa.md](../../qa.md), using `mise run app --headless ...` where possible and recording the real capture/recovery results.
22. **Optional.** Completion notification (`UNUserNotificationCenter`).

---

## 12. Test plan per module

**RecorderCore** (all `mise run test`, no hardware)

- *Track/PerTrack*: JSON keys are `"self"`/`"remote"` (not `me`); absent tracks omitted on encode and decoded as nil.
- *SessionMeta*: golden v1 files round trip; `endedAt` without `endReason` and vice versa is a decode error; unknown fields ignored; `schemaVersion` 2 classifies `.unusable` and the store refuses to write it; `timeZone` plus `startedAt` reproduce the local date across a 23:30 JST / UTC date boundary.
- *FolderNamer*: table: `/`, `:`, `..`, leading dot, emoji ZWJ sequence at the truncation point, 41-character Japanese company, whitespace-only, case-insensitive collision, many collisions.
- *SessionClassifier*: full truth table over meta status, spool present, m4a present, segments valid/invalid/absent.
- *SessionStore* (temp dirs): 20 concurrent `create` calls with identical inputs give 20 distinct folders; a reader loop never sees a partial meta.json during updates; `saveTranscription` writes segments.json then transcript.md and moves the old transcript to `.prev`; `discardIfEmpty` refuses a folder with any audio; `list` ignores non-session directories.
- *RecordingPhase*: exhaustive (phase x event) table asserting the kind; property: `ignored` and `illegal` never change phase or emit effects; both-failed rule; `.quit` emits no finalize; `enqueueTranscription` only after `finalizeSucceeded`.
- *RecordingController* (fake backend/finalizer, real temp `SessionStore`): happy path; `notReady`, `micMissing`, `micChannelOutOfRange`, `remoteAppNotRunning`, `insufficientDisk` each create no folder; remote matched by bundle ID with the candidate's name recorded; `backend.start` throwing triggers `discardIfEmpty` and returns to idle; a scripted `trackFailed` is persisted to meta.json and keeps the session alive; a scripted `.digitalSilence(.me, true)` makes `me` health `digitallySilent` and `AppStatus` show a track problem; double `start` is `alreadyActive`; `stopForQuit` finishes with `endReason == .quit` and no finalize call.
- *TrackClock* (implemented and passing since commit 2): jitter within tolerance appends; a late chunk pads the exact frame count and the next contiguous chunk appends; a single backward jump drops at most the chunk's length; **simulated 2 h, device 100 ppm fast: zero pads, zero drops, `maxAbsDriftSeconds` about 0.72** (no speech deleted); **simulated 2 h, device 100 ppm slow: zero drops, silence padded only, total about 0.6-0.7 s**.
- *CaptureLease* (implemented and passing): second acquire is refused even in-process; `isHeld` true while held, false after `release()` or after the holder is deallocated (process death behaves the same, kernel-released); a missing lock file means free. *Recovery with a held lease*: a folder whose meta says `.inProgress` and whose lease is held (a second instance, or the live recorder) is classified `.capturing` and left untouched, and "no audio, remove folder" never fires on it.
- *DigitalSilenceDetector* (implemented and passing): fires once at exactly 3 s of zeros across chunks, not at 2.9 s; clears on the first non-zero sample and restarts the run; `-0.0` counts as zero; a ±1e-7 noise floor never fires; only `self` is watched.
- *SilenceMonitor*: waiting to live, live to silent after 20 s, silent to live, no emission when unchanged; digital silence outranks silent and live; clearing it falls back to the level rule's current answer.
- *SessionTimeline/TimelineBuilder*: offsets for one or two tracks; ties; a track with zero segments; stable ordering across shuffled input.
- *EngineOutput.normalize*: control tokens, NaN/inf, `end < start`, out-of-range, empty text.
- *TranscriptReader/Renderer*: each drop rule individually; the "keep a real ありがとうございました" case; coalesce boundaries at 2.0 s and 45 s; golden Markdown; YAML escaping of `A: B "x"`; `1:28:41` and `25:00:00`.
- *TranscriptionProgress* (implemented and passing): duration-weighted, independent of track order, monotone (backward and NaN ignored, clamped to 1), unrequested tracks ignored, zero durations weighed equally.
- *TranscriptionSchedule/Service* (session-level `FakeTranscriber`): schedule truth table; silent track not in the request and recorded `skippedSilent`, missing track `skippedNoAudio`; per-track DTOs normalized and merged; cancel on `setRecordingActive(true)` returns the job to queued with no files written; failed job leaves previous segments.json untouched; model-missing job waits, then runs after `installModel`; `enqueue` makes the job visible in `jobs` synchronously.
- *LaunchMode/HeadlessCommand* (implemented and passing): system-injected arguments ignored; `--relaunch` and `--headless` skip the single-instance check; `record` builds the same `SessionDraft` the UI builds (`--target all` and a bundle ID); `transcribe` takes a UUID; missing subcommand, unknown subcommand, unknown flag, missing or invalid values are typed errors.
- *Readiness*: `ScreenCaptureAccess.derive` truth table (24 combinations: atLaunch x now x requestedBefore x probe nil/succeeded/failed); `MicResolution` (missing, wrong channel, never the default device); `blockers` ordering.
- *Architecture*: sources under `RecorderCore` import none of AVFoundation, CoreAudio, ScreenCaptureKit, AppKit, SwiftUI, WhisperKit; string literals containing `meta.json`, `segments.json`, `transcript.md`, `.spool.caf`, `.m4a` occur only in `SessionFolder` (comments are not checked).

**RecorderAudio** (`mise run test`, synthetic PCM, no TCC)

- *SpoolWriter*: float to int16 with clamp and rounding; `appendSilence` in 1 s blocks; truncate the file by N arbitrary bytes (simulating `kill -9`) and confirm `AVAudioFile` reopens it and reads all whole frames.
- *AACFinalizer*: `outputSampleRate` caps at 48 kHz (implemented and passing); state matrix from commit 8; a 96 kHz spool yields a 48 kHz m4a with frames within 2048 of half the spool's; verify step rejects a truncated encode; idempotent twice; frame count within 2048 of the spool at 48 kHz and below; `peakDBFS` of a known sine.
- *extractChannel*, *device enumeration shape* (ported from the spike's tests).
- *TrackRecorder* with a fake source: `willWriteFirstSample` completes before the first spool byte exists; scripted host times produce the expected pad/drop; 3 s of exact-zero chunks on `self` emit `.digitalSilence(.me, true)` once, the same on `remote` emit nothing, and a scripted 5 s gap after 2 s of zeros does not emit (padding is not source audio); source error closes the spool and emits `trackFailed`.
- *Manual only (TCC)*: SCStream and AVAudioEngine sources, permission flows, `kill -9`, unplug, quit. Scripted in `docs/qa.md`, using headless runs where possible.

**RecorderWhisper**

- Not gated (implemented and passing): `trackOrder` is remote then self and contains only requested tracks.
- Gated by `IR_INTEGRATION=1`, tiny-model fixture: file-relative times on the incremental path with VAD, cancel latency and `.cancelled` with the model unloaded, progress samples, `download: false` really fails when the model is missing (`modelNotInstalled`).

---

## 13. Red-flag screen (design-red-flags.md)

- *Shallow module*: each public type in 3.2 completes an operation (`start`, `enqueue`, `create`, `transcribe` for a whole session); callers do not coordinate stages. Options do not expose stages.
- *Information leakage*: file names only in `SessionFolder`; JSON only in `SessionStore`; WhisperKit and hardware types never leave their targets (the port exchanges `EngineSegmentDTO`, `AudioChunk` stays internal to Audio); engine resource policy (load, track order, unload) stays in the adapter; the offset rule lives in `SessionTimeline`, and segments.json is self-contained so consumers do not need it.
- *Temporal decomposition*: modules are by knowledge (clock policy, folder format, state policy), not by capture/encode/transcribe/save stages. The two lifecycle events that look temporal (stop, recovery) share one `SessionFinalizer`.
- *Pass-through method*: none; `AudioFinalizer` and `CaptureBackend` ports exist because a fake and a second implementation are real needs.
- *Split ownership*: meta.json has one writer (`SessionStore`) even for first-sample times (write-ahead through the plan hook); `phase` has one writer; a track's non-failure health has one writer (`SilenceMonitor`, which merges levels and digital silence); segments/transcript have one writer.
- *Two ways to do one task*: stop and recovery are one finalize path; transcript.md has one render path; re-transcribe is `enqueue`; the headless runner calls the same `start`/`stop`/`enqueue` as the buttons and waits by observing `jobs`, not through a second transcribe API.
- *Importable internals*: `RecorderAudio` exposes only `LiveAudio`; `RecorderWhisper` exposes `LiveWhisper` and the engine; the rest is `internal`, and the architecture test pins imports and file-name literals.
- *Hand-synced list*: file names in one type; the model's required entries in `ModelSpec`; stock hallucination phrases in `ReadingPolicy`; launch flags in `LaunchMode`; blockers are derived from readiness inputs.

---

## 14. Tradeoffs accepted

- We accept **0.7 GB per hour of transient spool and a quick encode at stop** (about 20 s for two 90-minute tracks (V, extrapolated from 576x)) in exchange for crash safety that holds by construction. Start needs 5 GB free.
- We accept **a two-machine model** (more concepts than DESIGN.md section 5) in exchange for recording during a queued transcription and for recovery and re-transcribe having a natural home.
- We accept **one lock file per session and the extra concept of a lease** in exchange for crash detection that is correct no matter how many app instances exist.
- We accept **up to about 0.7 s of timestamp error after 2 hours** on a fast device clock in exchange for never deleting speech to fix drift.
- We accept **no pause and no automatic re-attach of a failed track** in Phase 1.
- We accept **unfiltered segments.json** (a consumer must not treat it as clean text) in exchange for improving filtering retroactively without re-transcribing.
- We accept **WhisperKit inside the package** (a small resolve step on a fresh clone) in exchange for a compile-checked, testable adapter and a hard dependency wall around Core.
- We accept **a model load per transcribed session** (the adapter unloads at the end of every call) in exchange for Core never managing engine memory and an idle app never holding the model.
- We accept **coarse in-track progress** on the incremental loading path in exchange for not holding a 346 MB buffer per track.
- We accept **the first transcription after install being gated behind an explicit Download and "Optimizing" step** rather than lazy loading, so no interview is followed by a surprise 1.6 GB download or a multi-minute stall.
- We accept **a level meter, a silence flag and a digital-silence flag** that the DESIGN.md Phase 1 list does not name, because the failure they prevent (a whole interview recorded as silence) is the one the Phase 0 findings make most likely.
- We accept **a DEBUG-only second caller (headless mode)** in exchange for verifying hardware commits without clicking; it adds no logic, only calls.
- Things that look like oversights but are not: no stored session status; no index database; no notification (commit 22, optional); no auto-transcribe at launch; `.m4a` is not written during capture; `transcript.prev.md` is a single backup, not a history; no lease during transcription; no `LSMultipleInstancesProhibited`.

---

## 15. Alternatives considered

| Alternative | Why it lost |
|---|---|
| **One state machine ending in `transcribing`** (DESIGN.md section 5), or one phase type that also carries finalize and transcription | Blocks or complicates recording during a queued transcription, and recovery/re-transcribe do not fit a "recording" session. "The next interview outranks a queued transcription" is met by the two machines too, and recovery and re-transcribe become plain jobs on folders. Two small machines plus a derived status is simpler for callers. |
| **Keep the spike's incremental AAC `AVAudioFile`** | (V) A `kill -9` leaves an unopenable m4a. The spike's SIGINT/SIGTERM success was a graceful close, not crash safety. |
| **Fragmented MP4 via `AVAssetWriter.movieFragmentInterval`** | (R) Plausibly crash-tolerant, but unverified, requires rewriting the writer, and ties correctness to one API's behavior. CAF was verified in minutes. Revisit only if the 0.7 GB/h spool becomes a problem. |
| **Raw PCM with a custom header** | Needs a custom reader and a custom recovery path. (V) CAF LPCM is readable by `AVAudioFile` directly. |
| **AAC inside CAF, or WAV** | (V) CAF AAC reopened with 0 readable frames; WAV reopened with length 0 after a kill (RIFF sizes unwritten). |
| **Encode AAC at the source rate always** | (V) The encoder fails at 96 and 192 kHz. Capping at 48 kHz costs one converter pass at finalize. |
| **Single-instance enforcement as the crash detector** (any `.capturing` folder at launch is dead) | `LSMultipleInstancesProhibited` is unverified, Xcode Debug next to an installed copy is the normal dev situation, and the launch-time recovery in `AppEnvironment.live()` can run before any AppDelegate check. A second instance could finalize and delete the spool of a live interview. A per-session `flock` makes liveness a kernel fact at the cost of one lock file. |
| **Holding the lease during transcription too** | The classifier reads a held lease as "capturing", so a transcribing session would be listed as recording. Two instances transcribing one folder happens only in development, and atomic writes keep it correct. Not worth redefining the classifier. |
| **Symmetric drift policy (drop audio when the file is ahead by more than the tolerance)** | A 50-100 ppm fast device clock would delete about 100 ms of speech every 17-35 minutes. Padding is harmless, dropping is not; only a sudden backward jump is trimmed. |
| **Gap fill only above 0.5 s** | Leaves up to 0.5 s of timestamp error from every skipped buffer. The 0.1 s tolerance with asymmetric drift handling (tested over 2 h both ways) is tighter and still never deletes speech. |
| **Chunked m4a every 60 s** | More files and a merge step to produce `audio-*.m4a`; loses up to a minute and adds a concatenation failure mode. |
| **Per-track, track-local segments.json** | Lossless but leaks the offset rule to every consumer; offsets are immutable after capture, so baking them in loses nothing. |
| **segments.json field named `track`** | DESIGN.md section 6 names it `speaker`; values `self`/`remote` already say which track. Kept `speaker`. |
| **Detect hand edits of transcript.md by hash and move them aside** | In Phase 1 transcript.md lives in the app's folder and is not edited there; one `transcript.prev.md` is enough. Revisit in Phase 2 when the Obsidian copy is overwritten. |
| **Track-level `Transcriber` port (Core runs remote then self and unloads on queue drain)** | Track order, load and unload are engine resource policy (a SpeechAnalyzer engine might run both tracks in parallel). Putting them in Core leaks the engine's needs through the port. The session-level port keeps them in the adapter; Core keeps status policy and normalization. |
| **Load whole tracks into memory (WhisperKit's default loading)** | 346 MB per 90-minute track as one 16 kHz Float buffer. `.incremental` keeps segment times absolute (read from source) and bounds memory. |
| **SwiftPM-only app with the spike's hand-assembled bundle** | It works for a spike. It hand-reimplements Info.plist embedding, signing, entitlements and (later) notarization, and has no Run/Archive. Viable, rejected for a long-lived app. |
| **All code in the app target, tests via host app** | `xcodebuild test` needs signing; YoruMimizuku's test target lists source files one by one (a hand-synced list). `swift test` on a pure package is faster and cannot drift. |
| **Package at `Packages/RecorderKit`** | YoruMimizuku's precedent is `core/`; following it keeps the user's projects alike. |
| **WhisperKit only in the app target** | Rationale was "slow rebuild per worktree"; measured at about 10 s, so it does not pay for losing the compile-checked, testable adapter. |
| **`scripts/test.sh` and `scripts/run-app.sh`** | The user's other apps use `mise.toml` tasks; one task runner, discoverable with `mise tasks`. |
| **Launch the binary directly for automated checks** | The terminal's Screen Recording grant masks the app's own TCC state. Headless runs go through `open -n`. |
| **Parallel transcription of both tracks** | Double model memory, ANE contention, no wall-clock win, and it can disturb a call that starts later. |
| **Fall back to the system default mic when the chosen device is missing** | Phase 0: the built-in mic is silent in clamshell mode. A silent interview is the worst outcome; blocking Start is cheaper. |
| **Only the level-based silence flag (no digital-silence check)** | Takes 20 s and cannot tell a dead device from a quiet room. Exact zeros for 3 s are unambiguous and get a specific message. |
| **SQLite/SwiftData session index** | A second source of truth to keep consistent with folders the user can move; the folder scan is fast enough and recovery-safe. |
| **Persisted transcription queue, auto-resume at launch** | A crash caused by the model would loop on every launch. Manual transcribe from the menu is one click. |

---

## 16. Open questions and risks

- Japanese accuracy of `openai_whisper-large-v3-v20240930_turbo` versus the `_632MB` quantized sibling is unmeasured. The default is decided; if accuracy or memory disappoints, the variant is one setting (`Settings.modelVariant`).
- Does SCStream deliver buffers while the target app is silent? If not, expect large `gapFillFrames` on the remote track. Correctness is handled; the QA in commit 14 will tell us how much padding is normal.
- Does the OS re-confirm screen recording periodically on this macOS (R)? If it does, is the warm probe at launch enough, or does this become the argument to bring Core Audio Tap forward from Phase 2?
- How fast does a cancelled WhisperKit `transcribe` return (R)? If it takes minutes, the adapter falls back to "finish the current track, then yield" (section 7), at the cost of overlapping a new recording for a few minutes.
- How long does loading the model take after the first specialization (R)? It is paid once per transcribed session.
- Should recordings root be changeable from the Setup UI in Phase 1? The plumbing exists (`Settings.recordingsRoot`), the UI is omitted.
- When only one track produces audio, is a one-sided transcript acceptable as "done"? Currently yes, with the other track's status in segments.json and a failure in meta.json.
- Speakers on the loudspeaker will leak the remote voice into the mic (DESIGN.md risk). Out of scope here; unfiltered segments.json keeps both tracks so later de-duplication is possible.
- `SessionStore` is an `actor` called from `@MainActor` code; every call is already inside a `Task`, so no awkward suspension points are expected in SwiftUI event handlers. Flag if commit 10 shows otherwise.

---

## 17. Verified facts and how (so the implementer can skip re-checking)

| Fact | How |
|---|---|
| `kill -9` during `AVAudioFile` AAC `.m4a` write: file unopenable | experiment, `probe-work/run-probe.sh` (and `evidence-a/crash-after-sigkill.swift`) |
| `kill -9` during CAF LPCM int16 write: reopens, 135,680 of 139,200 written frames recovered | same |
| CAF AAC after kill: 0 frames readable; WAV after kill: length 0 | same |
| AAC encode of a CAF spool: 576x realtime (10 min in 1.0 s), m4a 5 MB per 10 min, spool 57 MB per 10 min, frame count identical after reopen | experiment, `probe-work/encode-speed.swift` |
| AAC encoder (`AVAudioFile`, mono 64 kbps) fails at 96 kHz and 192 kHz, succeeds at 44.1 kHz and 48 kHz | experiment, `evidence-a/aac-sample-rates.swift` |
| WhisperKit latest release v1.1.1 (2026-10-08); tools 5.10; macOS 13+; products include `WhisperKit`; only `swift-argument-parser` without `BUILD_ALL` | read from GitHub (API and Package.swift) |
| `init(_ config:)`, `download(variant:downloadBase:progressCallback:)`, `loadModels`, `prewarmModels`, `unloadModels`, `transcribe(audioPath:decodeOptions:callback:)`, `TranscriptionSegment` fields, `DecodingOptions` fields, `WhisperKitConfig` fields, `ChunkingStrategy {none, vad}` | read from source |
| `transcribe(audioPath:audioInputOptions:decodeOptions:)` with `AudioInputOptions(audioLoadingMode: .incremental)`, `unloadModels()` and the rest of `sketch/core/Sources/RecorderWhisper/WhisperKitEngine.swift` compile against v1.1.1 in Swift 6 language mode with a plain `import WhisperKit` | `swift test` of the sketch (it builds RecorderWhisper) |
| On the incremental path, segment times are corrected to absolute file time (`updateSegmentTimings`) and no segment callback is passed | read from the v1.1.1 source during design; runtime confirmation is commit 19 |
| `Progress`-based `progressCallback`; `kit.progress`; `TranscriptionProgress.windowId` | compile-only probe against v1.1.1 in a scratch package (then removed) |
| Variant glob `*<variant>/*`, `*openai*` retry on ambiguity; six large-v3 turbo folders; folder contents; turbo config (32/4 layers, 128 mels) | read from source and the Hugging Face tree |
| `loadAudio` (the default loading mode) returns one 16 kHz mono buffer for the whole requested range; the app uses `.incremental` instead | read from source |
| `project.yml` generates a valid project and resolves WhisperKit 1.1.1 via the local package | ran XcodeGen 2.46.0 and `xcodebuild -list` in a scratch copy |
| mise appends a task's extra arguments to the last line of its run script (`$@` is empty inside it) and consumes a leading `--` | ran mise 2026.11.2 against a scratch `mise.toml` with the same task shape as `sketch/mise.toml` |
| The sketch package compiles in Swift 6 mode; 22 tests pass and 2 are skipped (reducer, both drift signs over 2 h, lease exclusivity, meta round trip, digital silence, transcription progress, launch arguments, AAC rate cap, track order) | `swift test` with Xcode's toolchain in a scratch copy |
| (R) cancellation latency, VAD segment-time semantics on the incremental path at runtime, `kit.progress` granularity, model reload time, SCStream silence behavior, OS re-confirmation prompts, first-load Core ML cost, XcodeGen `debug` preset defining `DEBUG`, `LSMultipleInstancesProhibited` refusing `open -n`, a directly exec'd binary changing the TCC-responsible process | not verified; each has a commit above that decides it, or the design no longer depends on it |

---

## 18. Synthesis

This design was assembled from two independent candidates; `SYNTHESIS.md` records the comparison, what was taken from the other candidate, what was rejected, and the decisions made with the user. This document is the single source of truth; SYNTHESIS.md is history.

## 19. Next implementation step

Commit 2: copy `sketch/core/` into the repo as `core/` with all its tests green under `mise run test`, delete `docs/design/phase1/sketch/core` in the same commit, add `mise.toml` and the architecture test. Then do commit 4 (App shell reading real permission status) first among the hardware-facing work, because it settles whether the Phase 0 TCC grants survive the move to an Xcode-built app before anything else depends on it.

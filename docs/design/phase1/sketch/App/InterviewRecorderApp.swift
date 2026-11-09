// <repo>/App/InterviewRecorderApp.swift -- NOT compiled in the sketch.
import AppKit
import SwiftUI
import RecorderCore

@main
struct InterviewRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var env = AppEnvironment.live()

    var body: some Scene {
        // .window style: SwiftUI content in the popover (status, readiness rows, Stop, recent sessions).
        MenuBarExtra { MenuView(env: env) } label: { StatusIcon(status: env.status) }
            .menuBarExtraStyle(.window)

        // Separate windows for text input: a MenuBarExtra popover dismisses on focus loss and fights TextField focus.
        Window("New Recording", id: "new-recording") { NewRecordingView(env: env) }
            .windowResizability(.contentSize)
        Window("Setup", id: "setup") { SetupView(env: env) }     // onboarding: the 4 readiness rows
            .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Read once, in applicationWillFinishLaunching, before anything else.
    private(set) var mode: LaunchMode = .normal

    /// Quit while recording: stop capture + close spools (bounded, < 1 s), defer AAC encode to next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // if recorder.phase.isCapturing {
        //     Task { await withTimeout(.seconds(10)) { await recorder.stopForQuit() }; sender.reply(toApplicationShouldTerminate: true) }
        //     return .terminateLater      // stopForQuit handles preparing/recording/stopping; the reply ALWAYS fires (timeout)
        // }
        .terminateNow
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        // A malformed --headless command must END the run with a result line; falling back to a normal launch would hang
        // `open -W` on the menu bar UI (or be swallowed by the single-instance check) and never print HEADLESS ....
        do {
            mode = try LaunchMode.parse(CommandLine.arguments)
        } catch {
            FileHandle.standardError.write(Data("HEADLESS FAILED: \(error)\n".utf8))
            exit(2)
        }
        // Then the nicety, only after the mode is known: if another instance with our bundle ID is running AND !mode.skipsSingleInstanceCheck, activate it and
        // quit this one (avoids two menu bar icons). Skipped for .relaunched (the old instance is about to terminate) and for
        // .headless (it runs beside the menu bar instance on purpose). Correctness does NOT depend on it: crash detection
        // uses the per-session CaptureLease (flock), so a second instance can never finalize a live recording.
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // #if DEBUG
        // if case let .headless(command) = mode { Task { @MainActor in await HeadlessRunner.run(command, env: env) } ; return }
        // #endif
        // (Release ignores .headless and launches normally.) No Setup window is opened in headless mode.
    }
}

// MenuView, StatusIcon, NewRecordingView, SetupView: plain SwiftUI over `env`. They contain no policy:
// every enabled/disabled state is `env.readiness.readiness.canRecord`, `env.recorder.phase`, `env.status`.
// Icon: SF Symbol `record.circle.fill` red while recording (static; MenuBarExtra labels do not animate reliably),
// amber badge when AppStatus.recording(trackProblem: true), `waveform` while transcribing, `mic` when idle.
// The "自分" meter row shows "マイクの入力がデジタル無音です。接続とチャンネルを確認してください" while health is .digitallySilent.

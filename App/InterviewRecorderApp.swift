import AppKit
import SwiftUI
import RecorderCore

@main
struct InterviewRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var env: AppEnvironment

    init() {
        let environment = AppEnvironment.live()
        _env = State(initialValue: environment)
        AppDelegate.environment = environment
    }

    var body: some Scene {
        MenuBarExtra { MenuView(env: env) } label: { LaunchIcon() }
            .menuBarExtraStyle(.window)
        Window("Setup", id: "setup") { SetupView(env: env) }
            .windowResizability(.contentSize)
        Window("新しい録音", id: "new-recording") { NewRecordingView(env: env) }
            .windowResizability(.contentSize)
    }
}

private struct LaunchIcon: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(systemName: "mic")
            .accessibilityLabel("InterviewRecorder")
            .task {
                #if DEBUG
                if case .headless = AppDelegate.launchMode { return }
                #endif
                openWindow(id: "setup")
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var environment: AppEnvironment?
    static let launchMode: LaunchMode = {
        do { return try LaunchMode.parse(CommandLine.arguments) }
        catch {
            FileHandle.standardError.write(Data("HEADLESS FAILED: \(error)\n".utf8))
            exit(2)
        }
    }()
    private(set) var mode: LaunchMode = .normal

    func applicationWillFinishLaunching(_ notification: Notification) {
        mode = Self.launchMode
        guard !mode.skipsSingleInstanceCheck, let bundleID = Bundle.main.bundleIdentifier else { return }
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [])
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if case .headless(let command) = mode {
            guard let environment = Self.environment else {
                FileHandle.standardError.write(Data("HEADLESS FAILED: missing app environment\n".utf8))
                exit(2)
            }
            Task { await HeadlessRunner.run(command, env: environment) }
            return
        }
        #endif
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
}

private struct MenuView: View {
    let env: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("InterviewRecorder").font(.headline)
            switch env.recorder.phase {
            case .idle:
                Button("新しい録音") { openWindow(id: "new-recording"); NSApp.activate(ignoringOtherApps: true) }
            case .preparing: Text("録音を準備しています")
            case .recording(let recording):
                HStack { Text("録音中"); Text(recording.startedAt, style: .timer).monospacedDigit() }
                Button("録音を停止") { Task { await env.recorder.stop() } }
            case .stopping: Text("録音を保存しています")
            }
            Button("設定を開く") { openWindow(id: "setup"); NSApp.activate(ignoringOtherApps: true) }
            Button("終了") { NSApp.terminate(nil) }
        }
        .padding()
    }
}

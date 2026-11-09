import AppKit
import SwiftUI
import RecorderCore

@main
struct InterviewRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var env = AppEnvironment.live()

    var body: some Scene {
        MenuBarExtra { MenuView() } label: { LaunchIcon() }
            .menuBarExtraStyle(.window)
        Window("Setup", id: "setup") { SetupView(env: env) }
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
        if case .headless = mode {
            FileHandle.standardError.write(Data("HEADLESS FAILED: Headless runner is not implemented yet\n".utf8))
            exit(2)
        }
        #endif
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
}

private struct MenuView: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("InterviewRecorder").font(.headline)
            Button("設定を開く") { openWindow(id: "setup"); NSApp.activate(ignoringOtherApps: true) }
            Button("終了") { NSApp.terminate(nil) }
        }
        .padding()
    }
}

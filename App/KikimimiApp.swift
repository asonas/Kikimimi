import AppKit
import SwiftUI
import RecorderCore

@main
struct KikimimiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var env: AppEnvironment

    init() {
        let environment = AppEnvironment.live()
        _env = State(initialValue: environment)
        AppDelegate.environment = environment
    }

    var body: some Scene {
        // Keep the menu scene first: windows open explicitly, including on macOS 14 without defaultLaunchBehavior.
        MenuBarExtra { MenuView(env: env) } label: { LaunchIcon(env: env) }
            .menuBarExtraStyle(.window)
        Window("Kikimimi", id: "main") { MainWindowView(env: env) }
            .defaultSize(width: 1120, height: 840)
            .windowStyle(.hiddenTitleBar)
            .windowToolbarStyle(.unified)
        Settings { SetupView(env: env) }
            .defaultSize(width: 1040, height: 720)
        Window("新しい録音", id: "new-recording") { NewRecordingView(env: env) }
            .windowResizability(.contentSize)
    }
}

private struct LaunchIcon: View {
    let env: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private var status: AppStatus { env.status }
    var body: some View {
        Image(systemName: symbol)
            .renderingMode(.original)
            .foregroundStyle(iconColor)
            .overlay(alignment: .topTrailing) {
                if case .recording(_, trackProblem: true) = status {
                    Circle().fill(.orange).frame(width: 6, height: 6).offset(x: 3, y: -2)
                }
            }
            .accessibilityLabel("Kikimimi: \(status.description)")
            .help(status.description)
            .task {
                guard !AppDelegate.isHeadless else { return }
                AppDelegate.showMainWindow = {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                AppDelegate.showMainWindow?()
                await env.launched.value
                if !env.readiness.readiness.canRecord {
                    UserDefaults.standard.set(SettingsPane.recording.rawValue, forKey: "settings.selectedPane")
                    openSettings()
                }
            }
    }

    private var symbol: String {
        switch status {
        case .recording: "record.circle.fill"
        case .preparing, .saving: "arrow.triangle.2.circlepath"
        case .transcribing: "text.bubble"
        case .needsAttention: "mic.badge.exclamationmark"
        case .idle: "mic"
        }
    }
    private var iconColor: Color {
        switch status { case .recording: .red; case .needsAttention: .orange; default: .primary }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var environment: AppEnvironment?
    static var showMainWindow: (() -> Void)?
    static var isHeadless: Bool {
        #if DEBUG
        if case .headless = launchMode { return true }
        #endif
        return false
    }
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
        NSApp.setActivationPolicy(Self.isHeadless ? .accessory : .regular)
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment = Self.environment else { return .terminateNow }
        environment.termination.request(stop: { await environment.recorder.stopForQuit() }, reply: {
            sender.reply(toApplicationShouldTerminate: true)
        })
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !Self.isHeadless { Self.showMainWindow?() }
        return false
    }
}

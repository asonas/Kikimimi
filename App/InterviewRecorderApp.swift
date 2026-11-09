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
        MenuBarExtra { MenuView(env: env) } label: { LaunchIcon(status: env.status) }
            .menuBarExtraStyle(.window)
        Window("Setup", id: "setup") { SetupView(env: env) }
            .windowResizability(.contentSize)
        Window("新しい録音", id: "new-recording") { NewRecordingView(env: env) }
            .windowResizability(.contentSize)
    }
}

private struct LaunchIcon: View {
    let status: AppStatus
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(systemName: symbol)
            .renderingMode(.original)
            .foregroundStyle(iconColor)
            .overlay(alignment: .topTrailing) {
                if case .recording(_, trackProblem: true) = status {
                    Circle().fill(.orange).frame(width: 6, height: 6).offset(x: 3, y: -2)
                }
            }
            .accessibilityLabel("InterviewRecorder: \(status.description)")
            .help(status.description)
            .task {
                #if DEBUG
                if case .headless = AppDelegate.launchMode { return }
                #endif
                openWindow(id: "setup")
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment = Self.environment else { return .terminateNow }
        environment.termination.request(stop: { await environment.recorder.stopForQuit() }, reply: {
            sender.reply(toApplicationShouldTerminate: true)
        })
        return .terminateLater
    }
}

private struct MenuView: View {
    let env: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @State private var recent: [SessionListing] = []
    @State private var listError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("InterviewRecorder").font(.headline)
            Text(env.status.description).font(.caption).foregroundStyle(.secondary)
            switch env.recorder.phase {
            case .idle:
                Button("新しい録音") { openWindow(id: "new-recording"); NSApp.activate(ignoringOtherApps: true) }
                    .disabled(env.termination.requested)
            case .preparing: Text("録音を準備しています")
            case .recording(let recording):
                HStack { Text("録音中"); Text(recording.startedAt, style: .timer).monospacedDigit() }
                TrackMeter(label: "自分", peak: env.recorder.levels?.me, health: recording.health.me)
                TrackMeter(label: "相手", peak: env.recorder.levels?.remote, health: recording.health.remote)
                Button("録音を停止") { Task { await env.recorder.stop() } }
            case .stopping: Text("録音を保存しています")
            }
            Divider()
            Text("最近の録音").font(.subheadline.bold())
            if recent.isEmpty { Text("録音はまだありません").font(.caption).foregroundStyle(.secondary) }
            ForEach(recent) { session in
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([session.ref.folder.url])
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.company + (session.title.map { " / " + $0 } ?? "")).lineLimit(1)
                        HStack {
                            Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                            if let seconds = session.durationSeconds { Text(Duration.seconds(seconds), format: .time(pattern: .hourMinuteSecond)) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Text(session.state.label).font(.caption).foregroundStyle(session.state.needsAttention ? .orange : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Finderで録音フォルダを表示")
            }
            if let listError { Text(listError).font(.caption).foregroundStyle(.red) }
            Divider()
            Button("設定を開く") { openWindow(id: "setup"); NSApp.activate(ignoringOtherApps: true) }
            Button("終了") { NSApp.terminate(nil) }
        }
        .padding()
        .frame(width: 320)
        .task {
            await env.launched.value
            while !Task.isCancelled {
                do { recent = Array(try await env.store.list().prefix(10)); listError = nil }
                catch { listError = "録音一覧を取得できませんでした" }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
}

private struct TrackMeter: View {
    let label: String
    let peak: Float?
    let health: TrackHealth
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text(health.label).foregroundStyle(health.isProblem ? .orange : .secondary)
            }
            .font(.caption)
            HStack {
                ProgressView(value: Double(min(1, max(0, ((peak ?? -120) + 75) / 75))))
                    .tint(health.isProblem ? .orange : .green)
                    .accessibilityLabel("\(label)の録音レベル")
                Text(String(format: "%.0f dBFS", peak ?? -120)).font(.caption.monospacedDigit()).frame(width: 72)
            }
        }
    }
}

private extension AppStatus {
    var description: String {
        switch self {
        case .recording(_, let problem): problem ? "録音中・入力を確認してください" : "録音中"
        case .preparing: "録音を準備しています"
        case .saving: "録音を保存しています"
        case .transcribing: "文字起こし中"
        case .needsAttention(let message): message
        case .idle: "録音できます"
        }
    }
}

private extension TrackHealth {
    var isProblem: Bool {
        switch self { case .silent, .digitallySilent, .failed: true; default: false }
    }
    var label: String {
        switch self {
        case .waitingForAudio: "音声待ち"
        case .live: "正常"
        case .silent: "無音"
        case .digitallySilent: "入力を確認してください"
        case .failed: "入力が停止しました"
        }
    }
}

private extension SessionState {
    var needsAttention: Bool {
        switch self { case .needsFinalize, .unusable: true; default: false }
    }
    var label: String {
        switch self {
        case .capturing: "録音中"
        case .needsFinalize: "要保存処理"
        case .readyToTranscribe: "文字起こし待ち"
        case .transcribed: "文字起こし済み"
        case .unusable: "録音を確認してください"
        }
    }
}

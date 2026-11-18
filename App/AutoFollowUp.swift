import Foundation
import Observation
import OSLog
import RecorderCore

/// What the session screen shows about the automatic run. A run that finished leaves no state: the export line says it.
enum AutoFollowUpState: Equatable {
    case running
    /// The summary failed, so nothing was exported.
    case summaryFailed
    case exportFailed
    /// The switch was on, but a setting had been undone by the time the transcript was ready.
    case skipped([AutoFollowUpRequirement])
}

/// After a new recording is transcribed, summarizes it and exports the note, when the user turned that on.
@MainActor @Observable
final class AutoFollowUp {
    private(set) var states: [SessionRef: AutoFollowUpState] = [:]
    @ObservationIgnored private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) { self.environment = environment }

    /// Shared by the settings switch and the run, so both agree. A folder that was moved or sits on an unplugged volume
    /// counts as missing: otherwise the export would fail only after the transcript was sent.
    var missingRequirements: [AutoFollowUpRequirement] {
        guard let env = environment else { return AutoFollowUpRequirement.allCases }
        let folder = env.settings.settings.exportFolder
        return AutoFollowUpRequirement.missing(modelReady: env.transcription.model == .ready,
                                               providerReady: env.summaryProviderReady,
                                               summaryModel: env.settings.settings.summaryModel,
                                               exportFolder: Self.folderExists(folder) ? folder : nil)
    }

    func transcribed(_ ref: SessionRef, origin: TranscriptionOrigin) {
        guard origin == .newRecording else { return }
        run(ref, needsSwitch: true)
    }

    /// The session screen's "もう一度試す". The user asks for it, so the switch may since have been turned off.
    func retry(_ ref: SessionRef) { run(ref, needsSwitch: false) }

    /// A note the user exported by hand answers any earlier failure.
    func clear(_ ref: SessionRef) {
        if states[ref] != .running { states[ref] = nil }
    }

    func isRunning(_ ref: SessionRef) -> Bool { states[ref] == .running }

    private func run(_ ref: SessionRef, needsSwitch: Bool) {
        // Headless runs are scripted checks; they must never send anything to the provider.
        guard !AppDelegate.isHeadless, let env = environment, states[ref] != .running else { return }
        if needsSwitch, !env.settings.settings.autoSummarizeAndExport { return }
        states[ref] = .running
        Task {
            // Credentials are loaded only when a screen asks for them, so a recording made right after launch would
            // otherwise look as if nothing were set up.
            // Only the selected provider: reading the other one's keychain item could wait on an unrelated prompt.
            switch env.settings.settings.summaryProvider {
            case .apiKey: env.summaryCredentials.refresh()
            case .chatGPT: await env.chatGPT.refresh()
            }
            // From here to `start` nothing awaits, so the settings checked are the settings the summary uses.
            if (needsSwitch && !env.settings.settings.autoSummarizeAndExport) || env.termination.requested {
                states[ref] = nil; return
            }
            let missing = missingRequirements
            guard missing.isEmpty, let summary = env.summaryJobs.start(ref: ref) else {
                states[ref] = .skipped(missing); return
            }
            switch await summary.value {
            case .finished: break
            case nil: states[ref] = nil; return            // cancelled by the user or by a provider change
            default: states[ref] = .summaryFailed; return
            }
            if env.termination.requested { states[ref] = nil; return }
            // Read the folder again: the user may have changed or cleared it while the summary ran.
            guard let folder = env.settings.settings.exportFolder else { states[ref] = .skipped([.exportFolder]); return }
            do {
                _ = try await env.store.exportNote(ref, to: URL(fileURLWithPath: folder, isDirectory: true))
                states[ref] = nil
            } catch SessionExportError.folderMissing {
                states[ref] = .skipped([.exportFolder])     // e.g. the volume was unplugged during the summary
            } catch {
                // `.metadataFailed` means the note was written; only the export history was not. Not a failed export.
                if case SessionExportError.metadataFailed = error { states[ref] = nil } else { states[ref] = .exportFailed }
                Logger(subsystem: "as.ason.Kikimimi", category: "export")
                    .error("Automatic note export failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// A folder that was moved or sits on an unplugged volume would fail only after the transcript was sent.
    private static func folderExists(_ path: String?) -> Bool {
        var isDirectory: ObjCBool = false
        return path.map { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue } ?? false
    }
}

extension AutoFollowUpRequirement {
    /// Names the missing setting in the session screen's notice.
    var shortLabel: String {
        switch self {
        case .transcriptionModel: "文字起こしモデル"
        case .summaryProvider: "要約のサインインまたはAPIキー"
        case .summaryModel: "要約に使うモデル"
        case .exportFolder: "ノートの保存先"
        }
    }
    /// Tells where to finish the setting, in the export settings.
    var instruction: String {
        switch self {
        case .transcriptionModel: "「文字起こし」でモデルをダウンロードしてください。"
        case .summaryProvider: "「要約」でChatGPTにサインインするか、APIキーを保存してください。"
        case .summaryModel: "「要約」で要約に使うモデルを選んでください。"
        case .exportFolder: "「ノートの保存先」でフォルダを選んでください。"
        }
    }
    var settingsPane: SettingsPane {
        switch self {
        case .transcriptionModel: .transcription
        case .summaryProvider, .summaryModel: .summary
        case .exportFolder: .export
        }
    }
}

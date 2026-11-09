import Foundation

/// How this process was launched, from its arguments. Pure; the App reads `CommandLine.arguments` once at launch.
///
/// Every non-normal mode is launched through LaunchServices (`/usr/bin/open -n <app> --args ...`), never by running the
/// binary: a binary started from a terminal runs under the terminal's TCC grants (Herdr, Ghostty already have Screen
/// Recording), so it would say nothing about the app's own permission state. `open -n` starts a second instance on
/// purpose, so the AppDelegate's single-instance nicety is skipped for these modes (`skipsSingleInstanceCheck`).
public enum LaunchMode: Sendable, Equatable {
    case normal
    /// Started by the Setup window's Relaunch button (`open -n <bundle> --args --relaunch`) a moment before the old
    /// instance terminates.
    case relaunched
    /// DEBUG builds only (the App ignores it in Release): run one command against the same controller methods the UI
    /// uses, print the result, exit.
    case headless(HeadlessCommand)

    public static let relaunchFlag = "--relaunch"
    public static let headlessFlag = "--headless"

    public var skipsSingleInstanceCheck: Bool { self != .normal }

    /// Arguments before the first recognized flag are ignored (argv[0], `-NSDocumentRevisionsDebugMode YES` added by Xcode,
    /// and anything else the system injects). Everything after `--headless` belongs to the headless command.
    public static func parse(_ arguments: [String]) throws(LaunchArgumentError) -> LaunchMode {
        if let i = arguments.firstIndex(of: headlessFlag) {
            return .headless(try HeadlessCommand.parse(Array(arguments[(i + 1)...])))
        }
        return arguments.contains(relaunchFlag) ? .relaunched : .normal
    }
}

/// The DEBUG headless commands. Exactly what a coding agent needs to verify a hardware commit without clicking:
///
///     mise run app --headless record --seconds 30 --company smoke --target com.google.Chrome [--title QA]
///     mise run app --headless record --seconds 30 --company smoke --target all
///     mise run app --headless transcribe 6F1C7E1B-3C0D-4C55-9F5B-0A1B2C3D4E5F
///
/// `record` uses the persisted mic choice (Setup must have been completed once in the UI) and exits after finalize;
/// it does not wait for transcription. `transcribe` takes the session's `meta.id`, enqueues it and waits until the job
/// is `.done` or `.failed`.
public enum HeadlessCommand: Sendable, Equatable {
    case record(SessionDraft, seconds: Double)
    case transcribe(sessionID: UUID)

    /// `arguments` are the words after `--headless`.
    public static func parse(_ arguments: [String]) throws(LaunchArgumentError) -> HeadlessCommand {
        guard let sub = arguments.first else { throw .missingSubcommand }
        let rest = Array(arguments.dropFirst())
        switch sub {
        case "record":
            var values: [String: String] = [:]
            var i = 0
            while i < rest.count {
                let flag = rest[i]
                guard ["--seconds", "--company", "--title", "--target"].contains(flag) else { throw .unknownArgument(flag) }
                guard i + 1 < rest.count, !rest[i + 1].hasPrefix("--") else { throw .missingValue(flag) }
                values[flag] = rest[i + 1]
                i += 2
            }
            guard let rawSeconds = values["--seconds"] else { throw .missingValue("--seconds") }
            guard let seconds = Double(rawSeconds), seconds.isFinite, seconds > 0 else { throw .invalidValue("--seconds", rawSeconds) }
            let company = values["--company"]?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !company.isEmpty else { throw .missingValue("--company") }
            guard let target = values["--target"] else { throw .missingValue("--target") }
            // The controller matches `.app` by bundleID only; the display name is filled from the running candidate.
            let remote: RemoteSource = target == "all" ? .allSystemAudio : .app(bundleID: target, name: target)
            return .record(SessionDraft(company: company, title: values["--title"], remote: remote), seconds: seconds)
        case "transcribe":
            guard let raw = rest.first else { throw .missingValue("<session-id>") }
            guard rest.count == 1 else { throw .unknownArgument(rest[1]) }
            guard let id = UUID(uuidString: raw) else { throw .invalidValue("<session-id>", raw) }
            return .transcribe(sessionID: id)
        default:
            throw .unknownSubcommand(sub)
        }
    }
}

public enum LaunchArgumentError: Error, Sendable, Equatable {
    case missingSubcommand
    case unknownSubcommand(String)
    case unknownArgument(String)
    case missingValue(String)
    case invalidValue(String, String)
}

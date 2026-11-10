import Foundation

public enum LegacyInstallMigration {
    public static let folderName = "InterviewRecorder"
    public static let defaultsDomain = "as.ason.InterviewRecorder"

    public enum FolderOutcome: String, Sendable {
        case moved, bothExist, nothingToDo
    }

    public static func moveFolder(old: URL, new: URL) throws -> FolderOutcome {
        let files = FileManager.default
        guard files.fileExists(atPath: old.path) else { return .nothingToDo }
        guard !files.fileExists(atPath: new.path) else { return .bothExist }
        try files.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: old, to: new)
        return .moved
    }

    @discardableResult
    public static func copySettings(old: UserDefaults, new: UserDefaults) -> Bool {
        guard new.object(forKey: SettingsStore.key) == nil,
              let value = old.data(forKey: SettingsStore.key),
              var settings = try? JSONDecoder().decode(Settings.self, from: value) else { return false }
        // TCC permission requests belong to the bundle identity, so the new identity must ask again.
        settings.screenCaptureRequested = false
        guard let migrated = try? JSONEncoder().encode(settings) else { return false }
        new.set(migrated, forKey: SettingsStore.key)
        return true
    }
}

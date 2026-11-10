import Foundation
import Testing
@testable import RecorderCore

@Test func legacyFolderMovesContentsAndSecondRunDoesNothing() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? files.removeItem(at: root) }
    let old = root.appendingPathComponent("InterviewRecorder")
    let new = root.appendingPathComponent("nested/Kikimimi")
    try files.createDirectory(at: old, withIntermediateDirectories: true)
    let contents = Data("recording and model".utf8)
    try contents.write(to: old.appendingPathComponent("data"))
    #expect(try LegacyInstallMigration.moveFolder(old: old, new: new) == .moved)
    #expect(!files.fileExists(atPath: old.path))
    #expect(try Data(contentsOf: new.appendingPathComponent("data")) == contents)
    #expect(try LegacyInstallMigration.moveFolder(old: old, new: new) == .nothingToDo)
}

@Test func legacyFolderMissingDoesNotCreateDestination() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let new = root.appendingPathComponent("new")
    #expect(try LegacyInstallMigration.moveFolder(old: root.appendingPathComponent("old"), new: new) == .nothingToDo)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func legacyFolderConflictPreservesBoth() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? files.removeItem(at: root) }
    let old = root.appendingPathComponent("old")
    let new = root.appendingPathComponent("new")
    for folder in [old, new] {
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(folder.lastPathComponent.utf8).write(to: folder.appendingPathComponent("data"))
    }
    #expect(try LegacyInstallMigration.moveFolder(old: old, new: new) == .bothExist)
    for folder in [old, new] {
        #expect(try Data(contentsOf: folder.appendingPathComponent("data")) == Data(folder.lastPathComponent.utf8))
    }
}

@Test func legacySettingsCopyOnlyWhenAbsentAndPreserveOriginal() throws {
    let oldName = "migration-old-\(UUID().uuidString)"
    let newName = "migration-new-\(UUID().uuidString)"
    let old = try #require(UserDefaults(suiteName: oldName))
    let new = try #require(UserDefaults(suiteName: newName))
    defer {
        old.removePersistentDomain(forName: oldName)
        new.removePersistentDomain(forName: newName)
    }
    #expect(!LegacyInstallMigration.copySettings(old: old, new: new))
    old.set(Data("invalid settings".utf8), forKey: SettingsStore.key)
    #expect(!LegacyInstallMigration.copySettings(old: old, new: new))
    #expect(new.object(forKey: SettingsStore.key) == nil)
    var settings = Settings()
    settings.screenCaptureRequested = true
    settings.mic = MicPreference(deviceUID: "rubix", deviceName: "Rubix44", channel: 1)
    settings.modelVariant = "custom-model"
    let value = try JSONEncoder().encode(settings)
    old.set(value, forKey: SettingsStore.key)
    #expect(LegacyInstallMigration.copySettings(old: old, new: new))
    let migrated = try JSONDecoder().decode(Settings.self, from: #require(new.data(forKey: SettingsStore.key)))
    #expect(!migrated.screenCaptureRequested)
    #expect(migrated.mic == settings.mic)
    #expect(migrated.modelVariant == settings.modelVariant)
    settings.screenCaptureRequested = false
    #expect(migrated == settings)
    #expect(old.data(forKey: SettingsStore.key) == value)
    #expect(!LegacyInstallMigration.copySettings(old: old, new: new))
    new.set(Data("existing".utf8), forKey: SettingsStore.key)
    #expect(!LegacyInstallMigration.copySettings(old: old, new: new))
    #expect(new.data(forKey: SettingsStore.key) == Data("existing".utf8))
}

import Foundation
import Testing
@testable import RecorderCore

@Test func noteExportDestinationAndContentsLabels() {
    let home = URL(fileURLWithPath: "/Users/x", isDirectory: true)
    let rows = [
        ("/Users/x/Documents/面接ノート", "Documents / 面接ノート"),
        ("/Users/x/面接ノート", "面接ノート"),
        ("/Users/x", "ホーム"),
        ("/Users/x/Documents/Vault/面接/", "Vault / 面接"),
        ("/Users/xx/Exports", "xx / Exports"),
        ("/Volumes/External/Notes", "External / Notes"),
        ("/Notes", "Notes"),
        ("/", "/")
    ]
    for (path, expected) in rows {
        #expect(NoteExportLabels.destination(folder: URL(fileURLWithPath: path, isDirectory: true), home: home) == expected)
    }
    for (summary, expected) in [(false, "文字起こし"), (true, "文字起こし・作成済みの要約")] {
        #expect(NoteExportLabels.contents(hasSummary: summary) == expected)
    }
}

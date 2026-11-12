import Foundation

public enum NoteExportLabels {
    public static func destination(folder: URL, home: URL) -> String {
        let folderParts = folder.standardizedFileURL.pathComponents
        let homeParts = home.standardizedFileURL.pathComponents
        let parts = folderParts.starts(with: homeParts) ? Array(folderParts.dropFirst(homeParts.count)) : folderParts.filter { $0 != "/" }
        if parts.isEmpty { return folderParts == homeParts ? "ホーム" : "/" }
        return parts.suffix(2).joined(separator: " / ")
    }
    public static func contents(hasSummary: Bool) -> String {
        hasSummary ? "文字起こし・作成済みの要約" : "文字起こし"
    }
}

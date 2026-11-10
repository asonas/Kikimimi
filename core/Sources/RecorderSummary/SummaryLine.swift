import Foundation

public enum SummaryLine: Sendable, Equatable {
    case heading(String)
    case bullet(text: String, depth: Int)
    case paragraph(String)
    case blank

    public static func classify(_ line: String) -> SummaryLine {
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }
        if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3))) }
        let spaces = line.prefix(while: { $0 == " " }).count
        let content = line.dropFirst(spaces)
        if content.hasPrefix("- ") || content.hasPrefix("* ") {
            return .bullet(text: String(content.dropFirst(2)), depth: spaces / 2)
        }
        return .paragraph(line)
    }
}

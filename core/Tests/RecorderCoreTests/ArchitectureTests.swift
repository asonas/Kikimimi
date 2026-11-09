import Foundation
import Testing

private enum SourceToken: Equatable {
    case code(String)
    case literal(String)
}

// Recognize comments and string boundaries before checking architectural rules.
// In particular, comment examples must not count as imports or file-name literals.
private func sourceTokens(_ source: String) -> [SourceToken] {
    let chars = Array(source)
    var index = 0
    var tokens: [SourceToken] = []
    func starts(_ text: String, at position: Int) -> Bool {
        let suffix = Array(text)
        return position + suffix.count <= chars.count
            && Array(chars[position..<(position + suffix.count)]) == suffix
    }
    while index < chars.count {
        if starts("//", at: index) {
            while index < chars.count && chars[index] != "\n" { index += 1 }
        } else if starts("/*", at: index) {
            var depth = 1
            index += 2
            while index < chars.count && depth > 0 {
                if starts("/*", at: index) { depth += 1; index += 2 }
                else if starts("*/", at: index) { depth -= 1; index += 2 }
                else { index += 1 }
            }
        } else {
            var quote = index
            while quote < chars.count && chars[quote] == "#" { quote += 1 }
            if quote < chars.count && chars[quote] == "\"" {
                let hashes = quote - index
                let quotes = starts("\"\"\"", at: quote) ? 3 : 1
                let closing = String(repeating: "\"", count: quotes) + String(repeating: "#", count: hashes)
                index = quote + quotes
                let begin = index
                while index < chars.count && !starts(closing, at: index) {
                    if starts("\\" + String(repeating: "#", count: hashes), at: index) {
                        index = min(chars.count, index + hashes + 2)
                    } else { index += 1 }
                }
                tokens.append(.literal(String(chars[begin..<index])))
                index = min(chars.count, index + closing.count)
            } else if chars[index].isLetter || chars[index] == "_" {
                let begin = index
                while index < chars.count && (chars[index].isLetter || chars[index].isNumber || chars[index] == "_") {
                    index += 1
                }
                tokens.append(.code(String(chars[begin..<index])))
            } else {
                if !chars[index].isWhitespace { tokens.append(.code(String(chars[index]))) }
                index += 1
            }
        }
    }
    return tokens
}

private func architectureViolations(_ source: String, pureCore: Bool) -> [String] {
    let tokens = sourceTokens(source)
    let banned = Set(["AVFoundation", "CoreAudio", "ScreenCaptureKit", "AppKit", "SwiftUI", "WhisperKit"])
    let importKinds = Set(["typealias", "struct", "class", "enum", "protocol", "let", "var", "func"])
    let filenames = ["meta.json", "segments.json", "transcript.md", "transcript.prev.md", "capture.lock", ".spool.caf", ".m4a"]
    var violations: [String] = []
    var depth = 0
    var folderDepth: Int?
    var enteringFolder = false
    for (index, token) in tokens.enumerated() {
        if token == .code("struct"), index + 1 < tokens.count, tokens[index + 1] == .code("SessionFolder") {
            enteringFolder = true
        }
        if token == .code("{") {
            depth += 1
            if enteringFolder { folderDepth = depth; enteringFolder = false }
        } else if token == .code("}") {
            if folderDepth == depth { folderDepth = nil }
            depth -= 1
        }
        if pureCore, token == .code("import"), index + 1 < tokens.count {
            var moduleIndex = index + 1
            if case .code(let kind) = tokens[moduleIndex], importKinds.contains(kind) { moduleIndex += 1 }
            if moduleIndex < tokens.count, case .code(let module) = tokens[moduleIndex], banned.contains(module) {
                violations.append("Forbidden RecorderCore import: \(module)")
            }
        }
        if case .literal(let text) = token, folderDepth == nil, filenames.contains(where: text.contains) {
            violations.append("Session file-name literal outside SessionFolder: \(text)")
        }
    }
    return violations
}

@Test func sourceArchitectureBoundaries() throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let sources = package.appendingPathComponent("Sources")
    let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    #expect(!files.isEmpty)
    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        let pureCore = file.pathComponents.contains("RecorderCore")
        for violation in architectureViolations(source, pureCore: pureCore) {
            Issue.record("\(file.lastPathComponent): \(violation)")
        }
    }
}

@Test func architectureChecksIgnoreCommentsAndRespectLiteralBoundaries() {
    let source = ##"""
    // import AVFoundation; "meta.json"
    /* /* nested */ import CoreAudio; "audio-self.m4a" */
    let url = "https://example.test" // "segments.json"
    let documentation = "import SwiftUI"
    struct SessionFolder { var meta: String { "meta.json" } }
    struct Elsewhere { let bad = #"audio-self.m4a"# }
    import class AVFoundation.AVAudioFile
    """##
    #expect(architectureViolations(source, pureCore: true).count == 2)
    #expect(architectureViolations(source, pureCore: false).count == 1)
    #expect(architectureViolations("let bad = \"segments.json\"", pureCore: true).count == 1)
}

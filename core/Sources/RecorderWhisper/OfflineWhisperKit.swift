import Foundation
import NaturalLanguage
import RecorderCore
import WhisperKit

/// Override the SDK's Hub fallback. A broken or missing local tokenizer must fail closed.
final class OfflineWhisperKit: WhisperKit {
    override func loadTokenizerIfNeeded() async throws {
        guard tokenizer == nil else { return }
        guard let folder = tokenizerFolder, let logits = textDecoder.logitsSize else { throw TranscriberError.modelNotInstalled }
        textDecoder.isModelMultilingual = logits != 51864
        tokenizer = try await LocalWhisperTokenizer.load(from: folder)
    }
}

/// Local adapter because WhisperKit 1.1.1 does not expose its tokenizer wrapper initializer.
struct LocalWhisperTokenizer: WhisperTokenizer {
    private let tokenizer: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    static func load(from folder: URL) async throws -> LocalWhisperTokenizer {
        // The modelFolder overload only parses local files; never call the pretrained overload here.
        let tokenizer = try await AutoTokenizerWrapper.from(modelFolder: folder, hubApi: HubApiWrapper(downloadBase: folder))
        return try LocalWhisperTokenizer(tokenizer)
    }

    private init(_ tokenizer: TokenizerWrapper) throws {
        func token(_ name: String) throws -> Int {
            guard let id = tokenizer.convertTokenToId(name) else { throw TranscriberError.modelNotInstalled }
            return id
        }
        let end = try token("<|endoftext|>"), time = try token("<|0.00|>")
        guard time > end, time - end < 10000, let space = tokenizer.encode(text: " ", addSpecialTokens: false).first else {
            throw TranscriberError.modelNotInstalled
        }
        self.tokenizer = tokenizer
        specialTokens = try SpecialTokens(endToken: end, englishToken: token("<|en|>"), noSpeechToken: token("<|nospeech|>"),
            noTimestampsToken: token("<|notimestamps|>"), specialTokenBegin: end, startOfPreviousToken: token("<|startofprev|>"),
            startOfTranscriptToken: token("<|startoftranscript|>"), timeTokenBegin: time, transcribeToken: token("<|transcribe|>"),
            translateToken: token("<|translate|>"), whitespaceToken: space)
        allLanguageTokens = Set((end..<time).filter {
            guard let text = tokenizer.convertIdToToken($0) else { return false }
            return text.range(of: #"^<\|[a-z]{2,3}\|>$"#, options: .regularExpression) != nil
        })
    }

    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        var pending: [Int] = [], units: [(String, [Int])] = []
        for id in tokenIds {
            pending.append(id)
            let text = decode(tokens: pending)
            if text.contains("\u{fffd}") { continue }
            units.append((text, pending)); pending = []
        }
        if !pending.isEmpty { units.append((decode(tokens: pending), pending)) }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(decode(tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin }))
        let language = recognizer.dominantLanguage.flatMap { Locale(identifier: $0.rawValue).language.languageCode?.identifier }
        if ["zh", "ja", "th", "lo", "my", "yue"].contains(language) { return (units.map(\.0), units.map(\.1)) }
        var words: [String] = [], tokens: [[Int]] = []
        for (text, ids) in units {
            let punctuation = !text.isEmpty && text.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
            if words.isEmpty || (ids.first ?? 0) >= specialTokens.specialTokenBegin || text.hasPrefix(" ") || punctuation {
                words.append(text); tokens.append(ids)
            } else {
                words[words.count - 1] += text; tokens[tokens.count - 1] += ids
            }
        }
        return (words, tokens)
    }
}

import Foundation
import RecorderCore
import WhisperKit

/// Internal boundary for testing session ownership without loading Core ML. No SDK types cross it.
protocol WhisperSession: Sendable {
    func transcribe(_ url: URL, language: String) async throws -> [EngineSegmentDTO]
    func fractionCompleted() async -> Double
    func unload() async
}

actor LiveWhisperSession: WhisperSession {
    private let kit: WhisperKit

    init(folder: URL, tokenizerFolder: URL) async throws {
        let kit = try await OfflineWhisperKit(WhisperKitConfig(
            modelFolder: folder.path, tokenizerFolder: tokenizerFolder,
            verbose: false, prewarm: false, load: false, download: false))
        do {
            try await kit.loadModels()
            try Task.checkCancellation()
        } catch {
            await kit.unloadModels()
            throw error
        }
        self.kit = kit
    }

    func transcribe(_ url: URL, language: String) async throws -> [EngineSegmentDTO] {
        var options = DecodingOptions()
        options.language = language
        options.detectLanguage = false
        options.skipSpecialTokens = true
        options.chunkingStrategy = .vad
        // Stream the file rather than allocating one 16 kHz buffer for a long interview.
        let results = try await kit.transcribe(audioPath: url.path,
            audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental), decodeOptions: options)
        // Interpretation belongs to EngineOutput.normalize in Core.
        return results.flatMap(\.segments).map {
            EngineSegmentDTO(start: $0.start, end: $0.end, text: $0.text,
                avgLogprob: $0.avgLogprob, noSpeechProb: $0.noSpeechProb, compressionRatio: $0.compressionRatio)
        }
    }

    func fractionCompleted() -> Double { kit.progress.fractionCompleted }
    func unload() async { await kit.unloadModels() }
}

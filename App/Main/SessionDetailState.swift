import Foundation
import Observation
import RecorderCore

enum SessionTranscriptDisplay: Equatable {
    case loading, absent, loaded([TranscriptLine]), failed(String)
}

@MainActor @Observable
final class SessionDetailState {
    let ref: SessionRef
    var tab: SessionDocumentTab
    private(set) var meta: SessionMeta?
    private(set) var metadataError: String?
    private(set) var transcript: SessionTranscriptDisplay = .loading
    private(set) var markdownAvailable = false
    private(set) var segmentsAvailable = false
    private(set) var exportOutdated = false

    init(ref: SessionRef) {
        self.ref = ref
        tab = FileManager.default.fileExists(atPath: ref.folder.summary.path) ? .summary : .transcript
    }

    func refresh(store: SessionStore) async {
        do {
            let value = try await store.meta(of: ref)
            guard !Task.isCancelled else { return }
            meta = value; metadataError = nil
        } catch { if !Task.isCancelled { metadataError = "録音情報を読み込めませんでした: \(error.localizedDescription)" } }
        do {
            let lines = try await store.transcriptLines(of: ref)
            guard !Task.isCancelled else { return }
            transcript = lines.map(SessionTranscriptDisplay.loaded) ?? .absent
            segmentsAvailable = lines != nil
        } catch { if !Task.isCancelled { transcript = .failed(error.localizedDescription); segmentsAvailable = false } }
        markdownAvailable = FileManager.default.fileExists(atPath: ref.folder.transcript.path)
        if let exported = meta?.export {
            let dates = [ref.folder.transcript, ref.folder.summary].compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            exportOutdated = SessionExportFreshness.isOutdated(exportedAt: exported.at, modifiedAt: dates)
        } else { exportOutdated = false }
    }
}

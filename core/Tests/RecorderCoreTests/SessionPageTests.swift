import Testing
@testable import RecorderCore

struct SessionPageTests {
    struct Row: Sendable {
        let state: SessionState
        let job: TranscriptionJobState?
        let capture: LocalCapture
        let summary: Bool
        let page: SessionPage
        let status: String
        init(_ state: SessionState, _ job: TranscriptionJobState?, _ capture: LocalCapture,
             _ summary: Bool, _ page: SessionPage, _ status: String) {
            self.state = state; self.job = job; self.capture = capture
            self.summary = summary; self.page = page; self.status = status
        }
        init(_ state: SessionState, _ job: TranscriptionJobState?, _ page: SessionPage, _ status: String) {
            self.init(state, job, .none, false, page, status)
        }
    }
    static let rows: [Row] = [
        Row(.capturing, nil, .recording, false, .recording, "録音中"),
        Row(.capturing, .waiting(.recordingInProgress), .recording, false, .recording, "録音中"),
        Row(.capturing, nil, .stopping, false, .saving, "保存中"),
        Row(.needsFinalize, .queued, .stopping, false, .saving, "保存中"),
        Row(.readyToTranscribe, .running(fraction: 0.4), .stopping, false, .saving, "保存中"),
        Row(.capturing, nil, .needsAttention, "別のアプリで録音中"),
        Row(.capturing, .queued, .needsAttention, "別のアプリで録音中"),
        Row(.needsFinalize, nil, .needsAttention, "要対応"),
        Row(.needsFinalize, .failed("error"), .needsAttention, "要対応"),
        Row(.unusable("no audio"), nil, .needsAttention, "録音を確認してください"),
        Row(.unusable("schema"), .running(fraction: 0.5), .needsAttention, "録音を確認してください"),
        Row(.readyToTranscribe, nil, .transcribing, "文字起こし待ち"),
        Row(.readyToTranscribe, .queued, .transcribing, "文字起こし待ち"),
        Row(.readyToTranscribe, .waiting(.modelNotReady), .transcribing, "文字起こし待ち"),
        Row(.readyToTranscribe, .waiting(.recordingInProgress), .transcribing, "文字起こし待ち"),
        Row(.readyToTranscribe, .running(fraction: 0.42), .transcribing, "文字起こし中 42%"),
        Row(.readyToTranscribe, .failed("error"), .transcribing, "文字起こしに失敗"),
        Row(.readyToTranscribe, .done, .transcribing, "文字起こし待ち"),
        Row(.transcribed, nil, .document, "文字起こし済み"),
        Row(.transcribed, .done, .document, "文字起こし済み"),
        Row(.transcribed, nil, .none, true, .document, "要約あり"),
        Row(.transcribed, .done, .none, true, .document, "要約あり"),
        Row(.transcribed, .queued, .transcribing, "文字起こし待ち"),
        Row(.transcribed, .waiting(.modelNotReady), .transcribing, "文字起こし待ち"),
        Row(.transcribed, .waiting(.recordingInProgress), .transcribing, "文字起こし待ち"),
        Row(.transcribed, .running(fraction: 0.75), .none, true, .transcribing, "文字起こし中 75%"),
        Row(.transcribed, .failed("error"), .none, true, .transcribing, "文字起こしに失敗"),
        Row(.readyToTranscribe, .running(fraction: -0.2), .transcribing, "文字起こし中 0%"),
        Row(.readyToTranscribe, .running(fraction: 1.2), .transcribing, "文字起こし中 100%"),
        Row(.readyToTranscribe, .running(fraction: .nan), .transcribing, "文字起こし中 0%")
    ]

    @Test(arguments: rows) func pageAndRowStatus(_ row: Row) {
        #expect(SessionPage.resolve(state: row.state, job: row.job, localCapture: row.capture) == row.page)
        #expect(SessionPage.statusText(state: row.state, job: row.job, localCapture: row.capture, hasSummary: row.summary) == row.status)
    }
}

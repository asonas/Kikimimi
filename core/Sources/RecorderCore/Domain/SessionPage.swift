import Foundation

/// Local capture is exclusive: stopping owns the lease while audio is finalized.
public enum LocalCapture: Sendable, Equatable { case none, recording, stopping }

public enum SessionPage: Sendable, Equatable {
    case recording, saving, transcribing, document, needsAttention

    public static func resolve(state: SessionState, job: TranscriptionJobState?, localCapture: LocalCapture) -> Self {
        switch localCapture {
        case .recording: return .recording
        case .stopping: return .saving
        case .none: break
        }
        // A foreign lease must never expose this process's stop controls.
        switch state {
        case .capturing, .needsFinalize, .unusable: return .needsAttention
        case .readyToTranscribe, .transcribed: break
        }
        switch job {
        case .queued, .waiting, .running, .failed: return .transcribing
        case .done, nil: return state == .transcribed ? .document : .transcribing
        }
    }

    public static func statusText(state: SessionState, job: TranscriptionJobState?, localCapture: LocalCapture,
                                  hasSummary: Bool) -> String {
        switch resolve(state: state, job: job, localCapture: localCapture) {
        case .recording: return "録音中"
        case .saving: return "保存中"
        case .needsAttention:
            switch state {
            case .capturing: return "別のアプリで録音中"
            case .unusable: return "録音を確認してください"
            default: return "要対応"
            }
        case .document: return hasSummary ? "要約あり" : "文字起こし済み"
        case .transcribing:
            switch job {
            case .running(let fraction):
                let percent = fraction.isFinite ? Int(min(1, max(0, fraction)) * 100) : 0
                return "文字起こし中 \(percent)%"
            case .failed: return "文字起こしに失敗"
            default: return "文字起こし待ち"
            }
        }
    }
}

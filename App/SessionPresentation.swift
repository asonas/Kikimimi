import SwiftUI
import RecorderCore

enum SessionDate {
    static func formatted(_ date: Date, _ pattern: String, timeZone: TimeZone? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone ?? .current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
    static func day(_ date: Date) -> String { formatted(date, "M月d日") }
    static func detail(_ date: Date, timeZone: TimeZone? = nil) -> String { formatted(date, "yyyy年M月d日 HH:mm", timeZone: timeZone) }
    static func upcoming(start: Date, end: Date) -> String {
        let day = Calendar.current.isDateInToday(start) ? "今日" : day(start)
        let endPattern = Calendar.current.isDate(start, inSameDayAs: end) ? "HH:mm" : "M月d日 HH:mm"
        return "\(day)  \(formatted(start, "HH:mm"))–\(formatted(end, endPattern))"
    }
    static func duration(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(max(0, seconds)) : 0
        return String(format: "%d分%02d秒", total / 60, total % 60)
    }
    static func range(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = Calendar.current.isDate(start, inSameDayAs: end) ? "HH:mm" : "yyyy/MM/dd HH:mm"
        return "\(string(start))〜\(formatter.string(from: end))"
    }

    static func string(_ date: Date, timeZone: TimeZone? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone ?? .current
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: date)
    }
}

struct TrackMeter: View {
    let label: String
    let peak: Float?
    let health: TrackHealth
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text(health.label).foregroundStyle(health.isProblem ? KikimimiColor.warning : KikimimiColor.secondary)
            }
            .font(KikimimiFont.small.font)
            HStack {
                ProgressView(value: Double(min(1, max(0, ((peak ?? -120) + 75) / 75))))
                    .tint(health.isProblem ? KikimimiColor.warning : KikimimiColor.success)
                    .accessibilityLabel("\(label)の録音レベル")
                Text(String(format: "%.0f dBFS", peak ?? -120)).font(KikimimiFont.number.font).frame(width: 72)
            }
        }
    }
}

extension AppStatus {
    var description: String {
        switch self {
        case .recording(_, let problem): problem ? "録音中・入力を確認してください" : "録音中"
        case .preparing: "録音を準備しています"
        case .saving: "録音を保存しています"
        case .transcribing: "文字起こし中"
        case .needsAttention(let message): message
        case .idle: "録音できます"
        }
    }
}

extension TrackHealth {
    var isProblem: Bool {
        switch self { case .silent, .digitallySilent, .failed: true; default: false }
    }
    var label: String {
        switch self {
        case .waitingForAudio: "音声待ち"
        case .live: "正常"
        case .silent: "無音"
        case .digitallySilent: "入力を確認してください"
        case .failed: "入力が停止しました"
        }
    }
}

extension SessionState {
    var needsAttention: Bool {
        switch self { case .needsFinalize, .unusable: true; default: false }
    }
    var label: String {
        switch self {
        case .capturing: "録音中"
        case .needsFinalize: "要保存処理"
        case .readyToTranscribe: "文字起こし待ち"
        case .transcribed: "文字起こし済み"
        case .unusable: "録音を確認してください"
        }
    }
}

extension TranscriptionJobState {
    var isBusy: Bool {
        switch self { case .queued, .waiting, .running: true; case .failed, .done: false }
    }
    var label: String {
        switch self {
        case .queued: "文字起こし待ち"
        case .waiting(.recordingInProgress): "録音終了後に文字起こし"
        case .waiting(.modelNotReady): "モデルの導入待ち"
        case .running(let fraction): "文字起こし中 \(Int(fraction * 100))%"
        case .failed(let message): "文字起こし失敗: \(message)"
        case .done: "文字起こし済み"
        }
    }
}

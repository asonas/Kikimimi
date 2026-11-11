import SwiftUI
import RecorderCore

enum SessionDocumentTab: String, CaseIterable {
    case transcript = "文字起こし"
    case summary = "要約"
}

struct SessionTranscriptView: View {
    let display: SessionTranscriptDisplay
    var body: some View {
        switch display {
        case .loading: ProgressView("文字起こしを読み込んでいます")
        case .absent: Text("文字起こしはまだありません").foregroundStyle(KikimimiColor.secondary)
        case .failed(let message):
            Text("文字起こしを読み込めませんでした: \(message)")
                .foregroundStyle(KikimimiColor.danger).textSelection(.enabled)
        case .loaded(let lines):
            if lines.isEmpty { Text("表示する発話はありません").foregroundStyle(KikimimiColor.secondary) }
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.timestamp).kikimimiText(.number).foregroundStyle(KikimimiColor.secondary)
                            Text(line.speaker == .me ? "自分" : "相手").kikimimiText(.label)
                        }
                        .frame(width: 88, alignment: .leading)
                        Text(line.text).kikimimiText(.body).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .textSelection(.enabled).frame(maxWidth: 920, alignment: .leading)
        }
    }
}

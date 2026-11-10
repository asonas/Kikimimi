import Foundation

public enum SessionExportError: Error, Sendable, Equatable, LocalizedError {
    case folderMissing
    case metadataFailed(path: String)

    public var errorDescription: String? {
        switch self {
        case .folderMissing: "書き出し先のフォルダが見つかりません。設定で選び直してください"
        case .metadataFailed(let path): "\(path) に書き出しましたが、書き出し履歴を保存できませんでした"
        }
    }
}

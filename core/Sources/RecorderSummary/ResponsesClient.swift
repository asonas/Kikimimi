import Foundation

public protocol BearerTokenSource: Sendable {
    func bearerToken() async throws -> String
}

public enum SummaryError: Error, Sendable, Equatable, LocalizedError {
    case invalidKey
    case rateLimited(code: String?)
    case http(status: Int, message: String)
    case responseFailed(String)
    case incompleteStream
    case invalidStream
    case chatGPT(code: String, param: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidKey: "APIキーが無効です。設定で確認してください"
        case .rateLimited(let code): "リクエスト回数または利用量の上限に達しました" + (code.map { "（\($0)）" } ?? "")
        case .http(let status, let message): "要約APIエラー（\(status)）: \(message)"
        case .responseFailed(let message): "要約に失敗しました: \(message)"
        case .incompleteStream: "要約の受信が完了する前に接続が終了しました"
        case .invalidStream: "要約の応答を読み取れませんでした"
        case .chatGPT(let code, let param):
            switch code {
            case "subscription_sharing_usage_limit_exceeded": "ChatGPT プランの利用上限に達しました。chatgpt.com/settings/usage で確認できます。"
            case "subscription_sharing_user_not_eligible": "このアカウントのプランでは使えません（Plus / Pro が対象）。"
            case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": "一時的に使えません。しばらくしてからお試しください。"
            case "subscription_sharing_invalid_user": "再度サインインしてください"
            case "subscription_sharing_unsupported_capability": "未対応の機能が指定されました（\(param ?? "不明なパラメータ")）"
            default: "ChatGPT の要約に失敗しました"
            }
        }
    }

    static func chatGPTError(code: String?, param: String?) -> SummaryError? {
        guard let code, ["subscription_sharing_usage_limit_exceeded", "subscription_sharing_user_not_eligible",
                         "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable",
                         "subscription_sharing_invalid_user", "subscription_sharing_unsupported_capability"].contains(code) else { return nil }
        return .chatGPT(code: code, param: param)
    }
}

public struct SummaryHTTPResponse: Sendable {
    public let status: Int
    public let body: AsyncThrowingStream<Data, any Error>
    public let cancel: @Sendable () -> Void

    public init(status: Int, body: AsyncThrowingStream<Data, any Error>, cancel: @escaping @Sendable () -> Void = {}) {
        self.status = status; self.body = body; self.cancel = cancel
    }
}

public struct ResponsesClient: Sendable {
    private let transport: @Sendable (URLRequest) async throws -> SummaryHTTPResponse

    public init(transport: @escaping @Sendable (URLRequest) async throws -> SummaryHTTPResponse) {
        self.transport = transport
    }

    public init(session: URLSession = .shared) {
        self.init { request in
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw SummaryError.invalidStream }
            let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            let reader = Task {
                do {
                    var buffer = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if byte == 10 || buffer.count >= 4096 { continuation.yield(buffer); buffer.removeAll(keepingCapacity: true) }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in reader.cancel() }
            return SummaryHTTPResponse(status: response.statusCode, body: body, cancel: { reader.cancel() })
        }
    }

    func request(transcript: String, model: String, token: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "instructions": SummaryPrompt.instructions,
            "input": [["role": "user", "content": [["type": "input_text", "text": transcript]]]],
            "store": false, "stream": true
        ])
        return request
    }

    public func summarize(transcript: String, model: String, tokenSource: any BearerTokenSource) async throws -> String {
        try Task.checkCancellation()
        let token = try await tokenSource.bearerToken()
        try Task.checkCancellation()
        let response = try await transport(request(transcript: transcript, model: model, token: token))
        defer { response.cancel() }
        return try await withTaskCancellationHandler {
            guard (200..<300).contains(response.status) else {
                var data = Data()
                for try await chunk in response.body { try Task.checkCancellation(); data.append(chunk) }
                let error = try? JSONDecoder().decode(ErrorBody.self, from: data).error
                if let mapped = SummaryError.chatGPTError(code: error?.code, param: error?.param) { throw mapped }
                if response.status == 401 { throw SummaryError.invalidKey }
                if response.status == 429 { throw SummaryError.rateLimited(code: error?.code) }
                throw SummaryError.http(status: response.status, message: error?.message ?? "応答を確認できませんでした")
            }
            var parser = SummarySSEParser()
            for try await chunk in response.body {
                try Task.checkCancellation()
                if let result = try parser.append(chunk) { return result }
            }
            try Task.checkCancellation()
            throw SummaryError.incompleteStream
        } onCancel: { response.cancel() }
    }
}

private struct APIError: Decodable {
    let message: String?
    let code: String?
    let param: String?
}
private struct ErrorBody: Decodable { let error: APIError }

private struct SummarySSEParser {
    private var line = Data()
    private var data: [String] = []
    private var eventName = ""
    private var output = ""

    mutating func append(_ chunk: Data) throws -> String? {
        for byte in chunk {
            if byte == 10 {
                guard var text = String(data: line, encoding: .utf8) else { throw SummaryError.invalidStream }
                line.removeAll(keepingCapacity: true)
                if text.hasSuffix("\r") { text.removeLast() }
                if text.isEmpty {
                    if let result = try dispatch() { return result }
                } else if text.hasPrefix("data:") {
                    var value = String(text.dropFirst(5))
                    if value.hasPrefix(" ") { value.removeFirst() }
                    data.append(value)
                } else if text.hasPrefix("event:") {
                    eventName = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                }
            } else { line.append(byte) }
        }
        return nil
    }

    private mutating func dispatch() throws -> String? {
        defer { data.removeAll(keepingCapacity: true); eventName = "" }
        guard !data.isEmpty else { return nil }
        let payload = data.joined(separator: "\n")
        if payload == "[DONE]" { return nil }
        struct Event: Decodable {
            struct Response: Decodable { let error: APIError? }
            let type: String?
            let delta: String?
            let message: String?
            let code: String?
            let param: String?
            let error: APIError?
            let response: Response?
        }
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(payload.utf8)) else {
            throw SummaryError.invalidStream
        }
        switch event.type ?? eventName {
        case "response.output_text.delta":
            guard let delta = event.delta else { throw SummaryError.invalidStream }
            output += delta
        case "response.completed": return output
        case "response.failed", "error":
            let error = event.response?.error ?? event.error ?? APIError(message: event.message, code: event.code, param: event.param)
            if let mapped = SummaryError.chatGPTError(code: error.code, param: error.param) { throw mapped }
            throw SummaryError.responseFailed(error.message ?? "生成が完了しませんでした")
        case "response.incomplete": throw SummaryError.incompleteStream
        default: break
        }
        return nil
    }
}

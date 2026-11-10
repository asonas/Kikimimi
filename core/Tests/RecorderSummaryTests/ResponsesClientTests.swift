import Foundation
import Testing
@testable import RecorderSummary

private struct TestToken: BearerTokenSource {
    func bearerToken() async throws -> String { "test-token-never-sent" }
}

private func body(_ chunks: [Data]) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
    }
}

private func client(_ text: String, status: Int = 200, byteByByte: Bool = false) -> ResponsesClient {
    let chunks = byteByByte ? Array(text.utf8).map { Data([$0]) } : [Data(text.utf8)]
    return ResponsesClient { _ in SummaryHTTPResponse(status: status, body: body(chunks)) }
}

private let delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"日本語の要約\"}\n\n"
private let completed = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"error\":null}}\n\n"

@Test func summaryRequestHasOnlyAllowedFieldsAndUserTranscript() throws {
    let client = client("")
    let request = try client.request(transcript: "面接の原文", model: "gpt-6.1-sol", token: "fake-token")
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let data = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(json.keys) == ["model", "instructions", "input", "store", "stream"])
    #expect(json["model"] as? String == "gpt-6.1-sol")
    #expect(json["instructions"] as? String == SummaryPrompt.instructions)
    #expect(json["store"] as? Bool == false)
    #expect(json["stream"] as? Bool == true)
    for key in ["temperature", "top_p", "max_output_tokens", "metadata", "user", "previous_response_id",
                "truncation", "background", "conversation", "prompt", "safety_identifier"] { #expect(json[key] == nil) }
    let input = try #require(json["input"] as? [[String: Any]])
    #expect(input.count == 1)
    #expect(input.first?["role"] as? String == "user")
    let content = try #require(input.first?["content"] as? [[String: String]])
    #expect(content == [["type": "input_text", "text": "面接の原文"]])
}

@Test func summaryJoinsDeltasAndRequiresCompletedAcrossEveryUTF8ChunkBoundary() async throws {
    let stream = ": heartbeat\r\n\r\n" + delta
        + "event: response.output_text.delta\r\ndata: {\"delta\":\"です。\"}\r\n\r\n" + completed
    for split in [false, true] {
        let result = try await client(stream, byteByByte: split).summarize(transcript: "input", model: "test", tokenSource: TestToken())
        #expect(result == "日本語の要約です。")
    }
}

@Test func summaryFailedAndErrorEventsRejectPartialText() async throws {
    for terminal in [
        "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"failed\",\"code\":\"server_error\"}}}\n\n",
        "event: error\ndata: {\"type\":\"error\",\"message\":\"failed\",\"code\":\"server_error\"}\n\n"
    ] {
        await #expect(throws: SummaryError.responseFailed("failed")) {
            try await client(delta + terminal, byteByByte: true).summarize(transcript: "input", model: "test", tokenSource: TestToken())
        }
    }
}

@Test func summaryRejectsMissingCompletedIncompleteAndMalformedStreams() async throws {
    for text in ["", delta, delta + "data: [DONE]\n\n", delta + "data: {\"type\":\"response.completed\"}",
                 delta + "data: {\"type\":\"response.incomplete\"}\n\n"] {
        await #expect(throws: SummaryError.incompleteStream) {
            try await client(text).summarize(transcript: "input", model: "test", tokenSource: TestToken())
        }
    }
    await #expect(throws: SummaryError.invalidStream) {
        try await client(delta + "data: invalid json\n\n").summarize(transcript: "input", model: "test", tokenSource: TestToken())
    }
}

@Test func summaryMapsHTTPAuthenticationLimitsAndGenericErrors() async throws {
    await #expect(throws: SummaryError.invalidKey) {
        try await client("{}", status: 401).summarize(transcript: "input", model: "test", tokenSource: TestToken())
    }
    await #expect(throws: SummaryError.chatGPT(code: "subscription_sharing_usage_limit_exceeded", param: nil)) {
        try await client(#"{"error":{"message":"limit","code":"subscription_sharing_usage_limit_exceeded"}}"#, status: 429)
            .summarize(transcript: "input", model: "test", tokenSource: TestToken())
    }
    await #expect(throws: SummaryError.http(status: 503, message: "unavailable")) {
        try await client(#"{"error":{"message":"unavailable","code":"server_error"}}"#, status: 503)
            .summarize(transcript: "input", model: "test", tokenSource: TestToken())
    }
}

@Test func summaryMapsChatGPTSubscriptionCodesForHTTPAndFailedStream() async throws {
    for (code, status) in [("subscription_sharing_usage_limit_exceeded", 429), ("subscription_sharing_user_not_eligible", 403),
                           ("subscription_sharing_usage_unavailable", 503), ("subscription_sharing_user_unavailable", 503),
                           ("subscription_sharing_invalid_user", 401), ("subscription_sharing_unsupported_capability", 400)] {
        let error = ["code": code, "message": "failure", "param": "tools"]
        let data = try JSONSerialization.data(withJSONObject: ["error": error])
        let http = ResponsesClient { _ in SummaryHTTPResponse(status: status, body: body([data])) }
        let expected = SummaryError.chatGPT(code: code, param: "tools")
        await #expect(throws: expected) { try await http.summarize(transcript: "input", model: "test", tokenSource: TestToken()) }
        let event = try JSONSerialization.data(withJSONObject: ["type": "response.failed", "response": ["error": error]])
        let stream = client(delta + "data: " + String(decoding: event, as: UTF8.self) + "\n\n")
        await #expect(throws: expected) { try await stream.summarize(transcript: "input", model: "test", tokenSource: TestToken()) }
        if code == "subscription_sharing_unsupported_capability" { #expect(expected.localizedDescription.contains("tools")) }
    }
}

@Test func summaryTransportReceivesBearerFromSourceAndCancellationRejectsResult() async throws {
    let client = ResponsesClient { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-never-sent")
        return SummaryHTTPResponse(status: 200, body: body([Data((delta + completed).utf8)]))
    }
    #expect(try await client.summarize(transcript: "input", model: "test", tokenSource: TestToken()) == "日本語の要約")
    let started = StreamStarted()
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    continuation.yield(Data(delta.utf8))
    let stalled = ResponsesClient { _ in
        await started.signal()
        return SummaryHTTPResponse(status: 200, body: stream, cancel: {
            continuation.finish(throwing: CancellationError())
        })
    }
    let task = Task {
        try await stalled.summarize(transcript: "input", model: "test", tokenSource: TestToken())
    }
    await started.wait()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

private actor StreamStarted {
    private var signalled = false
    private var continuation: CheckedContinuation<Void, Never>?
    func signal() { signalled = true; continuation?.resume(); continuation = nil }
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

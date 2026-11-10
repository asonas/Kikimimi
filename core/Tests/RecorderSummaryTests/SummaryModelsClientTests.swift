import Foundation
import RecorderCore
import Testing
@testable import RecorderSummary

private struct ModelsToken: BearerTokenSource {
    func bearerToken() async throws -> String { "test-model-token" }
}

private func modelsClient(_ json: String, status: Int = 200) -> SummaryModelsClient {
    SummaryModelsClient { _ in (status: status, data: Data(json.utf8)) }
}

@Test func summaryModelsDecodesAPIDataLenientlyAndBuildsAuthenticatedGET() async throws {
    let client = SummaryModelsClient { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-model-token")
        #expect(request.httpBody == nil)
        return (status: 200, data: Data(#"{"object":"list","unknown":true,"data":[{"id":"new","object":"model","created":200,"owned_by":"openai","visibility":"list","extra":{}},{"id":"old","owned_by":"openai"}]}"#.utf8))
    }
    let models = try await client.models(provider: .apiKey, tokenSource: ModelsToken())
    #expect(models == [.init(id: "new", visibility: "list", created: 200), .init(id: "old")])
}

@Test func summaryModelsDecodesChatGPTModelsSlugsDisplayNamesAndPreservesServerOrder() async throws {
    let client = modelsClient(#"{"models":[{"slug":"older","display_name":"Older model","visibility":"list","created":100,"unknown":true},{"slug":"hidden","display_name":"Hidden model","visibility":"hidden"},{"slug":"newer","display_name":"New model","visibility":"list","created":200},{"slug":"missing-visibility","display_name":"Missing"}]}"#)
    let models = try await client.models(provider: .chatGPT, tokenSource: ModelsToken())
    #expect(models.map(\.id) == ["older", "newer"])
    #expect(models.map(\.displayName) == ["Older model", "New model"])
    let noCreated = try await modelsClient(#"{"models":[{"slug":"gpt","display_name":"GPT","visibility":"list"}]}"#)
        .models(provider: .chatGPT, tokenSource: ModelsToken())
    #expect(noCreated == [.init(id: "gpt", displayName: "GPT", visibility: "list")])
}

@Test func summaryModelsChatGPTFilterRequiresExactListVisibilityInEitherShape() async throws {
    let client = modelsClient(#"{"data":[{"id":"second","visibility":"list","created":1},{"id":"hidden","visibility":"hidden"},{"id":"first","visibility":"list","created":9},{"id":"missing"}]}"#)
    #expect(try await client.models(provider: .chatGPT, tokenSource: ModelsToken()).map(\.id) == ["second", "first"])
}

@Test func summaryModelsAPIKeyFilterDropsOnlyDeclaredNonTextKinds() {
    let banned = ["embedding", "tts", "whisper", "transcribe", "audio", "realtime", "image", "dall-e",
                  "moderation", "search", "davinci", "babbage", "computer-use"]
    let excluded = banned.map { SummaryModel(id: "PREFIX-\($0.uppercased())-suffix", visibility: "list") }
    let kept = [SummaryModel(id: "gpt-6.1-sol"), .init(id: "o3"), .init(id: "custom-text", visibility: "hidden")]
    #expect(SummaryModelCatalog.select(excluded + kept, provider: .apiKey).map(\.id) == ["custom-text", "gpt-6.1-sol", "o3"])
}

@Test func summaryModelsAPIKeySortsNewestThenIDWithMissingCreatedLast() {
    let models: [SummaryModel] = [.init(id: "z-missing"), .init(id: "b-new", created: 20),
                                  .init(id: "old", created: 10), .init(id: "a-new", created: 20), .init(id: "a-missing")]
    #expect(SummaryModelCatalog.select(models, provider: .apiKey).map(\.id) == ["a-new", "b-new", "old", "a-missing", "z-missing"])
}

@Test func summaryModelsReusesResponsesHTTPErrorMappingAndProviderSpecificUnauthorized() async throws {
    await #expect(throws: SummaryError.invalidKey) {
        try await modelsClient("{}", status: 401).models(provider: .apiKey, tokenSource: ModelsToken())
    }
    await #expect(throws: SummaryError.signInAgain) {
        try await modelsClient("{}", status: 401).models(provider: .chatGPT, tokenSource: ModelsToken())
    }
    for (code, status) in [("rate_limit_exceeded", 429), ("subscription_sharing_usage_limit_exceeded", 429),
                           ("subscription_sharing_user_not_eligible", 403), ("subscription_sharing_invalid_user", 401),
                           ("subscription_sharing_usage_unavailable", 503), ("subscription_sharing_user_unavailable", 503),
                           ("subscription_sharing_unsupported_capability", 400), ("server_error", 500)] {
        let data = try JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": "failure", "param": "model"]])
        let expected = SummaryError.httpFailure(status: status, data: data)
        let client = SummaryModelsClient { _ in (status: status, data: data) }
        await #expect(throws: expected) { try await client.models(provider: .apiKey, tokenSource: ModelsToken()) }
        await #expect(throws: expected) { try await client.models(provider: .chatGPT, tokenSource: ModelsToken()) }
    }
}

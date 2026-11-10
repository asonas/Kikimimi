import Foundation
import RecorderCore

public struct SummaryModel: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let displayName: String?
    public let visibility: String?
    public let created: Double?

    public init(id: String, displayName: String? = nil, visibility: String? = nil, created: Double? = nil) {
        self.id = id; self.displayName = displayName; self.visibility = visibility; self.created = created
    }

    private enum CodingKeys: String, CodingKey { case id, slug, displayName = "display_name", visibility, created }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? c.decode(String.self, forKey: .slug)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
        created = try c.decodeIfPresent(Double.self, forKey: .created)
    }
}

public enum SummaryModelCatalog {
    public static func select(_ models: [SummaryModel], provider: SummaryProvider) -> [SummaryModel] {
        switch provider {
        case .chatGPT: return models.filter { $0.visibility == "list" }
        case .apiKey:
            let excluded = ["embedding", "tts", "whisper", "transcribe", "audio", "realtime", "image", "dall-e",
                            "moderation", "search", "davinci", "babbage", "computer-use"]
            return models.filter { model in !excluded.contains(where: model.id.lowercased().contains) }
                .sorted {
                    if $0.created != $1.created { return ($0.created ?? -.infinity) > ($1.created ?? -.infinity) }
                    return $0.id < $1.id
                }
        }
    }
}

public struct SummaryModelsClient: Sendable {
    private let transport: @Sendable (URLRequest) async throws -> (status: Int, data: Data)

    public init(transport: @escaping @Sendable (URLRequest) async throws -> (status: Int, data: Data)) {
        self.transport = transport
    }
    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.init { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw SummaryError.invalidStream }
            return (status: response.statusCode, data: data)
        }
    }

    public func models(provider: SummaryProvider, tokenSource: any BearerTokenSource) async throws -> [SummaryModel] {
        try Task.checkCancellation()
        let token = try await tokenSource.bearerToken()
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await transport(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.status) else {
            throw SummaryError.httpFailure(status: response.status, data: response.data,
                                           unauthorized: provider == .chatGPT ? .signInAgain : .invalidKey)
        }
        struct Catalog: Decodable {
            let models: [SummaryModel]
            enum CodingKeys: String, CodingKey { case data, models }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                models = try c.contains(.data) ? c.decode([SummaryModel].self, forKey: .data)
                    : c.decode([SummaryModel].self, forKey: .models)
            }
        }
        return SummaryModelCatalog.select(try JSONDecoder().decode(Catalog.self, from: response.data).models, provider: provider)
    }
}

import CryptoKit
import Foundation
import Security

public enum ChatGPTAuthError: Error, Sendable, Equatable, LocalizedError {
    case notSignedIn, signInAgain, invalidCallback, stateMismatch, clientMismatch, invalidIDToken, missingPermission
    case endpoint(String), timedOut, browserUnavailable

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "サインインしていません"
        case .signInAgain: "再度サインインしてください"
        case .invalidCallback: "サインインの応答を確認できませんでした"
        case .stateMismatch: "サインインの確認情報が一致しません"
        case .clientMismatch: "サインイン先の登録情報が一致しません"
        case .invalidIDToken: "サインインしたアカウントを検証できませんでした"
        case .missingPermission: "ChatGPT のプランの利用が許可されませんでした"
        case .endpoint(let code): "ChatGPT の認証に失敗しました（\(code)）"
        case .timedOut: "サインインがタイムアウトしました。もう一度お試しください"
        case .browserUnavailable: "サインイン用のブラウザーを開けませんでした"
        }
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ text: String) -> Data? {
        let value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
}

public struct OAuthSecrets: Sendable {
    public let state: String
    public let nonce: String
    public let verifier: String

    public init() throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw ChatGPTAuthError.invalidCallback
            }
            return Base64URL.encode(Data(bytes))
        }
        state = try random(); nonce = try random(); verifier = try random()
    }
    init(state: String, nonce: String, verifier: String) {
        self.state = state; self.nonce = nonce; self.verifier = verifier
    }
    public var challenge: String { Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8)))) }
}

public enum OAuthCallback: Sendable, Equatable {
    case declined
    case authorized(code: String, clientID: String)
}

public struct OAuthAttempt: Sendable {
    public let secrets: OAuthSecrets
    public let redirectURI: URL
    public let registration: ChatGPTRecord

    public init(secrets: OAuthSecrets, redirectURI: URL, registration: ChatGPTRecord) throws {
        guard redirectURI.scheme == "http", redirectURI.host == "127.0.0.1",
              redirectURI.port != nil, redirectURI.path == "/auth/callback",
              redirectURI.query == nil, redirectURI.fragment == nil, redirectURI.user == nil else {
            throw ChatGPTAuthError.invalidCallback
        }
        self.secrets = secrets; self.redirectURI = redirectURI; self.registration = registration
    }

    public func authorizeURL() -> URL {
        var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: registration.clientID ?? "dynamic_agent_client"),
            URLQueryItem(name: "ext_agent_host_id", value: registration.hostID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
            URLQueryItem(name: "resource", value: ChatGPTOAuthClient.resource),
            URLQueryItem(name: "state", value: secrets.state), URLQueryItem(name: "nonce", value: secrets.nonce),
            URLQueryItem(name: "code_challenge", value: secrets.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        if registration.clientID == nil { items.append(URLQueryItem(name: "agent_name_hint", value: "Kikimimi")) }
        else if let email = registration.email { items.append(URLQueryItem(name: "login_hint", value: email)) }
        components.queryItems = items
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    public static func callback(requestLine: String, state: String, savedClientID: String?) throws -> OAuthCallback {
        let fields = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "GET", ["HTTP/1.0", "HTTP/1.1"].contains(fields[2]),
              fields[1].hasPrefix("/auth/callback?"),
              let components = URLComponents(string: "http://127.0.0.1" + fields[1]),
              components.path == "/auth/callback", components.fragment == nil else { throw ChatGPTAuthError.invalidCallback }
        let items = components.queryItems ?? []
        for key in ["state", "code", "client_id", "error"] where items.filter({ $0.name == key }).count > 1 {
            throw ChatGPTAuthError.invalidCallback
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { throw ChatGPTAuthError.stateMismatch }
        if let savedClientID, let returned = value("client_id"), returned != savedClientID {
            throw ChatGPTAuthError.clientMismatch
        }
        if let error = value("error") {
            if error == "access_denied" { return .declined }
            throw ChatGPTAuthError.endpoint(error)
        }
        guard let code = value("code"), !code.isEmpty else { throw ChatGPTAuthError.invalidCallback }
        let clientID: String
        if let savedClientID {
            clientID = savedClientID
        } else {
            guard let issued = value("client_id"), !issued.isEmpty, issued != "dynamic_agent_client" else {
                throw ChatGPTAuthError.invalidCallback
            }
            clientID = issued
        }
        return .authorized(code: code, clientID: clientID)
    }
}

public struct ChatGPTRecord: Sendable, Codable, Equatable {
    public var clientID: String?
    public let hostID: String
    public var email: String?
    public var sub: String?
    public var accessToken: String?
    public var refreshToken: String?
    public var idToken: String?
    public var expiresAt: Date?
    public var earliestRefreshAt: Date?
    public var scopes: Set<String> = []

    public init(hostID: String = "urn:uuid:\(UUID().uuidString)") { self.hostID = hostID }

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id", hostID = "ext_agent_host_id", email, sub, accessToken = "access_token"
        case refreshToken = "refresh_token", idToken = "id_token", expiresAt = "expires_at"
        case earliestRefreshAt = "earliest_refresh_at", scopes
    }

    public var isSignedIn: Bool {
        clientID != nil && accessToken != nil && refreshToken != nil && idToken != nil && expiresAt != nil
            && scopes.contains("chatgpt.tokens.use.direct")
    }

    public mutating func clearTokens() {
        accessToken = nil; refreshToken = nil; idToken = nil; expiresAt = nil; earliestRefreshAt = nil; scopes = []
    }

    func needsRefresh(now: Date) -> Bool {
        guard let expiresAt else { return true }
        if expiresAt <= now { return true }
        if let earliestRefreshAt, earliestRefreshAt > now { return false }
        return expiresAt.timeIntervalSince(now) <= 120
    }
}

struct OAuthTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let tokenType: String
    let expiresIn: Double
    let scopes: Set<String>
    let earliestRefreshAt: Date?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token", tokenType = "token_type"
        case expiresIn = "expires_in", scope, earliestRefreshAt = "earliest_refresh_at"
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        idToken = try c.decode(String.self, forKey: .idToken)
        tokenType = try c.decode(String.self, forKey: .tokenType)
        expiresIn = try c.decode(Double.self, forKey: .expiresIn)
        scopes = Set(try c.decode(String.self, forKey: .scope).split(separator: " ").map(String.init))
        if let seconds = try? c.decode(Double.self, forKey: .earliestRefreshAt), seconds.isFinite {
            earliestRefreshAt = Date(timeIntervalSince1970: seconds)
        } else if let text = try? c.decode(String.self, forKey: .earliestRefreshAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: text)
            formatter.formatOptions = [.withInternetDateTime]
            earliestRefreshAt = fractional ?? formatter.date(from: text)
        } else { earliestRefreshAt = nil }
        guard scopes.contains("chatgpt.tokens.use.direct") else { throw ChatGPTAuthError.missingPermission }
        guard tokenType.lowercased() == "bearer", !accessToken.isEmpty, !refreshToken.isEmpty,
              !idToken.isEmpty, expiresIn.isFinite, expiresIn > 0 else { throw ChatGPTAuthError.signInAgain }
    }
}

public struct OAuthHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}

public struct ChatGPTOAuthClient: Sendable {
    static let resource = "https://api.openai.com/v1"
    private let transport: @Sendable (URLRequest) async throws -> OAuthHTTPResponse

    public init(transport: @escaping @Sendable (URLRequest) async throws -> OAuthHTTPResponse) { self.transport = transport }
    public init(session: URLSession = .shared) {
        self.init { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ChatGPTAuthError.endpoint("invalid_response") }
            return OAuthHTTPResponse(status: response.statusCode, data: data)
        }
    }

    static func formRequest(endpoint: String, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "="
                + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
        return request
    }

    func codeRequest(code: String, clientID: String, attempt: OAuthAttempt) -> URLRequest {
        Self.formRequest(endpoint: "https://auth.openai.com/api/accounts/oauth/token", fields: [
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": attempt.secrets.verifier, "redirect_uri": attempt.redirectURI.absoluteString, "resource": Self.resource
        ])
    }
    func refreshRequest(_ record: ChatGPTRecord) throws -> URLRequest {
        guard let clientID = record.clientID, clientID != "dynamic_agent_client", let refresh = record.refreshToken else {
            throw ChatGPTAuthError.notSignedIn
        }
        return Self.formRequest(endpoint: "https://auth.openai.com/api/accounts/oauth/token", fields: [
            "grant_type": "refresh_token", "client_id": clientID, "refresh_token": refresh, "resource": Self.resource
        ])
    }
    func revokeRequest(_ record: ChatGPTRecord) throws -> URLRequest {
        guard let clientID = record.clientID, let token = record.refreshToken else { throw ChatGPTAuthError.notSignedIn }
        return Self.formRequest(endpoint: "https://auth.openai.com/api/accounts/oauth/revoke", fields: [
            "token": token, "token_type_hint": "refresh_token", "client_id": clientID
        ])
    }

    public static func isTerminalRefreshError(_ code: String) -> Bool {
        ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
         "refresh_token_invalidated", "refresh_token_reused"].contains(code)
    }

    private func token(_ request: URLRequest, refreshing: Bool) async throws -> OAuthTokenResponse {
        let response = try await transport(request)
        guard response.status == 200 else {
            struct Failure: Decodable { let error: String }
            let code = (try? JSONDecoder().decode(Failure.self, from: response.data).error) ?? "http_\(response.status)"
            if refreshing && Self.isTerminalRefreshError(code) { throw ChatGPTAuthError.signInAgain }
            if !refreshing && code == "invalid_grant" { throw ChatGPTAuthError.signInAgain }
            throw ChatGPTAuthError.endpoint(code)
        }
        return try JSONDecoder().decode(OAuthTokenResponse.self, from: response.data)
    }

    public func signIn(code: String, clientID: String, attempt: OAuthAttempt, now: Date = Date()) async throws -> ChatGPTRecord {
        let token = try await token(codeRequest(code: code, clientID: clientID, attempt: attempt), refreshing: false)
        return try await validatedRecord(token, registration: attempt.registration, clientID: clientID, nonce: attempt.secrets.nonce, now: now)
    }

    public func refresh(_ record: ChatGPTRecord, now: Date = Date()) async throws -> ChatGPTRecord {
        let token = try await token(refreshRequest(record), refreshing: true)
        return try await validatedRecord(token, registration: record, clientID: record.clientID!, nonce: nil, now: now)
    }

    private func validatedRecord(_ token: OAuthTokenResponse, registration: ChatGPTRecord, clientID: String,
                                 nonce: String?, now: Date) async throws -> ChatGPTRecord {
        let keys = try await transport(URLRequest(url: URL(string: "https://auth.openai.com/.well-known/jwks.json")!))
        guard keys.status == 200 else { throw ChatGPTAuthError.invalidIDToken }
        let identity = try IDTokenValidator.validate(token.idToken, jwks: keys.data, clientID: clientID, nonce: nonce, now: now)
        if let sub = registration.sub, sub != identity.sub { throw ChatGPTAuthError.clientMismatch }
        var record = registration
        record.clientID = clientID; record.email = identity.email; record.sub = identity.sub
        record.accessToken = token.accessToken; record.refreshToken = token.refreshToken; record.idToken = token.idToken
        record.expiresAt = now.addingTimeInterval(token.expiresIn); record.earliestRefreshAt = token.earliestRefreshAt; record.scopes = token.scopes
        return record
    }

    public func revoke(_ record: ChatGPTRecord) async throws {
        let response = try await transport(revokeRequest(record))
        guard response.status == 200 else { throw ChatGPTAuthError.endpoint("http_\(response.status)") }
    }
}

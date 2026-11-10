import Foundation
import Security
import Testing
@testable import RecorderSummary

private let authNow = Date(timeIntervalSince1970: 1_800_000_000)
private let authSecrets = OAuthSecrets(state: "state", nonce: "nonce", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")

private func attempt(_ record: ChatGPTRecord = ChatGPTRecord(hostID: "urn:uuid:test")) throws -> OAuthAttempt {
    try OAuthAttempt(secrets: authSecrets, redirectURI: URL(string: "http://127.0.0.1:1455/auth/callback")!, registration: record)
}

private func form(_ request: URLRequest) throws -> [String: String] {
    let data = try #require(request.httpBody)
    let body = try #require(String(data: data, encoding: .utf8))
    let components = try #require(URLComponents(string: "https://test.invalid/?" + body))
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

@Test func chatGPTAuthorizeURLUsesOnlySpecifiedFirstAndReturningParameters() throws {
    let first = try attempt()
    let parameters = try #require(URLComponents(url: first.authorizeURL(), resolvingAgainstBaseURL: false)?.queryItems)
    let fields = Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.value ?? "") })
    #expect(Set(fields.keys) == ["response_type", "client_id", "agent_name_hint", "ext_agent_host_id", "redirect_uri",
                                 "scope", "resource", "state", "nonce", "code_challenge", "code_challenge_method"])
    #expect(first.authorizeURL().host == "auth.openai.com")
    #expect(first.authorizeURL().path == "/api/accounts/authorize")
    #expect(fields["response_type"] == "code")
    #expect(fields["client_id"] == "dynamic_agent_client")
    #expect(fields["agent_name_hint"] == "Kikimimi")
    #expect(fields["ext_agent_host_id"] == "urn:uuid:test")
    #expect(fields["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
    #expect(fields["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
    #expect(fields["resource"] == "https://api.openai.com/v1")
    #expect(fields["state"] == "state")
    #expect(fields["nonce"] == "nonce")
    #expect(fields["code_challenge_method"] == "S256")
    #expect(fields["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    var registration = first.registration
    registration.clientID = "oaiapp_test"; registration.email = "test+label@example.com"
    let returning = try attempt(registration)
    let returned = try #require(URLComponents(url: returning.authorizeURL(), resolvingAgainstBaseURL: false)?.queryItems)
    let reauth = Dictionary(uniqueKeysWithValues: returned.map { ($0.name, $0.value ?? "") })
    #expect(reauth["client_id"] == "oaiapp_test")
    #expect(reauth["agent_name_hint"] == nil)
    #expect(reauth["login_hint"] == "test+label@example.com")
    #expect(returning.authorizeURL().absoluteString.contains("test%2Blabel"))
    #expect(reauth["ext_agent_host_id"] == fields["ext_agent_host_id"])
    #expect(Set(reauth.keys) == Set(fields.keys).subtracting(["agent_name_hint"]).union(["login_hint"]))
    #expect(throws: ChatGPTAuthError.invalidCallback) {
        try OAuthAttempt(secrets: authSecrets, redirectURI: URL(string: "http://localhost:1455/auth/callback")!, registration: registration)
    }
    let secrets = try OAuthSecrets()
    #expect(secrets.state != secrets.nonce)
    #expect(secrets.verifier.count >= 43)
    #expect(!secrets.challenge.contains("="))
}

@Test func chatGPTCallbackVerifiesStateAndIssuedClientBeforeUsingCode() throws {
    func callback(_ query: String, saved: String? = nil) throws -> OAuthCallback {
        try OAuthAttempt.callback(requestLine: "GET /auth/callback?\(query) HTTP/1.1", state: "state", savedClientID: saved)
    }
    #expect(try callback("code=a%2Bb&state=state&client_id=oaiapp_test&scope=openid") == .authorized(code: "a+b", clientID: "oaiapp_test"))
    #expect(try callback("code=abc&state=state", saved: "oaiapp_test") == .authorized(code: "abc", clientID: "oaiapp_test"))
    #expect(try callback("code=abc&state=state&client_id=oaiapp_test", saved: "oaiapp_test") == .authorized(code: "abc", clientID: "oaiapp_test"))
    #expect(try callback("error=access_denied&state=state") == .declined)
    #expect(throws: ChatGPTAuthError.stateMismatch) { try callback("error=access_denied&state=wrong") }
    #expect(throws: ChatGPTAuthError.stateMismatch) { try callback("code=abc&client_id=oaiapp_test") }
    #expect(throws: ChatGPTAuthError.clientMismatch) { try callback("code=abc&state=state&client_id=other", saved: "oaiapp_test") }
    for query in ["code=abc&state=state", "code=abc&state=state&client_id=dynamic_agent_client",
                  "code=abc&state=state&state=state&client_id=oaiapp_test"] {
        #expect(throws: ChatGPTAuthError.invalidCallback) { try callback(query) }
    }
    #expect(throws: ChatGPTAuthError.invalidCallback) {
        try OAuthAttempt.callback(requestLine: "POST /auth/callback?state=state HTTP/1.1", state: "state", savedClientID: nil)
    }
}

private func tokenData(idToken: String = "id", refresh: String = "rotated", earliest: Any? = nil,
                       scope: String = "openid chatgpt.tokens.use.direct") throws -> Data {
    var json: [String: Any] = ["access_token": "new-access", "refresh_token": refresh, "id_token": idToken,
                               "token_type": "Bearer", "expires_in": 3600, "scope": scope]
    if let earliest { json["earliest_refresh_at"] = earliest }
    return try JSONSerialization.data(withJSONObject: json)
}

@Test func chatGPTTokenResponseReadsEarliestRefreshAsUnixSecondsISO8601OrMissing() throws {
    for earliest: Any in [authNow.timeIntervalSince1970, "2027-01-15T08:00:00Z", "2027-01-15T08:00:00.000Z"] {
        let token = try JSONDecoder().decode(OAuthTokenResponse.self, from: tokenData(earliest: earliest))
        #expect(token.earliestRefreshAt == authNow)
        #expect(token.scopes.contains("chatgpt.tokens.use.direct"))
        #expect(token.refreshToken == "rotated")
    }
    for earliest in [nil, "invalid", ["bad": true], NSNull()] as [Any?] {
        #expect(try JSONDecoder().decode(OAuthTokenResponse.self, from: tokenData(earliest: earliest)).earliestRefreshAt == nil)
    }
    #expect(throws: ChatGPTAuthError.missingPermission) {
        try JSONDecoder().decode(OAuthTokenResponse.self, from: tokenData(scope: "openid profile email"))
    }
}

@Test func chatGPTCodeRefreshAndRevokeRequestsContainOnlyDocumentedFields() throws {
    let client = ChatGPTOAuthClient { _ in throw ChatGPTAuthError.endpoint("unexpected_transport") }
    let attempt = try attempt()
    let code = client.codeRequest(code: "a+b &", clientID: "oaiapp_test", attempt: attempt)
    #expect(try form(code) == ["grant_type": "authorization_code", "client_id": "oaiapp_test", "code": "a+b &",
                              "code_verifier": authSecrets.verifier, "redirect_uri": attempt.redirectURI.absoluteString,
                              "resource": "https://api.openai.com/v1"])
    #expect(code.httpMethod == "POST")
    #expect(code.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    var record = ChatGPTRecord(); record.clientID = "oaiapp_test"; record.refreshToken = "refresh"
    #expect(try form(client.refreshRequest(record)) == ["grant_type": "refresh_token", "client_id": "oaiapp_test",
                                                       "refresh_token": "refresh", "resource": "https://api.openai.com/v1"])
    #expect(try form(client.revokeRequest(record)) == ["token": "refresh", "token_type_hint": "refresh_token", "client_id": "oaiapp_test"])
    #expect(try client.revokeRequest(record).url?.absoluteString == "https://auth.openai.com/api/accounts/oauth/revoke")
    for error in ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"] {
        #expect(ChatGPTOAuthClient.isTerminalRefreshError(error))
    }
    #expect(!ChatGPTOAuthClient.isTerminalRefreshError("invalid_client"))
    #expect(!ChatGPTOAuthClient.isTerminalRefreshError("server_error"))
}

@Test func chatGPTEarliestRefreshDelaysOnlyUnexpiredTokens() {
    var record = ChatGPTRecord()
    record.expiresAt = authNow.addingTimeInterval(121)
    #expect(!record.needsRefresh(now: authNow))
    record.expiresAt = authNow.addingTimeInterval(120)
    #expect(record.needsRefresh(now: authNow))
    record.earliestRefreshAt = authNow.addingTimeInterval(600)
    #expect(!record.needsRefresh(now: authNow))
    record.expiresAt = authNow
    #expect(record.needsRefresh(now: authNow))
    record.earliestRefreshAt = authNow
    #expect(record.needsRefresh(now: authNow))
}

private struct TestRSA {
    let key: SecKey
    let jwks: Data
    init() throws {
        key = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                                kSecAttrKeySizeInBits: 2048, kSecAttrIsPermanent: false] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        let bytes = Array(der)
        var index = 0
        func length() -> Int {
            let first = Int(bytes[index]); index += 1
            if first < 128 { return first }
            var value = 0
            for _ in 0..<(first & 127) { value = value * 256 + Int(bytes[index]); index += 1 }
            return value
        }
        #expect(bytes[index] == 0x30); index += 1; _ = length()
        #expect(bytes[index] == 0x02); index += 1
        let nSize = length(); let n = Data(bytes[index..<(index + nSize)].drop(while: { $0 == 0 })); index += nSize
        #expect(bytes[index] == 0x02); index += 1
        let eSize = length(); let e = Data(bytes[index..<(index + eSize)])
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "test", "kty": "RSA", "alg": "RS256",
                                                                  "n": Base64URL.encode(n), "e": Base64URL.encode(e)]]])
    }
    func jwt(changes: [String: Any] = [:], alg: String = "RS256") throws -> String {
        let header = Base64URL.encode(try JSONSerialization.data(withJSONObject: ["kid": "test", "alg": alg]))
        var claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": "oaiapp_test", "exp": authNow.addingTimeInterval(3600).timeIntervalSince1970,
                                     "nonce": "nonce", "sub": "user", "email": "test@example.com"]
        claims.merge(changes) { _, new in new }
        let payload = Base64URL.encode(try JSONSerialization.data(withJSONObject: claims))
        let content = header + "." + payload
        let signature = try #require(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(content.utf8) as CFData, nil)) as Data
        return content + "." + Base64URL.encode(signature)
    }
}

@Test func chatGPTIDTokenVerifiesSignatureIssuerAudienceExpiryAndNonce() throws {
    let rsa = try TestRSA()
    for aud: Any in ["oaiapp_test", ["other", "oaiapp_test"]] {
        let identity = try IDTokenValidator.validate(rsa.jwt(changes: ["aud": aud]), jwks: rsa.jwks,
                                                      clientID: "oaiapp_test", nonce: "nonce", now: authNow)
        #expect(identity.sub == "user")
        #expect(identity.email == "test@example.com")
    }
    for changes: [String: Any] in [["iss": "https://evil.invalid"], ["aud": "other"],
                                  ["exp": authNow.timeIntervalSince1970], ["nonce": "wrong"]] {
        #expect(throws: ChatGPTAuthError.invalidIDToken) {
            try IDTokenValidator.validate(rsa.jwt(changes: changes), jwks: rsa.jwks, clientID: "oaiapp_test", nonce: "nonce", now: authNow)
        }
    }
    #expect(throws: ChatGPTAuthError.invalidIDToken) {
        try IDTokenValidator.validate(rsa.jwt(alg: "HS256"), jwks: rsa.jwks, clientID: "oaiapp_test", nonce: "nonce", now: authNow)
    }
    let other = try TestRSA()
    #expect(throws: ChatGPTAuthError.invalidIDToken) {
        try IDTokenValidator.validate(rsa.jwt(), jwks: other.jwks, clientID: "oaiapp_test", nonce: "nonce", now: authNow)
    }
}

private final class MemoryCredentials: ChatGPTCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record: ChatGPTRecord?
    init(_ record: ChatGPTRecord? = nil) { self.record = record }
    func load() -> ChatGPTRecord? { lock.withLock { record } }
    func save(_ record: ChatGPTRecord) { lock.withLock { self.record = record } }
}

private func signedRecord() -> ChatGPTRecord {
    var record = ChatGPTRecord(hostID: "urn:uuid:test")
    record.clientID = "oaiapp_test"; record.email = "test@example.com"; record.sub = "user"
    record.accessToken = "old-access"; record.refreshToken = "old-refresh"; record.idToken = "old-id"
    record.expiresAt = authNow; record.scopes = ["chatgpt.tokens.use.direct"]
    return record
}

private actor RefreshCount {
    var value = 0
    func increment() { value += 1 }
}

@Test func chatGPTTokenSourceSerializesRefreshAndPersistsRotatedCredentials() async throws {
    let rsa = try TestRSA(), data = try tokenData(idToken: rsa.jwt()), jwks = rsa.jwks
    let count = RefreshCount(), store = MemoryCredentials(signedRecord())
    let client = ChatGPTOAuthClient { request in
        if request.url?.path == "/.well-known/jwks.json" { return OAuthHTTPResponse(status: 200, data: jwks) }
        await count.increment()
        await Task.yield()
        return OAuthHTTPResponse(status: 200, data: data)
    }
    let source = ChatGPTTokenSource(store: store, client: client, now: { authNow })
    async let first = source.bearerToken()
    async let second = source.bearerToken()
    let values = try await [first, second]
    #expect(values == ["new-access", "new-access"])
    #expect(await count.value == 1)
    #expect(store.load()?.refreshToken == "rotated")
    #expect(store.load()?.expiresAt == authNow.addingTimeInterval(3600))
}

@Test func chatGPTTerminalRefreshFailureDropsTokensButKeepsRegistration() async throws {
    for code in ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"] {
        let store = MemoryCredentials(signedRecord())
        let client = ChatGPTOAuthClient { _ in
            OAuthHTTPResponse(status: 400, data: Data("{\"error\":\"\(code)\"}".utf8))
        }
        let source = ChatGPTTokenSource(store: store, client: client, now: { authNow })
        await #expect(throws: ChatGPTAuthError.signInAgain) { try await source.bearerToken() }
        #expect(store.load()?.accessToken == nil)
        #expect(store.load()?.refreshToken == nil)
        #expect(store.load()?.clientID == "oaiapp_test")
        #expect(store.load()?.hostID == "urn:uuid:test")
        await #expect(throws: ChatGPTAuthError.notSignedIn) { try await source.bearerToken() }
    }
}

@Test func chatGPTSignOutDeletesLocallyEvenWhenRevocationFailsAndReusesHost() async throws {
    for status in [200, 503] {
        let store = MemoryCredentials(signedRecord())
        let client = ChatGPTOAuthClient { _ in OAuthHTTPResponse(status: status, data: Data()) }
        let source = ChatGPTTokenSource(store: store, client: client)
        #expect(try await source.signOut() == (status == 200))
        let record = try await source.prepareRegistration()
        #expect(record.clientID == "oaiapp_test")
        #expect(record.hostID == "urn:uuid:test")
        #expect(record.accessToken == nil && record.refreshToken == nil && record.idToken == nil)
    }
    let source = ChatGPTTokenSource(store: MemoryCredentials())
    let first = try await source.prepareRegistration(), second = try await source.prepareRegistration()
    #expect(first.hostID == second.hostID)
    #expect(first.hostID.hasPrefix("urn:uuid:"))
}

@Test func chatGPTInvalidGrantDuringExchangeRequiresFreshSignIn() async throws {
    let client = ChatGPTOAuthClient { _ in OAuthHTTPResponse(status: 400, data: Data(#"{"error":"invalid_grant"}"#.utf8)) }
    await #expect(throws: ChatGPTAuthError.signInAgain) {
        try await client.signIn(code: "used-code", clientID: "oaiapp_test", attempt: attempt(), now: authNow)
    }
}

@Test func chatGPTSuccessfulSignInValidatesNonceAndPersistsIdentityFields() async throws {
    let rsa = try TestRSA(), response = try tokenData(idToken: rsa.jwt()), jwks = rsa.jwks
    let client = ChatGPTOAuthClient { request in
        OAuthHTTPResponse(status: 200, data: request.url?.path == "/.well-known/jwks.json" ? jwks : response)
    }
    let record = try await client.signIn(code: "code", clientID: "oaiapp_test", attempt: attempt(), now: authNow)
    #expect(record.isSignedIn)
    #expect(record.clientID == "oaiapp_test")
    #expect(record.email == "test@example.com")
    #expect(record.sub == "user")
    #expect(record.hostID == "urn:uuid:test")
    #expect(try JSONDecoder().decode(ChatGPTRecord.self, from: JSONEncoder().encode(record)) == record)
}

@Test func chatGPTTransientRefreshFailuresKeepCredentialsAndEarliestCanDeferRefresh() async throws {
    let store = MemoryCredentials(signedRecord())
    let client = ChatGPTOAuthClient { _ in OAuthHTTPResponse(status: 503, data: Data(#"{"error":"server_error"}"#.utf8)) }
    let source = ChatGPTTokenSource(store: store, client: client, now: { authNow })
    await #expect(throws: ChatGPTAuthError.endpoint("server_error")) { try await source.bearerToken() }
    #expect(store.load() == signedRecord())
    var deferred = signedRecord()
    deferred.expiresAt = authNow.addingTimeInterval(60)
    deferred.earliestRefreshAt = authNow.addingTimeInterval(120)
    store.save(deferred)
    #expect(try await source.bearerToken() == "old-access")
}

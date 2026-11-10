import AppKit
import Foundation
import Network
import Observation
import RecorderSummary
import Security

struct ChatGPTKeychainStore: ChatGPTCredentialStore {
    private struct StoreError: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "ChatGPTの認証情報を処理できませんでした（Keychain: \(status)）" }
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "as.ason.Kikimimi",
         kSecAttrAccount as String: "chatgpt-siwc"]
    }
    func load() throws -> ChatGPTRecord? {
        var query = query
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StoreError(status: status) }
        return try JSONDecoder().decode(ChatGPTRecord.self, from: data)
    }
    func save(_ record: ChatGPTRecord) throws {
        let data = try JSONEncoder().encode(record)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw StoreError(status: added) }
        } else if status != errSecSuccess { throw StoreError(status: status) }
    }
}

@MainActor @Observable
final class ChatGPTSignIn {
    let source = ChatGPTTokenSource(store: ChatGPTKeychainStore())
    private(set) var signedIn = false
    private(set) var email: String?
    private(set) var error: String?
    private(set) var signingOut = false
    private(set) var revision = 0
    private var operation: Task<Void, Never>?
    var waiting: Bool { operation != nil }

    func refresh() async {
        do {
            let record = try await source.status()
            signedIn = record?.isSignedIn == true
            email = record?.email
        } catch { signedIn = false; self.error = "認証情報を読み込めませんでした" }
    }

    func signIn() {
        guard operation == nil, !signingOut else { return }
        error = nil
        operation = Task {
            defer { operation = nil }
            do {
                let registration = try await source.prepareRegistration()
                let secrets = try OAuthSecrets()
                let listener = LoopbackSignIn(state: secrets.state, clientID: registration.clientID)
                defer { listener.cancel() }
                try await withTaskCancellationHandler {
                    let redirect = try await listener.start()
                    try Task.checkCancellation()
                    let attempt = try OAuthAttempt(secrets: secrets, redirectURI: redirect, registration: registration)
                    guard NSWorkspace.shared.open(attempt.authorizeURL()) else {
                        listener.cancel(); throw ChatGPTAuthError.browserUnavailable
                    }
                    let callback = try await listener.callback()
                    if case let .authorized(code, clientID) = callback {
                        try Task.checkCancellation()
                        try await source.retainIssuedClientID(clientID)
                        let record = try await ChatGPTOAuthClient().signIn(code: code, clientID: clientID, attempt: attempt)
                        try Task.checkCancellation()
                        try await source.accept(record)
                        revision += 1
                    }
                } onCancel: { listener.cancel() }
                await refresh()
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    func cancel() { operation?.cancel() }

    func signOut() async {
        guard operation == nil, !signingOut else { return }
        signingOut = true; error = nil
        defer { signingOut = false }
        do {
            let confirmed = try await source.signOut()
            revision += 1
            if !confirmed {
                error = "サインアウトしましたが、サーバー側の解除は確認できませんでした。ChatGPTの設定で確認してください"
            }
        } catch { self.error = error.localizedDescription }
        await refresh()
    }
}

/// All mutable listener/connection state is confined to queue; only immutable results cross it.
private final class LoopbackSignIn: @unchecked Sendable {
    private let queue = DispatchQueue(label: "as.ason.Kikimimi.oauth-loopback")
    private let state: String
    private let clientID: String?
    private var listener: NWListener?
    private var connection: NWConnection?
    private var startContinuation: CheckedContinuation<URL, any Error>?
    private var callbackContinuation: CheckedContinuation<OAuthCallback, any Error>?
    private var result: Result<OAuthCallback, any Error>?
    private var timeout: DispatchWorkItem?

    init(state: String, clientID: String?) { self.state = state; self.clientID = clientID }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.result {
                    switch result {
                    case .success: continuation.resume(throwing: CancellationError())
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                    return
                }
                self.startContinuation = continuation
                self.bind(preferred: true)
            }
        }
    }

    private func bind(preferred: Bool) {
        let port = preferred ? NWEndpoint.Port(rawValue: 1455)! : .any
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        do {
            let listener = try NWListener(using: parameters, on: port)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] status in
                guard let self, let listener, self.listener === listener, self.result == nil else { return }
                switch status {
                case .ready:
                    guard let port = listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback") else {
                        self.finish(.failure(ChatGPTAuthError.invalidCallback)); return
                    }
                    self.startContinuation?.resume(returning: url); self.startContinuation = nil
                    let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(ChatGPTAuthError.timedOut)) }
                    self.timeout = timeout
                    self.queue.asyncAfter(deadline: .now() + 300, execute: timeout)
                case .failed:
                    listener.cancel()
                    if preferred { self.bind(preferred: false) }
                    else { self.finish(.failure(ChatGPTAuthError.endpoint("loopback_listener"))) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.connection == nil, self.result == nil else { connection.cancel(); return }
                self.connection = connection
                connection.start(queue: self.queue)
                self.receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        } catch {
            if preferred { bind(preferred: false) }
            else { finish(.failure(ChatGPTAuthError.endpoint("loopback_listener"))) }
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, self.result == nil else { return }
            let buffer = buffer + (data ?? Data())
            if let end = buffer.range(of: Data("\r\n".utf8)) {
                do {
                    guard let line = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { throw ChatGPTAuthError.invalidCallback }
                    let callback = try OAuthAttempt.callback(requestLine: line, state: self.state, savedClientID: self.clientID)
                    let message = callback == .declined ? "サインインをキャンセルしました。" : "サインインが完了しました。Kikimimi に戻ってください。"
                    self.respond(connection, message: message, success: true)
                    self.finish(.success(callback), closeConnection: false)
                } catch {
                    self.respond(connection, message: "サインインの応答を確認できませんでした。Kikimimi に戻ってやり直してください。", success: false)
                    self.finish(.failure(error), closeConnection: false)
                }
            } else if buffer.count > 8192 || complete || error != nil {
                self.finish(.failure(ChatGPTAuthError.invalidCallback))
            } else { self.receive(connection, buffer: buffer) }
        }
    }

    private func respond(_ connection: NWConnection, message: String, success: Bool) {
        let html = "<!doctype html><html lang=\"ja\"><meta charset=\"utf-8\"><title>Kikimimi</title><p>\(message)</p></html>"
        let header = "HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((header + html).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    func callback() async throws -> OAuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.result { continuation.resume(with: result) }
                else { self.callbackContinuation = continuation }
            }
        }
    }

    func cancel() { queue.async { self.finish(.failure(CancellationError())) } }

    private func finish(_ result: Result<OAuthCallback, any Error>, closeConnection: Bool = true) {
        guard self.result == nil else { return }
        self.result = result; timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        if closeConnection { connection?.cancel() }
        connection = nil
        startContinuation?.resume(throwing: result.failure ?? ChatGPTAuthError.invalidCallback); startContinuation = nil
        callbackContinuation?.resume(with: result); callbackContinuation = nil
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let error) = self { error } else { nil } }
}

import Foundation

public protocol ChatGPTCredentialStore: Sendable {
    func load() throws -> ChatGPTRecord?
    func save(_ record: ChatGPTRecord) throws
}

public actor ChatGPTTokenSource: BearerTokenSource {
    private let store: any ChatGPTCredentialStore
    private let client: ChatGPTOAuthClient
    private let now: @Sendable () -> Date
    private var refreshTask: Task<ChatGPTRecord, any Error>?
    private var refreshID: UUID?
    private var signingOut = false
    private var revision = 0

    public init(store: any ChatGPTCredentialStore, client: ChatGPTOAuthClient = .init(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.client = client; self.now = now
    }

    public func status() throws -> ChatGPTRecord? { try store.load() }

    public func prepareRegistration() throws -> ChatGPTRecord {
        if let record = try store.load() { return record }
        let record = ChatGPTRecord()
        try store.save(record)
        return record
    }

    public func retainIssuedClientID(_ clientID: String) throws {
        var record = try prepareRegistration()
        guard clientID != "dynamic_agent_client", !clientID.isEmpty,
              record.clientID == nil || record.clientID == clientID else { throw ChatGPTAuthError.clientMismatch }
        record.clientID = clientID
        try store.save(record)
    }

    public func accept(_ record: ChatGPTRecord) throws {
        revision += 1; refreshTask?.cancel(); refreshTask = nil; refreshID = nil
        try store.save(record)
    }

    public func bearerToken() async throws -> String {
        try Task.checkCancellation()
        guard !signingOut, let record = try store.load(), record.isSignedIn, let accessToken = record.accessToken else {
            throw ChatGPTAuthError.notSignedIn
        }
        guard record.needsRefresh(now: now()) else { return accessToken }
        let currentRevision = revision
        let task: Task<ChatGPTRecord, any Error>
        if let existing = refreshTask { task = existing }
        else {
            let client = client, date = now()
            task = Task { try await client.refresh(record, now: date) }
            refreshTask = task
            refreshID = UUID()
        }
        let currentRefreshID = refreshID
        do {
            let updated = try await task.value
            guard revision == currentRevision else { throw ChatGPTAuthError.notSignedIn }
            if refreshID == currentRefreshID { try store.save(updated); refreshTask = nil; refreshID = nil }
            try Task.checkCancellation()
            return updated.accessToken!
        } catch {
            if revision == currentRevision && refreshID == currentRefreshID {
                refreshTask = nil; refreshID = nil
                if let authError = error as? ChatGPTAuthError, authError == .signInAgain {
                    var cleared = record; cleared.clearTokens()
                    revision += 1
                    try store.save(cleared)
                }
            }
            throw error
        }
    }

    /// Returns false when local sign-out succeeded but remote revocation could not be confirmed.
    public func signOut() async throws -> Bool {
        signingOut = true
        defer { signingOut = false }
        revision += 1
        let pendingRefresh = refreshTask
        refreshTask = nil; refreshID = nil
        guard var record = try store.load() else { return true }
        let currentRevision = revision
        // A refresh may already have rotated the server-side token. Revoke its replacement, not the stale token.
        if let pendingRefresh, let refreshed = try? await pendingRefresh.value { record = refreshed }
        guard revision == currentRevision else { throw ChatGPTAuthError.notSignedIn }
        var confirmed = true
        if record.refreshToken != nil {
            do { try await client.revoke(record) }
            catch { confirmed = false }
        }
        guard revision == currentRevision else { throw ChatGPTAuthError.notSignedIn }
        record.clearTokens()
        try store.save(record)
        return confirmed
    }
}

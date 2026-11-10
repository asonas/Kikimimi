import Foundation
import LocalAuthentication
import Observation
import RecorderSummary
import Security

struct SummaryAPIKey: BearerTokenSource {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "as.ason.Kikimimi", kSecAttrAccount as String: "openai-api-key"]
    }

    struct KeychainError: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "APIキーを処理できませんでした（Keychain: \(status)）" }
    }

    func exists() throws -> Bool {
        var query = query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return true
    }

    func bearerToken() async throws -> String {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw KeychainError(status: status == errSecSuccess ? errSecDecode : status)
        }
        return token
    }

    func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

@MainActor @Observable
final class SummaryCredentials {
    let source = SummaryAPIKey()
    private(set) var hasKey = false
    private(set) var error: String?

    func refresh() {
        do { hasKey = try source.exists(); error = nil }
        catch { hasKey = false; self.error = error.localizedDescription }
    }

    func save(_ key: String) {
        do { try source.save(key); refresh() }
        catch { self.error = error.localizedDescription }
    }

    func delete() {
        do { try source.delete(); refresh() }
        catch { self.error = error.localizedDescription }
    }
}

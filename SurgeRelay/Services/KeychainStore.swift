import Foundation
import Security

enum KeychainStore {
    static let defaultService = "com.allenmiao.SurgeRelay"
    static let githubTokenAccount = "github-token"

    static func loadGitHubToken() throws -> String {
        try readPassword(account: githubTokenAccount) ?? ""
    }

    static func saveGitHubToken(_ token: String) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            try deletePassword(account: githubTokenAccount)
        } else {
            try savePassword(value, account: githubTokenAccount)
        }
    }

    static func readPassword(
        account: String,
        service: String = defaultService
    ) throws -> String? {
        var query = baseQuery(account: account, service: service)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainStoreError(operation: "读取", status: status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError(operation: "解析", status: errSecDecode)
        }
        return value
    }

    static func savePassword(
        _ password: String,
        account: String,
        service: String = defaultService
    ) throws {
        let data = Data(password.utf8)
        let query = baseQuery(account: account, service: service)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError(operation: "更新", status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError(operation: "保存", status: addStatus)
        }
    }

    static func deletePassword(
        account: String,
        service: String = defaultService
    ) throws {
        let status = SecItemDelete(baseQuery(account: account, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(operation: "删除", status: status)
        }
    }

    private static func baseQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Surge Relay GitHub Token"
        ]
    }
}

struct KeychainStoreError: LocalizedError, Sendable {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "钥匙串\(operation)失败：\(message)"
    }
}

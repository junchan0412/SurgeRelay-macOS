import CryptoKit
import Foundation

enum LocalCredentialStore {
    static let githubTokenAccount = "github-token"
    static let webAccessTokenAccount = "web-management-token"
    static let defaultFileURL = PersistenceStore.configurationDirectoryURL
        .appending(path: "credentials.encrypted")
    static let defaultKeyURL = PersistenceStore.configurationDirectoryURL
        .appending(path: "credentials.key")

    private static let storageFormatVersion = 1

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

    static func loadWebAccessToken() throws -> String {
        try readPassword(account: webAccessTokenAccount) ?? ""
    }

    static func saveWebAccessToken(_ token: String) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            try deletePassword(account: webAccessTokenAccount)
        } else {
            try savePassword(value, account: webAccessTokenAccount)
        }
    }

    static func readPassword(
        account: String,
        fileURL: URL = defaultFileURL,
        keyURL: URL = defaultKeyURL
    ) throws -> String? {
        let key = try loadOrCreateKey(at: keyURL)
        guard let entries = try loadEntries(from: fileURL) else { return nil }
        guard let sealedData = entries[account] else { return nil }
        do {
            let box = try AES.GCM.SealedBox(combined: sealedData)
            let data = try AES.GCM.open(box, using: key)
            guard let value = String(data: data, encoding: .utf8) else {
                throw LocalCredentialStoreError(operation: "解析", detail: "解密内容不是有效文本。")
            }
            return value
        } catch let error as LocalCredentialStoreError {
            throw error
        } catch {
            throw LocalCredentialStoreError(operation: "读取", detail: "解密失败：\(error.localizedDescription)")
        }
    }

    static func savePassword(
        _ password: String,
        account: String,
        fileURL: URL = defaultFileURL,
        keyURL: URL = defaultKeyURL
    ) throws {
        let key = try loadOrCreateKey(at: keyURL)
        var entries = try loadEntries(from: fileURL) ?? [:]
        do {
            let box = try AES.GCM.seal(Data(password.utf8), using: key)
            entries[account] = box.combined
        } catch {
            throw LocalCredentialStoreError(operation: "保存", detail: "加密失败：\(error.localizedDescription)")
        }
        try writeEntries(entries, to: fileURL)
    }

    static func deletePassword(
        account: String,
        fileURL: URL = defaultFileURL,
        keyURL: URL = defaultKeyURL
    ) throws {
        _ = try loadOrCreateKey(at: keyURL)
        guard var entries = try loadEntries(from: fileURL) else { return }
        guard entries.removeValue(forKey: account) != nil else { return }
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
        } else {
            try writeEntries(entries, to: fileURL)
        }
    }

    static func probeAccess(
        fileURL: URL = defaultFileURL,
        keyURL: URL = defaultKeyURL
    ) -> LocalCredentialProbeResult {
        let account = "probe-\(UUID().uuidString)"
        let value = "probe-\(UUID().uuidString)"
        do {
            try savePassword(value, account: account, fileURL: fileURL, keyURL: keyURL)
            let stored = try readPassword(account: account, fileURL: fileURL, keyURL: keyURL)
            try deletePassword(account: account, fileURL: fileURL, keyURL: keyURL)
            guard stored == value else {
                return LocalCredentialProbeResult(
                    isAvailable: false,
                    message: "本地加密读写探测失败：读取值与写入值不一致。"
                )
            }
            return LocalCredentialProbeResult(isAvailable: true, message: "本地加密读写正常。")
        } catch {
            try? deletePassword(account: account, fileURL: fileURL, keyURL: keyURL)
            return LocalCredentialProbeResult(
                isAvailable: false,
                message: error.localizedDescription,
                recoverySuggestion: LocalCredentialStoreError.genericRecoverySuggestion
            )
        }
    }

    private struct CredentialStorePayload: Codable {
        var formatVersion: Int
        var entries: [String: Data]
    }

    private static func loadOrCreateKey(at url: URL) throws -> SymmetricKey {
        if let data = try? Data(contentsOf: url), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            try restrictPermissions(at: url)
        } catch {
            throw LocalCredentialStoreError(operation: "初始化", detail: "无法写入本地加密密钥：\(error.localizedDescription)")
        }
        return key
    }

    private static func loadEntries(from url: URL) throws -> [String: Data]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(CredentialStorePayload.self, from: data)
            guard payload.formatVersion == storageFormatVersion else {
                throw LocalCredentialStoreError(operation: "读取", detail: "不支持的存储版本。")
            }
            return payload.entries
        } catch let error as LocalCredentialStoreError {
            throw error
        } catch {
            throw LocalCredentialStoreError(operation: "读取", detail: "加密文件无法解析：\(error.localizedDescription)")
        }
    }

    private static func writeEntries(_ entries: [String: Data], to url: URL) throws {
        let payload = CredentialStorePayload(formatVersion: storageFormatVersion, entries: entries)
        do {
            let data = try JSONEncoder().encode(payload)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            try restrictPermissions(at: url)
        } catch let error as LocalCredentialStoreError {
            throw error
        } catch {
            throw LocalCredentialStoreError(operation: "写入", detail: error.localizedDescription)
        }
    }

    private static func restrictPermissions(at url: URL) throws {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

struct LocalCredentialProbeResult: Equatable, Sendable {
    var isAvailable: Bool
    var message: String
    var recoverySuggestion: String = ""
}

struct LocalCredentialStoreError: LocalizedError, Sendable {
    var operation: String
    var detail: String

    var errorDescription: String? {
        "本地加密存储\(operation)失败：\(detail)"
    }

    var recoverySuggestion: String? {
        Self.genericRecoverySuggestion
    }

    static let genericRecoverySuggestion = "请检查配置目录的读写权限后重试；若加密文件损坏，可在“凭据”设置中重新保存 Token。"
}

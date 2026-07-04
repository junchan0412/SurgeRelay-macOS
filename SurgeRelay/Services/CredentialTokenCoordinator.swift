import Foundation
import Security

enum CredentialTokenCoordinator {
    typealias TokenLoader = () throws -> String
    typealias TokenSaver = (String) throws -> Void
    typealias RandomByteGenerator = (Int) -> [UInt8]?

    struct GitHubTokenLoadResult: Equatable {
        var token: String
        var storageStatus: CredentialStorageStatus
        var shouldClearLegacyToken: Bool
        var statusMessage: String?
    }

    struct WebAccessTokenLoadResult: Equatable {
        var token: String
        var storageStatus: CredentialStorageStatus
        var statusMessage: String?
    }

    static func loadGitHubToken(
        migratingLegacyToken legacyToken: String,
        loadStoredToken: TokenLoader = { try KeychainStore.loadGitHubToken() },
        saveStoredToken: TokenSaver = { try KeychainStore.saveGitHubToken($0) }
    ) -> GitHubTokenLoadResult {
        let legacyToken = legacyToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let storedToken = try loadStoredToken()
            if !storedToken.isEmpty {
                return GitHubTokenLoadResult(
                    token: storedToken,
                    storageStatus: .keychain,
                    shouldClearLegacyToken: true,
                    statusMessage: legacyToken.isEmpty ? nil : "GitHub Token 已改由系统钥匙串管理"
                )
            }
            guard !legacyToken.isEmpty else {
                return GitHubTokenLoadResult(
                    token: "",
                    storageStatus: .notConfigured,
                    shouldClearLegacyToken: true
                )
            }
            try saveStoredToken(legacyToken)
            return GitHubTokenLoadResult(
                token: legacyToken,
                storageStatus: .keychain,
                shouldClearLegacyToken: true,
                statusMessage: "GitHub Token 已从同步配置迁移到系统钥匙串"
            )
        } catch {
            guard !legacyToken.isEmpty else {
                return GitHubTokenLoadResult(
                    token: "",
                    storageStatus: .unavailable,
                    shouldClearLegacyToken: false
                )
            }
            return GitHubTokenLoadResult(
                token: legacyToken,
                storageStatus: .legacyConfigurationFallback,
                shouldClearLegacyToken: false,
                statusMessage: "无法访问系统钥匙串，暂时沿用旧同步配置中的 GitHub Token"
            )
        }
    }

    static func loadWebAccessToken(
        loadStoredToken: TokenLoader = { try KeychainStore.loadWebAccessToken() },
        saveStoredToken: TokenSaver = { try KeychainStore.saveWebAccessToken($0) },
        generateToken: () -> String = { generateWebAccessToken() }
    ) -> WebAccessTokenLoadResult {
        do {
            let storedToken = try loadStoredToken().trimmingCharacters(in: .whitespacesAndNewlines)
            if !storedToken.isEmpty {
                return WebAccessTokenLoadResult(token: storedToken, storageStatus: .keychain)
            }
            let token = generateToken()
            try saveStoredToken(token)
            return WebAccessTokenLoadResult(token: token, storageStatus: .keychain)
        } catch {
            return WebAccessTokenLoadResult(
                token: generateToken(),
                storageStatus: .memoryOnly,
                statusMessage: "无法访问系统钥匙串，Web 管理访问令牌仅在本次运行中有效"
            )
        }
    }

    static func generateWebAccessToken(
        randomBytes: RandomByteGenerator = secureRandomBytes
    ) -> String {
        if let bytes = randomBytes(32), bytes.count == 32 {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func secureRandomBytes(count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        return status == errSecSuccess ? bytes : nil
    }
}

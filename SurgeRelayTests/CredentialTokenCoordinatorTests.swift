import Foundation
import XCTest
@testable import SurgeRelay

final class CredentialTokenCoordinatorTests: XCTestCase {
    private enum CredentialTestError: Error {
        case unavailable
    }

    func testCredentialTokenCoordinatorUsesStoredGitHubTokenAndClearsLegacy() {
        var savedTokens: [String] = []

        let result = CredentialTokenCoordinator.loadGitHubToken(
            migratingLegacyToken: " ghp_legacy ",
            loadStoredToken: { "ghp_stored" },
            saveStoredToken: { savedTokens.append($0) }
        )

        XCTAssertEqual(result.token, "ghp_stored")
        XCTAssertEqual(result.storageStatus, .keychain)
        XCTAssertTrue(result.shouldClearLegacyToken)
        XCTAssertEqual(result.statusMessage, "GitHub Token 已改由系统钥匙串管理")
        XCTAssertTrue(savedTokens.isEmpty)
    }

    func testCredentialTokenCoordinatorMigratesLegacyGitHubToken() {
        var savedToken: String?

        let result = CredentialTokenCoordinator.loadGitHubToken(
            migratingLegacyToken: " ghp_legacy\n",
            loadStoredToken: { "" },
            saveStoredToken: { savedToken = $0 }
        )

        XCTAssertEqual(result.token, "ghp_legacy")
        XCTAssertEqual(result.storageStatus, .keychain)
        XCTAssertTrue(result.shouldClearLegacyToken)
        XCTAssertEqual(result.statusMessage, "GitHub Token 已从同步配置迁移到系统钥匙串")
        XCTAssertEqual(savedToken, "ghp_legacy")
    }

    func testCredentialTokenCoordinatorReportsEmptyGitHubTokenConfiguration() {
        let result = CredentialTokenCoordinator.loadGitHubToken(
            migratingLegacyToken: " \n",
            loadStoredToken: { "" },
            saveStoredToken: { _ in XCTFail("Empty legacy token should not be saved") }
        )

        XCTAssertEqual(result.token, "")
        XCTAssertEqual(result.storageStatus, .notConfigured)
        XCTAssertTrue(result.shouldClearLegacyToken)
        XCTAssertNil(result.statusMessage)
    }

    func testCredentialTokenCoordinatorFallsBackToLegacyGitHubTokenWhenKeychainFails() {
        let result = CredentialTokenCoordinator.loadGitHubToken(
            migratingLegacyToken: " ghp_legacy ",
            loadStoredToken: { throw CredentialTestError.unavailable },
            saveStoredToken: { _ in XCTFail("Save should not run when loading throws") }
        )

        XCTAssertEqual(result.token, "ghp_legacy")
        XCTAssertEqual(result.storageStatus, .legacyConfigurationFallback)
        XCTAssertFalse(result.shouldClearLegacyToken)
        XCTAssertEqual(result.statusMessage, "无法访问系统钥匙串，暂时沿用旧同步配置中的 GitHub Token")
    }

    func testCredentialTokenCoordinatorMarksGitHubTokenUnavailableWithoutLegacyFallback() {
        let result = CredentialTokenCoordinator.loadGitHubToken(
            migratingLegacyToken: "",
            loadStoredToken: { throw CredentialTestError.unavailable },
            saveStoredToken: { _ in XCTFail("Save should not run without a legacy token") }
        )

        XCTAssertEqual(result.token, "")
        XCTAssertEqual(result.storageStatus, .unavailable)
        XCTAssertFalse(result.shouldClearLegacyToken)
        XCTAssertNil(result.statusMessage)
    }

    func testCredentialTokenCoordinatorLoadsStoredWebAccessToken() {
        let result = CredentialTokenCoordinator.loadWebAccessToken(
            loadStoredToken: { " web-token\n" },
            saveStoredToken: { _ in XCTFail("Existing Web token should not be saved again") },
            generateToken: {
                XCTFail("Existing Web token should not generate a replacement")
                return "unused"
            }
        )

        XCTAssertEqual(result.token, "web-token")
        XCTAssertEqual(result.storageStatus, .keychain)
        XCTAssertNil(result.statusMessage)
    }

    func testCredentialTokenCoordinatorGeneratesAndStoresWebAccessTokenWhenMissing() {
        var savedToken: String?

        let result = CredentialTokenCoordinator.loadWebAccessToken(
            loadStoredToken: { " " },
            saveStoredToken: { savedToken = $0 },
            generateToken: { "generated-web-token" }
        )

        XCTAssertEqual(result.token, "generated-web-token")
        XCTAssertEqual(result.storageStatus, .keychain)
        XCTAssertNil(result.statusMessage)
        XCTAssertEqual(savedToken, "generated-web-token")
    }

    func testCredentialTokenCoordinatorUsesMemoryOnlyWebTokenWhenSaveFails() {
        var generatedTokens = ["token-for-failed-save", "memory-token"]
        var attemptedSave: String?

        let result = CredentialTokenCoordinator.loadWebAccessToken(
            loadStoredToken: { "" },
            saveStoredToken: {
                attemptedSave = $0
                throw CredentialTestError.unavailable
            },
            generateToken: { generatedTokens.removeFirst() }
        )

        XCTAssertEqual(attemptedSave, "token-for-failed-save")
        XCTAssertEqual(result.token, "memory-token")
        XCTAssertEqual(result.storageStatus, .memoryOnly)
        XCTAssertEqual(result.statusMessage, "无法访问系统钥匙串，Web 管理访问令牌仅在本次运行中有效")
        XCTAssertTrue(generatedTokens.isEmpty)
    }

    func testCredentialTokenCoordinatorGeneratesHexWebAccessTokenFromRandomBytes() {
        let token = CredentialTokenCoordinator.generateWebAccessToken(
            randomBytes: { count in (0..<count).map { UInt8($0) } }
        )

        XCTAssertEqual(
            token,
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        )
    }

    func testCredentialTokenCoordinatorFallsBackToUUIDWebAccessToken() {
        let token = CredentialTokenCoordinator.generateWebAccessToken(randomBytes: { _ in nil })

        XCTAssertEqual(token.count, 64)
        XCTAssertFalse(token.contains("-"))
    }
}

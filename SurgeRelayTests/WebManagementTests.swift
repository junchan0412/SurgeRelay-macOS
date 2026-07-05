import XCTest
@testable import SurgeRelay

final class WebManagementTests: XCTestCase {
    func testWebIconContentTypeDetectionOnlyAcceptsRecognizedImages() {
        XCTAssertEqual(WebManagementAssets.imageContentType(Data([0x89, 0x50, 0x4E, 0x47, 0x0D])), "image/png")
        XCTAssertEqual(WebManagementAssets.imageContentType(Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(WebManagementAssets.imageContentType(Data("GIF89a".utf8)), "image/gif")
        XCTAssertEqual(
            WebManagementAssets.imageContentType(Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])),
            "image/webp"
        )
        XCTAssertEqual(WebManagementAssets.imageContentType(Data("<?xml version=\"1.0\"?><svg></svg>".utf8)), "image/svg+xml")
        XCTAssertNil(WebManagementAssets.imageContentType(Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45])))
        XCTAssertNil(WebManagementAssets.imageContentType(Data("not an image".utf8)))
    }

    func testWebContentSecurityPolicyMatchesCustomIconValidation() {
        let policy = WebManagementAssets.webContentSecurityPolicy

        XCTAssertTrue(policy.contains("img-src"))
        XCTAssertTrue(policy.contains("http:"))
        XCTAssertTrue(policy.contains("https:"))
        XCTAssertTrue(policy.contains("data:"))
    }

    func testWebServerRuntimeStateHasUserFacingAndDiagnosticValues() {
        XCTAssertEqual(WebServerRuntimeState.running.title, "运行中")
        XCTAssertEqual(WebServerRuntimeState.running.diagnosticValue, "running")
        XCTAssertEqual(WebServerRuntimeState.running.systemImage, "checkmark.circle.fill")

        let failed = WebServerRuntimeState.failed("端口已被占用")
        XCTAssertEqual(failed.title, "启动失败")
        XCTAssertEqual(failed.diagnosticValue, "failed: 端口已被占用")
        XCTAssertEqual(failed.failureMessage, "端口已被占用")
    }

    func testWebManagementDisplayURLOmitsAccessToken() throws {
        let accessURL = try XCTUnwrap(WebManagementURLFactory.url(
            host: "relay.local",
            port: 8787,
            accessToken: "secret-token",
            includingToken: true
        ))
        let displayURL = try XCTUnwrap(WebManagementURLFactory.url(
            host: "relay.local",
            port: 8787,
            accessToken: "secret-token",
            includingToken: false
        ))

        XCTAssertEqual(accessURL.absoluteString, "http://relay.local:8787/?token=secret-token")
        XCTAssertEqual(displayURL.absoluteString, "http://relay.local:8787/")
        XCTAssertFalse(displayURL.absoluteString.contains("secret-token"))
    }

    func testAppSettingsDecodesWebManagementDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.combinedModuleEnabled)
        XCTAssertFalse(settings.webServerEnabled)
        XCTAssertEqual(settings.webServerPort, 8787)
        XCTAssertFalse(settings.webServerAllowRemoteAccess)
    }
}

import XCTest
@testable import SurgeRelay

final class GitHubReleaseTests: XCTestCase {
    func testGitHubRawURL() throws {
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        settings.branch = "main"
        settings.directory = "modules"
        XCTAssertEqual(
            try XCTUnwrap(settings.rawURL(for: "YouTube.sgmodule")).absoluteString,
            "https://raw.githubusercontent.com/someone/relay/main/modules/YouTube.sgmodule"
        )
        XCTAssertEqual(
            try XCTUnwrap(settings.rawURL(for: "Ads/YouTube.sgmodule")).absoluteString,
            "https://raw.githubusercontent.com/someone/relay/main/modules/Ads/YouTube.sgmodule"
        )
    }

    func testGitHubSettingsValidatesOwnerRepositoryAndBranch() {
        var settings = GitHubSettings()
        settings.owner = "-bad"
        XCTAssertFalse(settings.isConfigured)
        XCTAssertNotNil(settings.validationMessage)

        settings.owner = "someone"
        settings.repository = "bad/repo"
        XCTAssertFalse(settings.isConfigured)

        settings.repository = "relay"
        settings.branch = "feature//bad"
        XCTAssertFalse(settings.isConfigured)

        settings.branch = "feature/security-hardening"
        XCTAssertTrue(settings.isConfigured)
        XCTAssertNil(settings.validationMessage)
    }

    func testGitHubClientTestsRepositoryVisibilityWithAPIHeaders() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        GitHubMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/repos/someone/relay")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "SurgeRelay/1.0")
            return (200, Data(#"{"private":true}"#.utf8))
        }
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"

        let isPrivate = try await GitHubClient(session: session).test(settings: settings, token: "token")

        XCTAssertTrue(isPrivate)
        XCTAssertEqual(GitHubMockURLProtocol.requestedPaths, ["GET /repos/someone/relay"])
    }

    func testGitHubClientListsNestedModuleDirectoriesFromTree() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        GitHubMockURLProtocol.handler = { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/repos/someone/relay/git/ref/heads/main"):
                return (200, Data(#"{"object":{"sha":"commit1"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/commits/commit1"):
                return (200, Data(#"{"sha":"commit1","tree":{"sha":"tree1"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/trees/tree1"):
                return (200, Data("""
                {
                  "tree": [
                    {"path": "modules/Ads", "type": "tree", "sha": "tree-ads"},
                    {"path": "modules/Ads/Video", "type": "tree", "sha": "tree-video"},
                    {"path": "modules/Ads/Video/YouTube.sgmodule", "type": "blob", "sha": "blob-video"},
                    {"path": "modules/Root.sgmodule", "type": "blob", "sha": "blob-root"},
                    {"path": "modules/assets/Generated/script.js", "type": "blob", "sha": "blob-asset"},
                    {"path": "other/Ignored", "type": "tree", "sha": "tree-ignored"}
                  ],
                  "truncated": false
                }
                """.utf8))
            default:
                return (404, Data(#"{"message":"not found"}"#.utf8))
            }
        }
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        settings.branch = "main"
        settings.directory = "modules"

        let folders = try await GitHubClient(session: session).listDirectories(settings: settings, token: "token")

        XCTAssertEqual(folders, ["Ads", "Ads/Video"])
        XCTAssertTrue(GitHubMockURLProtocol.requestedPaths.contains("GET /repos/someone/relay/git/trees/tree1?recursive=1"))
    }

    func testPublicRepositoryUsesGitHubRawWithoutCloudflare() throws {
        var settings = GitHubSettings()
        settings.repositoryIsPrivate = false
        settings.publicBaseURL = "https://unused.example.workers.dev"
        XCTAssertEqual(
            try XCTUnwrap(settings.publicURL(for: "Demo.sgmodule")).host,
            "raw.githubusercontent.com"
        )
    }

    func testReleaseUpdateChannelOpensLatestGitHubRelease() throws {
        let url = ReleaseUpdateChannel.latestReleaseURL
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/junchan0412/SurgeRelay-macOS/releases/latest")
    }

    func testReleaseVersionComparisonHandlesMultiDigitComponents() {
        XCTAssertEqual(
            ReleaseUpdateAvailability.compare(current: "1.2.11", latest: "v1.2.12"),
            .newerAvailable
        )
        XCTAssertEqual(
            ReleaseUpdateAvailability.compare(current: "1.2.11", latest: "1.2.11"),
            .upToDate
        )
        XCTAssertEqual(
            ReleaseUpdateAvailability.compare(current: "1.2.11", latest: "1.2.10"),
            .olderThanCurrent
        )
        XCTAssertFalse(ReleaseVersion("1.2.10") < ReleaseVersion("1.2.9"))
    }

    func testGitHubReleaseClientFetchesLatestReleaseAssets() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        GitHubMockURLProtocol.handler = { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/repos/junchan0412/SurgeRelay-macOS/releases/latest"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
                return (200, Data("""
                {
                  "tag_name": "v1.2.12",
                  "name": "Surge Relay 1.2.12",
                  "html_url": "https://github.com/junchan0412/SurgeRelay-macOS/releases/tag/v1.2.12",
                  "published_at": "2026-07-02T10:00:00Z",
                  "body": "Release notes",
                  "assets": [
                    {
                      "name": "Surge-Relay-1.2.12.app.zip",
                      "browser_download_url": "https://example.com/Surge-Relay-1.2.12.app.zip",
                      "size": 7000000,
                      "digest": "sha256:appzipdigest"
                    },
                    {
                      "name": "Surge-Relay-1.2.12.app.zip.sha256",
                      "browser_download_url": "https://example.com/Surge-Relay-1.2.12.app.zip.sha256",
                      "size": 93
                    },
                    {
                      "name": "Surge-Relay-1.2.12.pkg",
                      "browser_download_url": "https://example.com/Surge-Relay-1.2.12.pkg",
                      "size": 7100000,
                      "digest": "sha256:pkgdigest"
                    },
                    {
                      "name": "Surge-Relay-1.2.12.pkg.sha256",
                      "browser_download_url": "https://example.com/Surge-Relay-1.2.12.pkg.sha256",
                      "size": 89
                    }
                  ]
                }
                """.utf8))
            case ("GET", "/Surge-Relay-1.2.12.app.zip.sha256"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/plain")
                return (200, Data("appzipdigest  Surge-Relay-1.2.12.app.zip\n".utf8))
            case ("GET", "/Surge-Relay-1.2.12.pkg.sha256"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/plain")
                return (200, Data("pkgdigest  Surge-Relay-1.2.12.pkg\n".utf8))
            default:
                return (404, Data(#"{"message":"not found"}"#.utf8))
            }
        }

        let release = try await GitHubReleaseClient(session: session).latestRelease()

        XCTAssertEqual(release.version, "1.2.12")
        XCTAssertEqual(release.packageAsset?.name, "Surge-Relay-1.2.12.pkg")
        XCTAssertEqual(release.packageAsset?.digest, "sha256:pkgdigest")
        XCTAssertEqual(
            release.packageAsset.flatMap { release.checksumAsset(for: $0)?.name },
            "Surge-Relay-1.2.12.pkg.sha256"
        )
        XCTAssertEqual(release.packageAsset.map { release.checksumValidation(for: $0).status }, .matched)
        XCTAssertEqual(release.appZipAsset?.name, "Surge-Relay-1.2.12.app.zip")
        XCTAssertEqual(release.appZipAsset?.digestDisplay, "sha256:appzipdigest")
        XCTAssertEqual(
            release.appZipAsset.flatMap { release.checksumAsset(for: $0)?.name },
            "Surge-Relay-1.2.12.app.zip.sha256"
        )
        XCTAssertEqual(release.appZipAsset.map { release.checksumValidation(for: $0).status }, .matched)
        XCTAssertEqual(release.installableAssets.map(\.name), [
            "Surge-Relay-1.2.12.pkg",
            "Surge-Relay-1.2.12.app.zip"
        ])
        XCTAssertEqual(release.notesPreview, "Release notes")
        XCTAssertTrue(GitHubMockURLProtocol.requestedPaths.contains(
            "GET /repos/junchan0412/SurgeRelay-macOS/releases/latest"
        ))
        XCTAssertTrue(GitHubMockURLProtocol.requestedPaths.contains("GET /Surge-Relay-1.2.12.app.zip.sha256"))
        XCTAssertTrue(GitHubMockURLProtocol.requestedPaths.contains("GET /Surge-Relay-1.2.12.pkg.sha256"))
    }

    func testGitHubReleaseClientFlagsChecksumMismatch() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        GitHubMockURLProtocol.handler = { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/repos/junchan0412/SurgeRelay-macOS/releases/latest"):
                return (200, Data("""
                {
                  "tag_name": "v1.2.13",
                  "name": "Surge Relay 1.2.13",
                  "html_url": "https://github.com/junchan0412/SurgeRelay-macOS/releases/tag/v1.2.13",
                  "published_at": "2026-07-02T10:00:00Z",
                  "body": "",
                  "assets": [
                    {
                      "name": "Surge-Relay-1.2.13.app.zip",
                      "browser_download_url": "https://example.com/Surge-Relay-1.2.13.app.zip",
                      "size": 7000000,
                      "digest": "sha256:expectedhash"
                    },
                    {
                      "name": "Surge-Relay-1.2.13.app.zip.sha256",
                      "browser_download_url": "https://example.com/Surge-Relay-1.2.13.app.zip.sha256",
                      "size": 93
                    }
                  ]
                }
                """.utf8))
            case ("GET", "/Surge-Relay-1.2.13.app.zip.sha256"):
                return (200, Data("differenthash  Surge-Relay-1.2.13.app.zip\n".utf8))
            default:
                return (404, Data(#"{"message":"not found"}"#.utf8))
            }
        }

        let release = try await GitHubReleaseClient(session: session).latestRelease()
        let appZip = try XCTUnwrap(release.appZipAsset)
        let validation = release.checksumValidation(for: appZip)

        XCTAssertEqual(validation.status, .mismatched)
        XCTAssertEqual(validation.digestHash, "expectedhash")
        XCTAssertEqual(validation.checksumHash, "differenthash")
    }

    func testGitHubReleaseInstallGuidancePrefersPackageForUpdates() throws {
        let release = GitHubRelease(
            tagName: "v1.2.22",
            name: "Surge Relay 1.2.22",
            htmlURL: try XCTUnwrap(URL(string: "https://github.com/junchan0412/SurgeRelay-macOS/releases/tag/v1.2.22")),
            publishedAt: Date(timeIntervalSince1970: 1_800),
            body: "",
            assets: [
                GitHubReleaseAsset(
                    name: "Surge-Relay-1.2.22.pkg",
                    downloadURL: try XCTUnwrap(URL(string: "https://example.com/Surge-Relay-1.2.22.pkg")),
                    size: 7_100_000,
                    digest: "sha256:pkgdigest"
                ),
                GitHubReleaseAsset(
                    name: "Surge-Relay-1.2.22.app.zip",
                    downloadURL: try XCTUnwrap(URL(string: "https://example.com/Surge-Relay-1.2.22.app.zip")),
                    size: 7_000_000,
                    digest: "sha256:appzipdigest"
                )
            ]
        )

        let guidance = release.installGuidance

        XCTAssertFalse(guidance.updateNeedsAttention)
        XCTAssertEqual(guidance.updateSystemImage, "shippingbox")
        XCTAssertTrue(guidance.updateRecommendation.contains("Sparkle"))
        XCTAssertTrue(guidance.updateRecommendation.contains("pkg"))
        XCTAssertTrue(guidance.firstInstallRecommendation.contains("app.zip"))
        XCTAssertTrue(guidance.trustNotice.contains("固定自签名证书"))
        XCTAssertTrue(guidance.trustNotice.contains("EdDSA"))
    }

    func testGitHubReleaseInstallGuidanceWarnsWhenPackageIsMissing() throws {
        let release = GitHubRelease(
            tagName: "v1.2.22",
            name: "Surge Relay 1.2.22",
            htmlURL: try XCTUnwrap(URL(string: "https://github.com/junchan0412/SurgeRelay-macOS/releases/tag/v1.2.22")),
            publishedAt: Date(timeIntervalSince1970: 1_800),
            body: "",
            assets: [
                GitHubReleaseAsset(
                    name: "Surge-Relay-1.2.22.app.zip",
                    downloadURL: try XCTUnwrap(URL(string: "https://example.com/Surge-Relay-1.2.22.app.zip")),
                    size: 7_000_000,
                    digest: "sha256:appzipdigest"
                )
            ]
        )

        let guidance = release.installGuidance

        XCTAssertTrue(guidance.updateNeedsAttention)
        XCTAssertEqual(guidance.updateSystemImage, "exclamationmark.triangle.fill")
        XCTAssertTrue(guidance.updateRecommendation.contains("缺少 pkg"))
        XCTAssertTrue(guidance.updateRecommendation.contains("Sparkle"))
    }

    func testPrivateRepositoryRequiresCloudflareAndUsesItWhenConfigured() throws {
        var settings = GitHubSettings()
        settings.repositoryIsPrivate = true
        XCTAssertNil(settings.publicURL(for: "Demo.sgmodule"))
        settings.publicBaseURL = "https://surge-relay.example.workers.dev/"
        XCTAssertEqual(
            try XCTUnwrap(settings.publicURL(for: "assets/demo/script.js")).absoluteString,
            "https://surge-relay.example.workers.dev/assets/demo/script.js"
        )
    }
}

import XCTest
@testable import SurgeRelay

final class GitHubPublishTests: XCTestCase {
    func testGitHubPublishSnapshotBuildsCommitURLAndFileSummary() throws {
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        let commit = "abcdef1234567890"
        let entry = UpdateHistoryEntry(
            date: Date(timeIntervalSince1970: 3_600),
            moduleName: "GitHub",
            outcome: .published,
            duration: 0,
            message: "原子提交 abcdef12：上传/更新 2 个，删除 1 个",
            publishedFiles: ["Demo.sgmodule", "Folder/Tool.sgmodule"],
            deletedFiles: ["Old.sgmodule"],
            commitSHA: commit
        )

        let snapshot = try XCTUnwrap(GitHubPublishSnapshot.latest(in: [entry], settings: settings))

        XCTAssertEqual(snapshot.commitSHA, commit)
        XCTAssertEqual(snapshot.commitDisplay, "abcdef12")
        XCTAssertEqual(snapshot.commitURL, "https://github.com/someone/relay/commit/\(commit)")
        XCTAssertEqual(snapshot.changedFileCount, 3)
        XCTAssertEqual(snapshot.fileSummary, "2 个上传/更新 · 1 个删除")
        XCTAssertEqual(snapshot.publishedFiles, ["Demo.sgmodule", "Folder/Tool.sgmodule"])
        XCTAssertEqual(snapshot.deletedFiles, ["Old.sgmodule"])
    }

    func testGitBlobHashMatchesGitHubContentSHA() {
        XCTAssertEqual(Data("hello\n".utf8).gitBlobSHA1, "ce013625030ba8dba906f756967f9e9ca394464a")
    }

    func testGitHubRepositoryPathNormalizesNestedModuleRoot() {
        var settings = GitHubSettings()
        settings.directory = "/surge\\modules/"

        XCTAssertEqual(GitHubRepositoryPath.repositoryDirectory(settings: settings), "surge/modules")
        XCTAssertEqual(
            GitHubRepositoryPath.repositoryPath(for: "Ads/You Tube.sgmodule", settings: settings),
            "surge/modules/Ads/You Tube.sgmodule"
        )
        XCTAssertEqual(
            GitHubRepositoryPath.encodedRepositoryPath(for: "Ads/You Tube.sgmodule", settings: settings),
            "surge/modules/Ads/You%20Tube.sgmodule"
        )

        settings.directory = ""
        XCTAssertEqual(
            GitHubRepositoryPath.repositoryPath(for: "Ads/You Tube.sgmodule", settings: settings),
            "Ads/You Tube.sgmodule"
        )
    }

    func testGitHubRepositoryPathListsOutputFoldersRelativeToModuleRoot() {
        var settings = GitHubSettings()
        settings.directory = "surge/modules"
        let tree = [
            GitHubAPI.TreeItem(path: "surge/modules/Ads", type: "tree", sha: "tree-ads"),
            GitHubAPI.TreeItem(path: "surge/modules/Ads/Video", type: "tree", sha: "tree-video"),
            GitHubAPI.TreeItem(path: "surge/modules/Ads/Video/YouTube.sgmodule", type: "blob", sha: "blob-video"),
            GitHubAPI.TreeItem(path: "surge/modules/Root.sgmodule", type: "blob", sha: "blob-root"),
            GitHubAPI.TreeItem(path: "surge/modules/assets/Generated/script.js", type: "blob", sha: "blob-asset"),
            GitHubAPI.TreeItem(path: "other/Ignored", type: "tree", sha: "tree-ignored")
        ]

        XCTAssertEqual(
            GitHubRepositoryPath.moduleDirectories(from: tree, settings: settings),
            ["Ads", "Ads/Video"]
        )
    }

    func testGitHubPublishDiffsAgainstRecursiveTree() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        let sameSHA = Data("same".utf8).gitBlobSHA1
        let oldSHA = Data("old".utf8).gitBlobSHA1
        GitHubMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/repos/someone/relay/git/ref/heads/main"):
                return (200, Data(#"{"object":{"sha":"commit1"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/commits/commit1"):
                return (200, Data(#"{"sha":"commit1","tree":{"sha":"tree1"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/trees/tree1"):
                return (200, Data("""
                {
                  "tree": [
                    {"path": "modules/Same.sgmodule", "type": "blob", "sha": "\(sameSHA)"},
                    {"path": "modules/Changed.sgmodule", "type": "blob", "sha": "\(oldSHA)"},
                    {"path": "modules/Stale.sgmodule", "type": "blob", "sha": "\(oldSHA)"}
                  ],
                  "truncated": false
                }
                """.utf8))
            case ("POST", "/repos/someone/relay/git/blobs"):
                return (200, Data(#"{"sha":"new-blob"}"#.utf8))
            case ("POST", "/repos/someone/relay/git/trees"):
                return (200, Data(#"{"sha":"tree2"}"#.utf8))
            case ("POST", "/repos/someone/relay/git/commits"):
                return (200, Data(#"{"sha":"commit2","tree":{"sha":"tree2"}}"#.utf8))
            case ("PATCH", "/repos/someone/relay/git/refs/heads/main"):
                return (200, Data(#"{"object":{"sha":"commit2"}}"#.utf8))
            default:
                return (404, Data(#"{"message":"not found"}"#.utf8))
            }
        }
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        settings.branch = "main"
        settings.directory = "modules"

        let report = try await GitHubClient(session: session).publish(
            files: [
                PublishFile(name: "Same.sgmodule", data: Data("same".utf8)),
                PublishFile(name: "Changed.sgmodule", data: Data("new".utf8))
            ],
            deleting: ["Stale.sgmodule"],
            settings: settings,
            token: "token"
        )

        XCTAssertEqual(report.publishedFiles, ["Changed.sgmodule"])
        XCTAssertEqual(report.deletedFiles, ["Stale.sgmodule"])
        XCTAssertEqual(report.commitSHA, "commit2")
        XCTAssertFalse(GitHubMockURLProtocol.requestedPaths.contains { $0.contains("/contents/") })
        XCTAssertEqual(
            GitHubMockURLProtocol.requestedPaths.filter { $0 == "POST /repos/someone/relay/git/blobs" }.count,
            1
        )
    }

    func testGitHubPreviewPublishDiffsWithoutWriting() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        let sameSHA = Data("same".utf8).gitBlobSHA1
        let oldSHA = Data("old".utf8).gitBlobSHA1
        GitHubMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/repos/someone/relay/git/ref/heads/main"):
                return (200, Data(#"{"object":{"sha":"commit1"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/commits/commit1"):
                return (200, Data(#"{"sha":"commit1","tree":{"sha":"tree1"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/trees/tree1"):
                return (200, Data("""
                {
                  "tree": [
                    {"path": "modules/Same.sgmodule", "type": "blob", "sha": "\(sameSHA)"},
                    {"path": "modules/Changed.sgmodule", "type": "blob", "sha": "\(oldSHA)"},
                    {"path": "modules/Stale.sgmodule", "type": "blob", "sha": "\(oldSHA)"}
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

        let report = try await GitHubClient(session: session).previewPublish(
            files: [
                PublishFile(name: "Same.sgmodule", data: Data("same".utf8)),
                PublishFile(name: "Changed.sgmodule", data: Data("new".utf8))
            ],
            deleting: ["Stale.sgmodule"],
            settings: settings,
            token: "token"
        )

        XCTAssertEqual(report.publishedFiles, ["Changed.sgmodule"])
        XCTAssertEqual(report.deletedFiles, ["Stale.sgmodule"])
        XCTAssertFalse(GitHubMockURLProtocol.requestedPaths.contains { $0.hasPrefix("POST ") || $0.hasPrefix("PATCH ") })
    }

    func testGitHubPublishRejectsDuplicateRepositoryPathsBeforeNetworkWrite() async throws {
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        settings.branch = "main"
        settings.directory = "modules"

        do {
            _ = try await GitHubClient().previewPublish(
                files: [
                    PublishFile(name: "Folder/Demo.sgmodule", data: Data("one".utf8)),
                    PublishFile(name: "Folder/Demo.sgmodule", data: Data("two".utf8))
                ],
                settings: settings,
                token: "token"
            )
            XCTFail("不应允许重复 GitHub 发布路径")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("重复路径"))
        }
    }

    func testGitHubPublishRetriesOnceWhenReferenceMoves() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        var referenceReads = 0
        var patchAttempts = 0
        GitHubMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/repos/someone/relay/git/ref/heads/main"):
                referenceReads += 1
                let commit = referenceReads == 1 ? "commit1" : "commit2"
                return (200, Data(#"{"object":{"sha":"\#(commit)"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/commits/commit1"):
                return (200, Data(#"{"sha":"commit1","tree":{"sha":"tree1"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/commits/commit2"):
                return (200, Data(#"{"sha":"commit2","tree":{"sha":"tree2"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/trees/tree1"),
                 ("GET", "/repos/someone/relay/git/trees/tree2"):
                return (200, Data(#"{"tree":[],"truncated":false}"#.utf8))
            case ("POST", "/repos/someone/relay/git/blobs"):
                return (200, Data(#"{"sha":"new-blob"}"#.utf8))
            case ("POST", "/repos/someone/relay/git/trees"):
                return (200, Data(#"{"sha":"new-tree"}"#.utf8))
            case ("POST", "/repos/someone/relay/git/commits"):
                let commit = patchAttempts == 0 ? "new-commit1" : "new-commit2"
                return (200, Data(#"{"sha":"\#(commit)","tree":{"sha":"new-tree"}}"#.utf8))
            case ("PATCH", "/repos/someone/relay/git/refs/heads/main"):
                patchAttempts += 1
                if patchAttempts == 1 {
                    return (422, Data(#"{"message":"Reference update failed"}"#.utf8))
                }
                return (200, Data(#"{"object":{"sha":"new-commit2"}}"#.utf8))
            default:
                return (404, Data(#"{"message":"not found"}"#.utf8))
            }
        }
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        settings.branch = "main"
        settings.directory = "modules"

        let report = try await GitHubClient(session: session).publish(
            files: [PublishFile(name: "Changed.sgmodule", data: Data("new".utf8))],
            settings: settings,
            token: "token"
        )

        XCTAssertTrue(report.retriedAfterConflict)
        XCTAssertEqual(report.publishedFiles, ["Changed.sgmodule"])
        XCTAssertEqual(report.commitSHA, "new-commit2")
        XCTAssertEqual(patchAttempts, 2)
        XCTAssertEqual(
            GitHubMockURLProtocol.requestedPaths.filter { $0 == "GET /repos/someone/relay/git/ref/heads/main" }.count,
            2
        )
    }
}

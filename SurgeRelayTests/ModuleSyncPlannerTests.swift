import XCTest
@testable import SurgeRelay

final class ModuleSyncPlannerTests: XCTestCase {
    func testMatchingContentsDoNotConflict() {
        let data = Data("same".utf8)
        let snapshot = GitHubClient.FileSnapshot(
            path: "A.sgmodule",
            data: data,
            contentHash: data.sha256String,
            updatedAt: Date(timeIntervalSince1970: 20),
            commitSHA: "commit"
        )
        XCTAssertNil(ModuleSyncPlanner.conflict(
            localData: data,
            localUpdatedAt: Date(timeIntervalSince1970: 10),
            github: snapshot
        ))
    }

    func testDifferentContentsIncludeBothUpdateTimes() {
        let local = Data("local".utf8)
        let remote = Data("remote".utf8)
        let snapshot = GitHubClient.FileSnapshot(
            path: "A.sgmodule",
            data: remote,
            contentHash: remote.sha256String,
            updatedAt: Date(timeIntervalSince1970: 20),
            commitSHA: "commit"
        )
        let conflict = ModuleSyncPlanner.conflict(
            localData: local,
            localUpdatedAt: Date(timeIntervalSince1970: 10),
            github: snapshot
        )
        XCTAssertEqual(conflict?.localHash, local.sha256String)
        XCTAssertEqual(conflict?.githubHash, remote.sha256String)
        XCTAssertEqual(conflict?.localUpdatedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(conflict?.githubUpdatedAt, Date(timeIntervalSince1970: 20))
    }
}

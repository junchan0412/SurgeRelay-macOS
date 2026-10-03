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
    func testCommonBaselineClassifiesEveryDirectionWithoutInferringFromTime() {
        XCTAssertEqual(ModuleSyncPlanner.state(localHash: "same", githubHash: "same", baseHash: nil), .same)
        XCTAssertEqual(ModuleSyncPlanner.state(localHash: "new", githubHash: "base", baseHash: "base"), .localAhead)
        XCTAssertEqual(ModuleSyncPlanner.state(localHash: "base", githubHash: "new", baseHash: "base"), .githubAhead)
        XCTAssertEqual(ModuleSyncPlanner.state(localHash: "left", githubHash: "right", baseHash: "base"), .bothChanged)
        XCTAssertEqual(ModuleSyncPlanner.state(localHash: "left", githubHash: "right", baseHash: nil), .unbasedDifference)
    }

    func testManagedHeadersAndCRLFDoNotCreateFalseDifferences() {
        let content = Data("#!name=Demo\n[Rule]\nFINAL,DIRECT\n".utf8)
        let managed = ManagedPublishedFile.dataWrapping(content, relativePath: "Demo.sgmodule")
        let crlf = Data(String(decoding: managed, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n").utf8)
        XCTAssertEqual(ModuleSyncPlanner.normalizedPublishedData(crlf), content)
    }

    func testBaselineMigrationAndConflictCompatibility() throws {
        var module = RelayModule(name: "Demo", sourceURL: "https://example.org/demo", outputFileName: "Demo")
        module.syncBaseHash = "base"
        module.syncBaseScope = "scope"
        let data = try JSONEncoder().encode(module)
        XCTAssertEqual(try JSONDecoder().decode(RelayModule.self, from: data).syncBaseHash, "base")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "syncBaseHash")
        legacy.removeValue(forKey: "syncBaseScope")
        let decoded = try JSONDecoder().decode(RelayModule.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.syncBaseHash)
        XCTAssertNil(decoded.syncBaseScope)
        let conflict = ModuleSyncConflictMetadata(localHash: "left", githubHash: "right", localUpdatedAt: .now, githubUpdatedAt: .now, detectedAt: .now)
        XCTAssertEqual(try JSONDecoder().decode(ModuleSyncConflictMetadata.self, from: JSONEncoder().encode(conflict)).comparisonState, .unbasedDifference)
    }

    func testLineDiffPreservesLineNumbersAndInsertionDeletion() {
        let diff = ModuleLineDiffPlanner.compare(local: "a\nold\nsame\n", github: "a\nnew\nsame\n")
        XCTAssertEqual(diff.removedCount, 1)
        XCTAssertEqual(diff.addedCount, 1)
        XCTAssertFalse(diff.usesCoarseComparison)
        let removed = diff.rows.first { $0.kind == .removed }
        let added = diff.rows.first { $0.kind == .added }
        XCTAssertEqual(removed?.text, "old")
        XCTAssertEqual(removed?.localLine, 2)
        XCTAssertNil(removed?.githubLine)
        XCTAssertEqual(added?.text, "new")
        XCTAssertEqual(added?.githubLine, 2)
        let inserted = ModuleLineDiffPlanner.compare(local: "a\nb", github: "a\nnew\nb")
        XCTAssertEqual(inserted.removedCount, 0)
        XCTAssertEqual(inserted.addedCount, 1)
        let empty = ModuleLineDiffPlanner.compare(local: "", github: "")
        XCTAssertEqual(empty.removedCount + empty.addedCount, 0)
        let created = ModuleLineDiffPlanner.compare(local: "", github: "line\n")
        XCTAssertEqual(created.removedCount, 0)
        XCTAssertEqual(created.addedCount, 1)
        XCTAssertTrue(ModuleLineDiffPlanner.compare(local: "line", github: "line\n").hasFinalNewlineDifference)
    }

    func testLargeDiffBoundsComparisonAndDisplayedRows() {
        let local = (0..<1_500).map { "left-\($0)" }.joined(separator: "\n")
        let remote = (0..<1_500).map { "right-\($0)" }.joined(separator: "\n")
        let diff = ModuleLineDiffPlanner.compare(local: local, github: remote)
        XCTAssertTrue(diff.usesCoarseComparison)
        XCTAssertTrue(diff.isTruncated)
        XCTAssertEqual(diff.rows.count, ModuleLineDiffPlanner.maximumDisplayedRows)
        XCTAssertEqual(diff.removedCount, 1_500)
        XCTAssertEqual(diff.addedCount, 1_500)
    }

    func testReviewedSnapshotRejectsChangedFileCommitAndScope() {
        let metadata = ModuleSyncConflictMetadata(localHash: "local", githubHash: "remote", localUpdatedAt: .now, githubUpdatedAt: .now, detectedAt: .now)
        let original = ModuleSyncComparison(moduleID: UUID(), scope: "scope", localData: Data(), githubData: Data(), localFileHash: "raw-local", githubCommitSHA: "head", metadata: metadata, diff: ModuleLineDiffPlanner.compare(local: "", github: ""))
        XCTAssertTrue(ModuleSyncPlanner.isCurrent(original, comparedTo: original))
        var changed = original
        changed.localFileHash = "changed"
        XCTAssertFalse(ModuleSyncPlanner.isCurrent(original, comparedTo: changed))
        changed = original
        changed.githubCommitSHA = "new-head"
        XCTAssertFalse(ModuleSyncPlanner.isCurrent(original, comparedTo: changed))
        changed = original
        changed.metadata.githubHash = "new-content"
        XCTAssertFalse(ModuleSyncPlanner.isCurrent(original, comparedTo: changed))
        changed = original
        changed.scope = "new-destination"
        XCTAssertFalse(ModuleSyncPlanner.isCurrent(original, comparedTo: changed))
    }

}

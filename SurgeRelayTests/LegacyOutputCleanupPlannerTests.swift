import Foundation
import XCTest
@testable import SurgeRelay

final class LegacyOutputCleanupPlannerTests: XCTestCase {
    func testLegacyOutputCleanupDirectoriesSkipActiveLocalModuleRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let localRoot = root.appending(path: "SurgeRoot", directoryHint: .isDirectory)
        let configuration = localRoot.appending(path: "Surge Relay", directoryHint: .isDirectory)

        let directories = LegacyOutputCleanupPlanner.cleanupDirectories(
            outputDirectory: localRoot.path,
            configurationDirectory: configuration.path,
            localModuleDirectory: localRoot.path
        )

        XCTAssertEqual(directories, [configuration.standardizedFileURL.path])
    }

    func testLegacyOutputCleanupPlannerBuildsKnownPublishedPaths() {
        XCTAssertEqual(
            LegacyOutputCleanupPlanner.publishedRelativePaths(
                combinedModuleFileName: "Daily Relay",
                managedEngineFileName: "Engine Relay"
            ),
            [
                "Daily-Relay.sgmodule",
                "Surge-Relay.sgmodule",
                "Engine-Relay.sgmodule",
                "Script-Hub-Relay.sgmodule"
            ]
        )
    }
}

import Foundation
import XCTest
@testable import SurgeRelay

final class LegacyOutputCleanupPlannerTests: XCTestCase {
    func testLegacyCleanupSkipsSymlinkAliasOfActiveModuleRoot() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let modules = root.appending(path: "Modules", directoryHint: .isDirectory)
        let alias = root.appending(path: "OldOutput", directoryHint: .isDirectory)
        let configuration = root.appending(path: "Configuration", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: modules)
        let paths = LegacyOutputCleanupPlanner.cleanupDirectories(outputDirectory: alias.path,
            configurationDirectory: configuration.path, localModuleDirectory: modules.path)
        XCTAssertEqual(paths, [configuration.resolvingSymlinksInPath().standardizedFileURL.path])
    }

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

        XCTAssertEqual(directories, [configuration.resolvingSymlinksInPath().standardizedFileURL.path])
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

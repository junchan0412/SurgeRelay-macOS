import Foundation
import XCTest
@testable import SurgeRelay

final class ConfigurationMigrationTests: XCTestCase {
    @MainActor
    func testConfigurationWriterEncodesOffMainThreadAndPreservesWriteOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ConfigurationPersistenceWriter(directory: root)
        for value in 0..<8 { writer.enqueue(BackgroundEncodedSnapshot(value: value), fileName: "modules.json") }
        try await writer.flush()
        let saved = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: root.appending(path: "modules.json")))
        XCTAssertEqual(saved["value"], 7)
        let backups = try FileManager.default.contentsOfDirectory(at: root.appending(path: "Backups/modules.json"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 7)
    }

    func testConfigurationWriterFlushRetriesFailedSnapshotWithoutLosingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let failure = PersistenceFailureSwitch()
        let writer = ConfigurationPersistenceWriter(directory: root) { data, url in
            if failure.shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        writer.enqueue(["value": 1], fileName: "selected-publish.json")
        do { try await writer.flush(); XCTFail("Flush must report the failed write") }
        catch { XCTAssertTrue(error.localizedDescription.contains("selected-publish.json")) }
        failure.allowWrites()
        try await writer.flush()
        let saved = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: root.appending(path: "selected-publish.json")))
        XCTAssertEqual(saved["value"], 1)
        writer.enqueue(["value": 2], fileName: "selected-publish.json")
        try await writer.flush()
        let latest = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: root.appending(path: "selected-publish.json")))
        XCTAssertEqual(latest["value"], 2)
    }

    func testConfigurationWriterQueuesEditsDuringMigrationIntoNewDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let destination = root.appending(path: "destination", directoryHint: .isDirectory)
        let versions = source.appending(path: "ModuleVersions/module/version", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        try Data("historical content".utf8).write(to: versions.appending(path: "Content.module"))
        let writer = ConfigurationPersistenceWriter(directory: source)
        writer.enqueue(["value": 1], fileName: "modules.json")
        let enteredCommit = expectation(description: "migration reached directory switch")
        let releaseCommit = DispatchSemaphore(value: 0)
        let migration = Task {
            try await writer.migrate(to: destination) { _ in
                enteredCommit.fulfill()
                releaseCommit.wait()
            }
        }
        await fulfillment(of: [enteredCommit], timeout: 3)
        writer.enqueue(["value": 2], fileName: "modules.json")
        releaseCommit.signal()
        _ = try await migration.value
        try await writer.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "modules.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "ModuleVersions").path))
        let saved = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: destination.appending(path: "modules.json")))
        XCTAssertEqual(saved["value"], 2)
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "ModuleVersions/module/version/Content.module"), encoding: .utf8), "historical content")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "Backups/modules.json").path))
    }

    func testConfigurationWriterDoesNotMigrateAfterAnUnrecoverableWriteFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let destination = root.appending(path: "destination", directoryHint: .isDirectory)
        let writer = ConfigurationPersistenceWriter(directory: source) { _, _ in throw CocoaError(.fileWriteNoPermission) }
        writer.enqueue(["value": 1], fileName: "modules.json")
        do {
            _ = try await writer.migrate(to: destination) { _ in XCTFail("Failed snapshots must prevent directory switching") }
            XCTFail("Migration must fail when a queued snapshot cannot be saved")
        } catch {}
        let current = await writer.currentDirectory()
        XCTAssertEqual(current, source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testConfigurationMigrationCopiesRegistryHistoryBackupsAndOverrides() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Source", directoryHint: .isDirectory)
        let destination = root.appending(path: "Destination", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(
            at: source.appending(path: "Backups/modules.json", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: source.appending(path: "Overrides/nested", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination.appending(path: "Backups/settings.json", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination.appending(path: "Overrides", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        try Data("[{\"name\":\"source\"}]".utf8).write(to: source.appending(path: "modules.json"))
        try Data("{\"storageMode\":\"local\"}".utf8).write(to: source.appending(path: "settings.json"))
        try Data("{\"revision\":\"abc\"}".utf8).write(to: source.appending(path: "script-hub-state.json"))
        try Data("[{\"message\":\"history\"}]".utf8).write(to: source.appending(path: "update-history.json"))
        try Data("root backup".utf8).write(to: source.appending(path: "Backups/modules.json/root.backup"))
        try Data("override".utf8).write(to: source.appending(path: "Overrides/nested/module.cache"))
        try Data("old modules".utf8).write(to: destination.appending(path: "modules.json"))
        try Data("keep backup".utf8).write(to: destination.appending(path: "Backups/settings.json/keep.backup"))
        try Data("keep override".utf8).write(to: destination.appending(path: "Overrides/keep.cache"))

        try PersistenceStore.migrateConfigurationFiles(from: source, to: destination)

        XCTAssertEqual(try String(contentsOf: destination.appending(path: "modules.json"), encoding: .utf8), "[{\"name\":\"source\"}]")
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "settings.json"), encoding: .utf8), "{\"storageMode\":\"local\"}")
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "script-hub-state.json"), encoding: .utf8), "{\"revision\":\"abc\"}")
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "update-history.json"), encoding: .utf8), "[{\"message\":\"history\"}]")
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Backups/modules.json/root.backup"), encoding: .utf8),
            "root backup"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Backups/settings.json/keep.backup"), encoding: .utf8),
            "keep backup"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Overrides/nested/module.cache"), encoding: .utf8),
            "override"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Overrides/keep.cache"), encoding: .utf8),
            "keep override"
        )
        let overwrittenBackups = try FileManager.default.subpathsOfDirectory(
            atPath: destination.appending(path: "Backups/configuration-migration/modules.json").path
        )
        XCTAssertEqual(overwrittenBackups.count, 1)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appending(path: "Backups/configuration-migration/modules.json/\(overwrittenBackups[0])"),
                encoding: .utf8
            ),
            "old modules"
        )
    }

    func testConfigurationMigrationCleanupRemovesOnlySurgeRelayConfigurationFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Source", directoryHint: .isDirectory)
        let destination = source.appending(path: "Surge Relay", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: source.appending(path: "Backups/modules.json", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: source.appending(path: "Sgmodule", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("modules".utf8).write(to: source.appending(path: "modules.json"))
        try Data("settings".utf8).write(to: source.appending(path: "settings.json"))
        try Data("history".utf8).write(to: source.appending(path: "update-history.json"))
        try Data("state".utf8).write(to: source.appending(path: "script-hub-state.json"))
        try Data("backup".utf8).write(to: source.appending(path: "Backups/modules.json/root.backup"))
        try Data("module".utf8).write(to: source.appending(path: "Sgmodule/Original.sgmodule"))
        try Data("surge".utf8).write(to: source.appending(path: "Surge.conf"))

        try PersistenceStore.migrateConfigurationFiles(from: source, to: destination)
        try PersistenceStore.removeMigratedConfigurationFiles(from: source, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "modules.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "settings.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "script-hub-state.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "update-history.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "Backups").path))
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "modules.json"), encoding: .utf8), "modules")
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Backups/modules.json/root.backup"), encoding: .utf8),
            "backup"
        )
        XCTAssertEqual(try String(contentsOf: source.appending(path: "Sgmodule/Original.sgmodule"), encoding: .utf8), "module")
        XCTAssertEqual(try String(contentsOf: source.appending(path: "Surge.conf"), encoding: .utf8), "surge")
    }
}

private struct BackgroundEncodedSnapshot: Encodable, Sendable {
    let value: Int
    func encode(to encoder: any Encoder) throws {
        XCTAssertFalse(Thread.isMainThread)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }
    private enum CodingKeys: String, CodingKey { case value }
}

private final class PersistenceFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var fails = true
    var shouldFail: Bool { lock.withLock { fails } }
    func allowWrites() { lock.withLock { fails = false } }
}

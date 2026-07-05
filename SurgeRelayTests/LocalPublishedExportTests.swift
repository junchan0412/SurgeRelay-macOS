import Foundation
import XCTest
@testable import SurgeRelay

final class LocalPublishedExportTests: XCTestCase {
    func testLocalPublishedExportRemovesManifestStaleFilesOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore()
        _ = try await store.exportPublishedFiles([
            PublishFile(name: "Old.sgmodule", data: Data("old".utf8)),
            PublishFile(name: "Folder/Current.sgmodule", data: Data("current".utf8))
        ], toRootDirectory: root.path)
        try Data("manual".utf8).write(to: root.appending(path: "Manual.sgmodule"))

        let removed = try await store.exportPublishedFiles(
            [PublishFile(name: "New.sgmodule", data: Data("new".utf8))],
            toRootDirectory: root.path,
            removingObsoleteRelativePaths: ["Old.sgmodule", "Folder/Current.sgmodule"]
        )

        XCTAssertEqual(Set(removed), ["Old.sgmodule", "Folder/Current.sgmodule"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Old.sgmodule").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Folder").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "New.sgmodule").path))
        XCTAssertTrue(
            try String(contentsOf: root.appending(path: "New.sgmodule"), encoding: .utf8)
                .contains("# Surge Relay managed output")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Manual.sgmodule").path))
    }

    func testLocalPublishedExportRefusesUnmanagedSameNameFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = root.appending(path: "Personal.sgmodule")
        try Data("#!name=Personal\n[Rule]\nFINAL,DIRECT\n".utf8).write(to: existing)

        let store = ModuleFileStore()
        do {
            _ = try await store.exportPublishedFiles(
                [PublishFile(name: "Personal.sgmodule", data: Data("#!name=Relay\n[Rule]\nFINAL,REJECT\n".utf8))],
                toRootDirectory: root.path
            )
            XCTFail("不应覆盖未被 Surge Relay 管理的同名文件")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("不属于 Surge Relay 管理"))
        }

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "#!name=Personal\n[Rule]\nFINAL,DIRECT\n")
    }

    func testLocalPublishedExportMigratesKnownLegacyManagedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appending(path: "Legacy.sgmodule")
        try Data("#!name=Legacy\n[Rule]\nFINAL,DIRECT\n".utf8).write(to: destination)

        let store = ModuleFileStore()
        _ = try await store.exportPublishedFiles(
            [PublishFile(name: "Legacy.sgmodule", data: Data("#!name=Legacy\n[Rule]\nFINAL,REJECT\n".utf8))],
            toRootDirectory: root.path,
            knownManagedRelativePaths: ["Legacy.sgmodule"]
        )

        let written = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(written.contains("# Surge Relay managed output"))
        XCTAssertTrue(written.contains("FINAL,REJECT"))
    }

    func testLocalPublishedExportPreservesSurgeMetadataHeader() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = ModuleFileStore()
        _ = try await store.exportPublishedFiles(
            [
                PublishFile(
                    name: "Header.sgmodule",
                    data: Data("""
                    #!name=Header
                    #!category=Ads
                    [Rule]
                    FINAL,REJECT

                    """.utf8)
                )
            ],
            toRootDirectory: root.path
        )

        let written = try String(contentsOf: root.appending(path: "Header.sgmodule"), encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("""
        #!name=Header
        #!category=Ads
        # Surge Relay managed output
        # surge-relay-relative-path: Header.sgmodule

        """))
    }

    func testLocalPublishedCleanupRefusesUnmanagedStaleFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = root.appending(path: "Manual.sgmodule")
        try Data("#!name=Manual\n[Rule]\nFINAL,DIRECT\n".utf8).write(to: stale)

        let store = ModuleFileStore()
        do {
            _ = try await store.exportPublishedFiles(
                [],
                toRootDirectory: root.path,
                removingObsoleteRelativePaths: ["Manual.sgmodule"]
            )
            XCTFail("不应自动清理未被 Surge Relay 管理的旧文件")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("不属于 Surge Relay 管理"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
    }

    func testLegacyPublishedCleanupRemovesOnlyExplicitPaths() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore()
        try FileManager.default.createDirectory(
            at: root.appending(path: "assets/custom", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("combined".utf8).write(to: root.appending(path: "Surge-Relay.sgmodule"))
        try Data("manual".utf8).write(to: root.appending(path: "Manual.sgmodule"))
        try Data("asset".utf8).write(to: root.appending(path: "assets/custom/file.js"))

        let removed = try await store.removeLegacyPublishedFiles(
            in: root.path,
            relativePaths: ["Surge-Relay.sgmodule"]
        )

        XCTAssertEqual(removed, ["Surge-Relay.sgmodule"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Surge-Relay.sgmodule").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Manual.sgmodule").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "assets/custom/file.js").path))
    }

    func testGeneratedAssetFilesCanBeFilteredByModuleID() async throws {
        let includedID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let excludedID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let store = ModuleFileStore()
        defer {
            Task {
                try? await store.removeAssets(id: includedID)
                try? await store.removeAssets(id: excludedID)
            }
        }

        try await store.replaceAssets([
            GeneratedAsset(
                relativePath: "assets/\(includedID.uuidString.lowercased())/keep.js",
                data: Data("keep".utf8)
            )
        ], id: includedID)
        try await store.replaceAssets([
            GeneratedAsset(
                relativePath: "assets/\(excludedID.uuidString.lowercased())/drop.js",
                data: Data("drop".utf8)
            )
        ], id: excludedID)

        let files = try await store.generatedAssetFiles(for: [includedID])

        XCTAssertEqual(files.map(\.name), ["assets/\(includedID.uuidString.lowercased())/keep.js"])
    }
}

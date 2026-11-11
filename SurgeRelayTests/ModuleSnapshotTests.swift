import Foundation
import XCTest
@testable import SurgeRelay

final class ModuleSnapshotTests: XCTestCase {
    func testClientChangeArchivesThePreviousOverrideAndRetiresItOnlyAfterCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        let id = UUID()
        let source = URL(string: "https://example.org/Demo.plugin")!
        let oldContent = "#!name=Surge\n[Rule]\nFINAL,DIRECT\n"
        let override = "#!name=Edited Surge\n[Rule]\nFINAL,REJECT\n"
        try await store.commitConversion(ConversionResult(content: oldContent, requestURL: source), id: id)
        try await store.writeComponentOverride(override, id: id)
        let loon = "#!name=Loon\n[Rewrite]\n^https://example.org - reject\n"
        let invalid = ConversionResult(content: loon, requestURL: source,
            assets: [GeneratedAsset(relativePath: "assets/another-module/helper.js", data: Data("// helper".utf8))], outputFormat: .loon)
        do {
            try await store.commitConversion(invalid, id: id, retiringOverride: true)
            XCTFail("A failed client conversion must leave the prior override in place")
        } catch {}
        let keptOverride = try await store.readComponent(id: id)
        let keptConverted = try await store.readConvertedComponent(id: id)
        XCTAssertEqual(keptOverride, override)
        XCTAssertEqual(keptConverted, oldContent)
        let result = ConversionResult(content: loon, requestURL: source, outputFormat: .loon)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.commitConversion(result, id: id, retiringOverride: true)
        }
        do {
            try await cancelled.value
            XCTFail("A cancelled client conversion must leave the prior override in place")
        } catch { XCTAssertTrue(error is CancellationError) }
        let afterCancellation = try await store.readComponent(id: id)
        XCTAssertEqual(afterCancellation, override)
        try await store.commitConversion(result, id: id, retiringOverride: true)
        let current = try await store.readComponent(id: id)
        let format = try await store.convertedOutputFormat(id: id)
        let hasOverride = await store.hasOverride(id: id)
        XCTAssertEqual(current, loon)
        XCTAssertEqual(format, .loon)
        XCTAssertFalse(hasOverride)
        let versions = try await store.moduleVersions(id: id)
        let archived = try await store.readModuleVersion(id: id, versionID: XCTUnwrap(versions.first?.id))
        XCTAssertEqual(archived.content, override)
        XCTAssertEqual(archived.convertedContent, oldContent)
        XCTAssertTrue(archived.record.hasOverride)
    }

    func testSnapshotOverrideAndVersionRecoveryPreserveClientTextBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        let id = UUID()
        let content = "name: Demo\r\nscript-providers:\r\n  Demo:\r\n    script: |\r\n      [Map Local]\r\n\r\n\r\n      [Script]\r\n      console.log('body');\r\n"
        let result = ConversionResult(content: content, requestURL: URL(string: "https://example.org/Demo.stoverride")!, outputFormat: .stash)
        let prepared = try await store.prepareConversion(result, id: id)
        XCTAssertEqual(prepared.converted, content)
        try await store.commitConversion(result, id: id)
        let converted = try await store.readConvertedComponent(id: id)
        XCTAssertEqual(converted, content)
        let savedVersion = try await store.recordCurrentVersion(id: id, reason: .current)
        let version = try XCTUnwrap(savedVersion)
        let edited = content.replacingOccurrences(of: "console.log('body')", with: "console.log('edited')")
        try await store.writeComponentOverride(edited, id: id)
        let override = try await store.readComponent(id: id)
        XCTAssertEqual(override, edited)
        let currentValue = try await store.currentVersionContent(id: id)
        let current = try XCTUnwrap(currentValue)
        _ = try await store.restoreModuleVersion(id: id, versionID: version.id, expectedFingerprint: current.record.fingerprint)
        let restored = try await store.readComponent(id: id)
        let historical = try await store.readModuleVersion(id: id, versionID: version.id)
        XCTAssertEqual(restored, content)
        XCTAssertEqual(historical.content, content)
    }

    func testSnapshotCommitsContentAndAssetsTogetherAndPreservesOverrides() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        let id = UUID()
        func result(_ name: String) -> ConversionResult {
            ConversionResult(content: "#!name=\(name)\n[Rule]\nDOMAIN,example.org,DIRECT\n", requestURL: URL(string: "https://test.invalid/module")!,
                             assets: [GeneratedAsset(relativePath: "assets/\(id.uuidString.lowercased())/\(name).js", data: Data(name.utf8))])
        }
        try await store.commitConversion(result("first"), id: id)
        try await store.writeComponentOverride("#!name=override\n", id: id)
        try await store.commitConversion(result("second"), id: id)
        let converted = try await store.readConvertedComponent(id: id)
        let effective = try await store.readComponent(id: id)
        let assets = try await store.generatedAssetFiles(for: [id])
        XCTAssertTrue(converted.contains("second"))
        XCTAssertTrue(effective.contains("override"))
        XCTAssertEqual(assets.map(\.name), ["assets/\(id.uuidString.lowercased())/second.js"])
    }

    func testInvalidAssetDoesNotDestroyLastWorkingSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root)
        let id = UUID()
        let url = URL(string: "https://test.invalid/module")!
        let previous = ConversionResult(content: "#!name=working\n", requestURL: url,
                                        assets: [GeneratedAsset(relativePath: "assets/\(id.uuidString.lowercased())/working.js", data: Data("working".utf8))])
        try await store.commitConversion(previous, id: id)
        for path in ["assets/another-module/script.js", "assets/\(id.uuidString.lowercased())/../../escaped.js"] {
            let invalid = ConversionResult(content: "#!name=broken\n", requestURL: url, assets: [GeneratedAsset(relativePath: path, data: Data())])
            do {
                try await store.commitConversion(invalid, id: id)
                XCTFail("Invalid assets must fail before replacing the snapshot")
            } catch {}
            let content = try await store.readConvertedComponent(id: id)
            let assets = try await store.generatedAssetFiles(for: [id])
            XCTAssertEqual(content, previous.content)
            XCTAssertEqual(assets.map(\.name), previous.assets.map(\.relativePath))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "escaped.js").path))
    }

    func testNewSnapshotSupersedesLegacyAssetsWithoutDuplicatingThem() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root)
        let id = UUID()
        try await store.writeComponent("#!name=legacy\n", id: id)
        try await store.replaceAssets([GeneratedAsset(relativePath: "assets/\(id.uuidString.lowercased())/legacy.js", data: Data())], id: id)
        try await store.commitConversion(ConversionResult(content: "#!name=new\n", requestURL: URL(string: "https://test.invalid/module")!), id: id)
        let content = try await store.readComponent(id: id)
        let assets = try await store.generatedAssetFiles()
        XCTAssertTrue(content.contains("new"))
        XCTAssertTrue(assets.isEmpty)
    }
}

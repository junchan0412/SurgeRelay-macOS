import Foundation
import XCTest
@testable import SurgeRelay

final class ModuleSnapshotTests: XCTestCase {
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

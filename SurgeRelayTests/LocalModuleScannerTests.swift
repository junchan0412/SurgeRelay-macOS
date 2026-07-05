import Foundation
import XCTest
@testable import SurgeRelay

final class LocalModuleScannerTests: XCTestCase {
    func testLocalModuleScannerDiscoversExistingModules() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Ads", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("""
        #!name=YouTube
        #!category=Video
        [General]
        """.utf8).write(to: root.appending(path: "Ads/YouTube Ads.sgmodule"))
        try Data("#!name=Combined\n[General]\n".utf8).write(to: root.appending(path: "Surge-Relay.sgmodule"))

        let candidates = try LocalModuleScanner.candidates(
            in: root.path,
            combinedFileName: "Surge Relay",
            existingModules: [],
            publishedFilePaths: []
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].relativePath, "Ads/YouTube Ads.sgmodule")
        XCTAssertEqual(candidates[0].id, "Ads/YouTube Ads.sgmodule")
        XCTAssertEqual(candidates[0].name, "YouTube")
        XCTAssertEqual(candidates[0].category, "Video")
        XCTAssertEqual(candidates[0].outputFolder, "Ads")
        XCTAssertEqual(candidates[0].outputFileName, "YouTube Ads.sgmodule")
    }

    func testLocalModuleScannerReportsSkippedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!name=Combined\n[General]\n".utf8).write(to: root.appending(path: "Surge-Relay.sgmodule"))
        try Data().write(to: root.appending(path: "Empty.sgmodule"))
        try Data("#!name=Managed\n[General]\n".utf8).write(to: root.appending(path: "Managed.sgmodule"))

        let report = try LocalModuleScanner.report(
            in: root.path,
            combinedFileName: "Surge Relay",
            existingModules: [],
            publishedFilePaths: ["Managed.sgmodule"]
        )

        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: report.skippedFiles.map { ($0.relativePath, $0.reason) }),
            [
                "Empty.sgmodule": "文件为空",
                "Managed.sgmodule": "发布路径已纳入管理",
                "Surge-Relay.sgmodule": "这是当前总模块文件"
            ]
        )
    }

    func testLocalModuleFolderScannerFindsNestedFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Ads/Video", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appending(path: "Tools", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(
            try LocalModuleFolderScanner.folders(in: root.path),
            ["Ads", "Ads/Video", "Tools"]
        )
    }

    func testLocalModuleRootDiagnosticsReportsWritableDirectoryContents() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Ads/Video", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("#!name=Demo\n[General]\n".utf8).write(to: root.appending(path: "Ads/Video/Demo.sgmodule"))
        try Data("ignore".utf8).write(to: root.appending(path: "notes.txt"))

        let diagnostics = LocalModuleRootDiagnosticSnapshot.current(path: root.path)

        XCTAssertTrue(diagnostics.exists)
        XCTAssertTrue(diagnostics.isDirectory)
        XCTAssertTrue(diagnostics.isWritable)
        XCTAssertEqual(diagnostics.folderCount, 2)
        XCTAssertEqual(diagnostics.moduleFileCount, 1)
        XCTAssertEqual(diagnostics.status, "目录可用")
        XCTAssertNil(diagnostics.error)
    }
}

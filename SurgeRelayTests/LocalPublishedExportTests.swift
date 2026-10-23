import Foundation
import XCTest
@testable import SurgeRelay

final class LocalPublishedExportTests: XCTestCase {
    func testKnownPathsCannotOverrideMalformedOrMismatchedManagementDeclarations() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "assets"), withIntermediateDirectories: true)
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        let declarations = ["# Surge Relay managed output\n", "# surge-relay-relative-path: ../Other.sgmodule\n",
            "# Surge Relay managed output\n# surge-relay-relative-path: Other.sgmodule\n"]
        for path in ["Demo.sgmodule", "assets/demo.js"] {
            for declaration in declarations {
                let original = Data((declaration + "personal content").utf8)
                let url = root.appending(path: path)
                try original.write(to: url)
                do {
                    _ = try await store.exportPublishedFiles([PublishFile(name: path, data: Data("replacement".utf8))],
                        toRootDirectory: root.path, knownManagedRelativePaths: [path])
                    XCTFail("Known legacy paths cannot override broken or mismatched management declarations")
                } catch { XCTAssertTrue(error.localizedDescription.contains("不属于 Surge Relay 管理")) }
                do {
                    _ = try await store.exportPublishedFiles([], toRootDirectory: root.path,
                        removingObsoleteRelativePaths: [path], knownManagedRelativePaths: [path])
                    XCTFail("Known legacy paths cannot delete broken or mismatched management declarations")
                } catch { XCTAssertTrue(error.localizedDescription.contains("不属于 Surge Relay 管理")) }
                XCTAssertEqual(try Data(contentsOf: url), original)
            }
        }
    }

    func testCleanupPreservesCurrentSourceEvenWithManagedMarkerAndKnownPath() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        _ = try await store.exportPublishedFiles([PublishFile(name: "Source.sgmodule", data: Data("source".utf8)),
            PublishFile(name: "Old.sgmodule", data: Data("old".utf8))], toRootDirectory: root.path)
        let source = root.appending(path: "Source.sgmodule")
        let original = try Data(contentsOf: source)
        let removed = try await store.exportPublishedFiles([], toRootDirectory: root.path,
            removingObsoleteRelativePaths: ["Source.sgmodule", "Old.sgmodule"],
            knownManagedRelativePaths: ["Source.sgmodule", "Old.sgmodule"], protectedSourcePaths: ["source.sgmodule"])
        XCTAssertEqual(removed, ["Old.sgmodule"])
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testExportRejectsEquivalentDestinationsBeforeWritingOrCleaning() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        let old = PublishFile(name: "Old.sgmodule", data: Data("old".utf8))
        _ = try await store.exportPublishedFiles([old], toRootDirectory: root.path)
        let oldData = try Data(contentsOf: root.appending(path: old.name))
        for pair in [["Folder/Demo.sgmodule", "folder/demo.sgmodule"],
                     ["Folder/Demo.sgmodule", "Folder\\Demo.sgmodule"],
                     ["Caf\u{e9}.sgmodule", "Cafe\u{301}.sgmodule"]] {
            do {
                _ = try await store.exportPublishedFiles(pair.map { PublishFile(name: $0, data: Data("replacement".utf8)) },
                    toRootDirectory: root.path, removingObsoleteRelativePaths: [old.name])
                XCTFail("Equivalent destinations must fail before touching the directory")
            } catch { XCTAssertTrue(error.localizedDescription.contains("重复路径")) }
            XCTAssertEqual(try Data(contentsOf: root.appending(path: old.name)), oldData)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: pair[0]).path))
        }
    }

    func testActivePathAliasIsExcludedFromCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PublishFile(name: "Folder/Demo.sgmodule", data: Data("original".utf8))
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        _ = try await store.exportPublishedFiles([file], toRootDirectory: root.path)
        let removed = try await store.exportPublishedFiles([file], toRootDirectory: root.path,
            removingObsoleteRelativePaths: ["Folder\\Demo.sgmodule"], expectedExistingHashes: ["Folder\\Demo.sgmodule": "stale review"])
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(ModuleSyncPlanner.normalizedPublishedData(try Data(contentsOf: root.appending(path: file.name))), file.data)
    }

    func testExportRejectsUnsafeOrConflictingPathsBeforeWriting() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "Output")
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        for path in ["/Absolute.sgmodule", "Folder/../Escape.sgmodule", "Folder//Empty.sgmodule", "Line\nBreak.sgmodule"] {
            do {
                _ = try await store.exportPublishedFiles([PublishFile(name: "First.sgmodule", data: Data()), PublishFile(name: path, data: Data())],
                    toRootDirectory: output.path)
                XCTFail("Invalid path must fail before the first file is exported")
            } catch { XCTAssertTrue(error.localizedDescription.contains("发布路径无效")) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        do {
            _ = try await store.exportPublishedFiles([PublishFile(name: "assets", data: Data()), PublishFile(name: "assets/file.js", data: Data())],
                toRootDirectory: output.path)
            XCTFail("A batch may not replace a required parent directory with a file")
        } catch { XCTAssertTrue(error.localizedDescription.contains("文件与目录路径冲突")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testDirectoryAndFileSymlinksCannotEscapePublishRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "Output")
        let outside = root.appending(path: "Outside")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let userFile = outside.appending(path: "Personal.sgmodule")
        let original = ManagedPublishedFile.dataWrapping(Data("personal".utf8), relativePath: "Linked/Personal.sgmodule")
        try original.write(to: userFile)
        try FileManager.default.createSymbolicLink(at: output.appending(path: "Linked"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: output.appending(path: "Personal.sgmodule"), withDestinationURL: userFile)
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        for path in ["Linked/Personal.sgmodule", "Personal.sgmodule"] {
            do {
                _ = try await store.exportPublishedFiles([PublishFile(name: path, data: Data("replacement".utf8))],
                    toRootDirectory: output.path, knownManagedRelativePaths: [path])
                XCTFail("A symlink must not permit writes outside the configured root")
            } catch { XCTAssertTrue(error.localizedDescription.contains("符号链接")) }
            do {
                _ = try await store.exportPublishedFiles([], toRootDirectory: output.path, removingObsoleteRelativePaths: [path])
                XCTFail("A symlink must not permit cleanup outside the configured root")
            } catch { XCTAssertTrue(error.localizedDescription.contains("符号链接")) }
            XCTAssertEqual(try Data(contentsOf: userFile), original)
        }
    }

    func testCopiedModuleMarkerDoesNotAuthorizeDifferentPath() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = "Personal.sgmodule"
        let original = ManagedPublishedFile.dataWrapping(Data("personal".utf8), relativePath: "Elsewhere.sgmodule")
        try original.write(to: root.appending(path: path))
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        for knownPaths in [[], [path]] {
            do {
                _ = try await store.exportPublishedFiles([PublishFile(name: path, data: Data("replacement".utf8))],
                    toRootDirectory: root.path, knownManagedRelativePaths: knownPaths)
                XCTFail("A marker from another output path must not authorize overwriting a copied user file")
            } catch { XCTAssertTrue(error.localizedDescription.contains("不属于 Surge Relay 管理")) }
        }
        do {
            _ = try await store.exportPublishedFiles([], toRootDirectory: root.path, removingObsoleteRelativePaths: [path])
            XCTFail("A marker from another output path must not authorize cleanup")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不属于 Surge Relay 管理")) }
        XCTAssertEqual(try Data(contentsOf: root.appending(path: path)), original)
    }

    func testKnownManifestDoesNotOverrideInvalidResourceReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "Output")
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        let file = PublishFile(name: "assets/demo.js", data: Data("published".utf8))
        _ = try await store.exportPublishedFiles([file], toRootDirectory: output.path)
        try await store.acknowledgePublishedResources(paths: [file.name], rootDirectoryPath: output.path)
        let personal = Data("personal replacement".utf8)
        try personal.write(to: output.appending(path: file.name), options: .atomic)
        do {
            _ = try await store.exportPublishedFiles([file], toRootDirectory: output.path, knownManagedRelativePaths: [file.name])
            XCTFail("A persisted manifest cannot replace ownership identity verification")
        } catch { XCTAssertTrue(error.localizedDescription.contains("已被外部修改")) }
        do {
            _ = try await store.exportPublishedFiles([], toRootDirectory: output.path,
                removingObsoleteRelativePaths: [file.name], knownManagedRelativePaths: [file.name])
            XCTFail("A persisted manifest cannot delete externally replaced resources")
        } catch { XCTAssertTrue(error.localizedDescription.contains("已被外部修改")) }
        XCTAssertEqual(try Data(contentsOf: output.appending(path: file.name)), personal)
    }

    func testResourceReceiptCanBeAcknowledgedAndReusedThroughPathAliases() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "Output")
        let config = root.appending(path: "Config")
        let cache = root.appending(path: "Cache")
        let store = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
        let first = PublishFile(name: "assets/Demo.js", data: Data("first".utf8))
        _ = try await store.exportPublishedFiles([first], toRootDirectory: output.path)
        try await store.acknowledgePublishedResources(paths: ["assets\\Demo.js"], rootDirectoryPath: output.path)
        let pending = try await store.recoverPublishedResourcePaths(rootDirectoryPath: output.path)
        XCTAssertTrue(pending.isEmpty)
        let next = PublishFile(name: "assets\\Demo.js", data: Data("second".utf8))
        let restarted = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
        _ = try await restarted.exportPublishedFiles([next], toRootDirectory: output.path)
        XCTAssertEqual(try Data(contentsOf: output.appending(path: first.name)), next.data)
        try await restarted.acknowledgePublishedResources(paths: [first.name], rootDirectoryPath: output.path)
        let afterAck = try await restarted.recoverPublishedResourcePaths(rootDirectoryPath: output.path)
        XCTAssertTrue(afterAck.isEmpty)
    }

    func testResourceCommitRejectsDirectoryChangedToSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "Output")
        let outside = root.appending(path: "Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = PublishFile(name: "assets/demo.js", data: Data("published".utf8))
        let personal = Data("personal".utf8)
        try personal.write(to: outside.appending(path: "demo.js"))
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"),
            resourceInterruption: { phase in
                if phase == .beforeRename {
                    try FileManager.default.moveItem(at: output.appending(path: "assets"), to: output.appending(path: "StagedAssets"))
                    try FileManager.default.createSymbolicLink(at: output.appending(path: "assets"), withDestinationURL: outside)
                }
            })
        do {
            _ = try await store.exportPublishedFiles([file], toRootDirectory: output.path)
            XCTFail("A parent symlink introduced during publishing cannot redirect the commit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("符号链接")) }
        XCTAssertEqual(try Data(contentsOf: outside.appending(path: "demo.js")), personal)
    }

    func testLocalResourcesPublishExactBytesAndRequireManifestForLaterChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        let script = Data("\"use strict\";\r\nconst result = 1 + 2;\r\n".utf8)
        let binary = Data([0x00, 0xff, 0x89, 0xfe])
        let files = [PublishFile(name: "assets/main.js", data: script), PublishFile(name: "assets/data.bin", data: binary)]
        _ = try await store.exportPublishedFiles(files, toRootDirectory: root.path)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "assets/main.js")), script)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "assets/data.bin")), binary)
        let unknownRoot = root.appending(path: "Unmanaged", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unknownRoot.appending(path: "assets"), withIntermediateDirectories: true)
        try script.write(to: unknownRoot.appending(path: "assets/main.js"))
        do {
            _ = try await store.exportPublishedFiles([files[0]], toRootDirectory: unknownRoot.path)
            XCTFail("An unknown raw resource must not be silently adopted even when bytes match")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不属于 Surge Relay 管理")) }
        let changed = Data("function main() { return 7; }\n".utf8)
        _ = try await store.exportPublishedFiles([PublishFile(name: "assets/main.js", data: changed)], toRootDirectory: root.path,
                                                knownManagedRelativePaths: ["assets/main.js", "assets/data.bin"])
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "assets/main.js")), changed)
        let removed = try await store.exportPublishedFiles([], toRootDirectory: root.path,
            removingObsoleteRelativePaths: ["assets/main.js", "assets/data.bin"], knownManagedRelativePaths: ["assets/main.js", "assets/data.bin"])
        XCTAssertEqual(Set(removed), ["assets/main.js", "assets/data.bin"])
    }

    func testOldWrappedJavaScriptAndBinaryResourcesAreRepairedWithoutChangingPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "assets"), withIntermediateDirectories: true)
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        let samples = [("assets/legacy.js", Data("function main() { return 42; }\n".utf8)), ("assets/legacy.bin", Data([0xff, 0x00, 0xfe]))]
        for (path, payload) in samples {
            var old = Data("# Surge Relay managed output\n# surge-relay-relative-path: \(path)\n".utf8)
            old.append(payload)
            try old.write(to: root.appending(path: path))
            _ = try await store.exportPublishedFiles([PublishFile(name: path, data: payload)], toRootDirectory: root.path)
            XCTAssertEqual(try Data(contentsOf: root.appending(path: path)), payload)
        }
    }

    func testUnknownResourcesCannotBeDeletedOrClaimAnotherLegacyPath() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "assets"), withIntermediateDirectories: true)
        let path = "assets/user.js"
        let original = Data("# Surge Relay managed output\n# surge-relay-relative-path: assets/another.js\nconst value = 1;".utf8)
        try original.write(to: root.appending(path: path))
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        do {
            _ = try await store.exportPublishedFiles([PublishFile(name: path, data: Data("replacement".utf8))], toRootDirectory: root.path)
            XCTFail("A marker belonging to another relative path must not authorize overwrite")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不属于 Surge Relay 管理")) }
        do {
            _ = try await store.exportPublishedFiles([], toRootDirectory: root.path, removingObsoleteRelativePaths: [path])
            XCTFail("An unowned resource must not be deleted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不属于 Surge Relay 管理")) }
        XCTAssertEqual(try Data(contentsOf: root.appending(path: path)), original)
    }

    func testUnmanagedDestinationRejectsEntireBatchBeforeWritingOrCleaning() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "assets"), withIntermediateDirectories: true)
        let userData = Data("user owned script".utf8)
        try userData.write(to: root.appending(path: "assets/user.js"))
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        let first = PublishFile(name: "assets/first.js", data: Data("const a = 1;".utf8))
        let third = PublishFile(name: "assets/third.js", data: Data("const c = 3;".utf8))
        let old = PublishFile(name: "Old.sgmodule", data: Data("old".utf8))
        _ = try await store.exportPublishedFiles([old], toRootDirectory: root.path)
        let originalOld = try Data(contentsOf: root.appending(path: old.name))
        do {
            _ = try await store.exportPublishedFiles([first, PublishFile(name: "assets/user.js", data: Data("must not replace".utf8)), third],
                toRootDirectory: root.path, removingObsoleteRelativePaths: [old.name])
            XCTFail("The unowned middle file must stop the batch")
        } catch {
            XCTAssertFalse(error is LocalPublishPartialFailure)
            XCTAssertTrue(error.localizedDescription.contains("不属于 Surge Relay 管理"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: first.name).path))
        XCTAssertEqual(try Data(contentsOf: root.appending(path: old.name)), originalOld)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "assets/user.js")), userData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: third.name).path))
        _ = try await store.exportPublishedFiles([first, third], toRootDirectory: root.path, knownManagedRelativePaths: [first.name])
        XCTAssertEqual(try Data(contentsOf: root.appending(path: third.name)), third.data)
    }

    func testPartialExportReportsOnlyCommittedPathsAfterWriteFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = PublishFile(name: "First.sgmodule", data: Data("first".utf8))
        let second = PublishFile(name: "assets/second.js", data: Data("second".utf8))
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"),
            resourceInterruption: { phase in
                if phase == .staged { throw RelayError.invalidOutput("injected write failure") }
            })
        do {
            _ = try await store.exportPublishedFiles([first, second], toRootDirectory: root.path)
            XCTFail("Injected interruption must stop the batch")
        } catch let failure as LocalPublishPartialFailure {
            XCTAssertEqual(failure.writtenPaths, [first.name])
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: first.name).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: second.name).path))
    }

    func testExportCannotOverwriteProtectedSourceDespiteManagedMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        let path = "Source.sgmodule"
        _ = try await store.exportPublishedFiles([PublishFile(name: path, data: Data("source".utf8))], toRootDirectory: root.path)
        let original = try Data(contentsOf: root.appending(path: path))
        do {
            _ = try await store.exportPublishedFiles([PublishFile(name: "First.sgmodule", data: Data("new".utf8)),
                PublishFile(name: path, data: Data("replacement".utf8))], toRootDirectory: root.path,
                knownManagedRelativePaths: [path], protectedSourcePaths: ["source.sgmodule"])
            XCTFail("Registered source must remain protected during all export paths")
        } catch { XCTAssertTrue(error.localizedDescription.contains("本地来源文件")) }
        XCTAssertEqual(try Data(contentsOf: root.appending(path: path)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "First.sgmodule").path))
    }

    func testCleanupPreflightsAllOwnershipAndHashesBeforeDeleting() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        _ = try await store.exportPublishedFiles([PublishFile(name: "First.sgmodule", data: Data("first".utf8)),
            PublishFile(name: "Second.sgmodule", data: Data("second".utf8))], toRootDirectory: root.path)
        let first = try Data(contentsOf: root.appending(path: "First.sgmodule"))
        let second = try Data(contentsOf: root.appending(path: "Second.sgmodule"))
        do {
            _ = try await store.exportPublishedFiles([], toRootDirectory: root.path,
                removingObsoleteRelativePaths: ["First.sgmodule", "Second.sgmodule"],
                expectedExistingHashes: ["First.sgmodule": first.sha256String, "Second.sgmodule": "stale"])
            XCTFail("A stale later deletion must stop the whole cleanup")
        } catch { XCTAssertTrue(error.localizedDescription.contains("清理预览后")) }
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "First.sgmodule")), first)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "Second.sgmodule")), second)
    }

    func testResourceJournalRecoversOnlyRenamedGenerationAfterInterruption() async throws {
        for phase in [PublishedResourcePhase.journalPrepared, .staged, .beforeRename, .renamed] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let output = root.appending(path: "Output")
            let config = root.appending(path: "Config")
            let cache = root.appending(path: "Cache")
            let file = PublishFile(name: "assets/demo.js", data: Data("function main() { return 42; }\n".utf8))
            let interrupted = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config, resourceInterruption: {
                if $0 == phase { throw PublishedResourceCrash.interrupted }
            })
            do { _ = try await interrupted.exportPublishedFiles([file], toRootDirectory: output.path); XCTFail("Expected interruption") }
            catch {}
            let restarted = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
            let recovered = try await restarted.recoverPublishedResourcePaths(rootDirectoryPath: output.path)
            XCTAssertEqual(recovered, phase == .renamed ? [file.name] : [])
            XCTAssertEqual(FileManager.default.fileExists(atPath: output.appending(path: file.name).path), phase == .renamed)
            _ = try await restarted.exportPublishedFiles([file], toRootDirectory: output.path)
            XCTAssertEqual(try Data(contentsOf: output.appending(path: file.name)), file.data)
            let afterRetry = try await restarted.recoverPublishedResourcePaths(rootDirectoryPath: output.path)
            XCTAssertEqual(afterRetry, [file.name])
            let manifest = config.appending(path: "test-manifest.json")
            try JSONEncoder().encode(afterRetry).write(to: manifest, options: .atomic)
            try await restarted.acknowledgePublishedResources(paths: afterRetry, rootDirectoryPath: output.path)
            let afterAck = try await restarted.recoverPublishedResourcePaths(rootDirectoryPath: output.path)
            XCTAssertTrue(afterAck.isEmpty)
            let savedPaths = try JSONDecoder().decode([String].self, from: Data(contentsOf: manifest))
            let again = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
            _ = try await again.exportPublishedFiles([file], toRootDirectory: output.path, knownManagedRelativePaths: savedPaths)
        }
    }

    func testResourceJournalDoesNotAdoptUnknownReplacementWithIdenticalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "Output")
        let config = root.appending(path: "Config")
        let file = PublishFile(name: "assets/demo.bin", data: Data([0xff, 0x00, 0x55]))
        let crash = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: config, resourceInterruption: {
            if $0 == .renamed { throw PublishedResourceCrash.interrupted }
        })
        do { _ = try await crash.exportPublishedFiles([file], toRootDirectory: output.path) }
        catch {}
        let destination = output.appending(path: file.name)
        let replacement = output.appending(path: "external-copy.bin")
        try file.data.write(to: replacement)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: replacement, to: destination)
        let restarted = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: config)
        let paths = try await restarted.recoverPublishedResourcePaths(rootDirectoryPath: output.path)
        XCTAssertTrue(paths.isEmpty)
        do {
            _ = try await restarted.exportPublishedFiles([file], toRootDirectory: output.path)
            XCTFail("Identical bytes are not evidence of journal ownership")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不属于 Surge Relay 管理")) }
        XCTAssertEqual(try Data(contentsOf: destination), file.data)
    }

    func testNewResourceRenameCannotClobberUnknownFileCreatedAfterCASCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "Output")
        let file = PublishFile(name: "assets/demo.js", data: Data("const value = 1;".utf8))
        let destination = output.appending(path: file.name)
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"), resourceInterruption: {
            if $0 == .beforeRename { try file.data.write(to: destination) }
        })
        do { _ = try await store.exportPublishedFiles([file], toRootDirectory: output.path); XCTFail("Exclusive rename must reject a new unknown file") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: destination), file.data)
        let recovered = try await store.recoverPublishedResourcePaths(rootDirectoryPath: output.path)
        XCTAssertTrue(recovered.isEmpty)
    }

    func testResourceAcknowledgementCanBeInterruptedAfterManifestIsDurable() async throws {
        for phase in [PublishedResourcePhase.acknowledging, .ownershipPersisted, .journalRemoved, .acknowledged] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let output = root.appending(path: "Output")
            let config = root.appending(path: "Config")
            let cache = root.appending(path: "Cache")
            let file = PublishFile(name: "assets/demo.js", data: Data("const ready = true;".utf8))
            let store = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
            _ = try await store.exportPublishedFiles([file], toRootDirectory: output.path)
            let manifest = config.appending(path: "test-manifest.json")
            try JSONEncoder().encode([file.name]).write(to: manifest, options: .atomic)
            let interrupted = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config, resourceInterruption: {
                if $0 == phase { throw PublishedResourceCrash.interrupted }
            })
            do { try await interrupted.acknowledgePublishedResources(paths: [file.name], rootDirectoryPath: output.path); XCTFail("Expected acknowledgement interruption") }
            catch {}
            let restarted = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
            let known = try JSONDecoder().decode([String].self, from: Data(contentsOf: manifest))
            _ = try await restarted.exportPublishedFiles([file], toRootDirectory: output.path, knownManagedRelativePaths: known)
            try await restarted.acknowledgePublishedResources(paths: known, rootDirectoryPath: output.path)
            XCTAssertEqual(try Data(contentsOf: output.appending(path: file.name)), file.data)
        }
    }

    func testOwnershipReceiptSurvivesLeavingAndReturningToRootWithoutManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appending(path: "OutputA")
        let b = root.appending(path: "OutputB")
        let config = root.appending(path: "Config")
        let cache = root.appending(path: "Cache")
        let original = PublishFile(name: "assets/demo.js", data: Data("const version = 1;".utf8))
        let store = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
        _ = try await store.exportPublishedFiles([original], toRootDirectory: a.path)
        try await store.acknowledgePublishedResources(paths: [original.name], rootDirectoryPath: a.path)
        _ = try await store.exportPublishedFiles([original], toRootDirectory: b.path)
        try await store.acknowledgePublishedResources(paths: [original.name], rootDirectoryPath: b.path)
        let restarted = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
        let pending = try await restarted.recoverPublishedResourcePaths(rootDirectoryPath: a.path)
        XCTAssertTrue(pending.isEmpty, "Receipts are not pending journal claims")
        let next = PublishFile(name: original.name, data: Data("const version = 2;".utf8))
        _ = try await restarted.exportPublishedFiles([next], toRootDirectory: a.path)
        XCTAssertEqual(try Data(contentsOf: a.appending(path: next.name)), next.data)
        XCTAssertEqual(try Data(contentsOf: b.appending(path: original.name)), original.data)
        try await restarted.acknowledgePublishedResources(paths: [next.name], rootDirectoryPath: a.path)
        let replacement = root.appending(path: "external.js")
        try next.data.write(to: replacement)
        try FileManager.default.removeItem(at: a.appending(path: next.name))
        try FileManager.default.moveItem(at: replacement, to: a.appending(path: next.name))
        let externalState = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
        do {
            _ = try await externalState.exportPublishedFiles([next], toRootDirectory: a.path)
            XCTFail("A receipt must not adopt an external same-byte replacement with another inode")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不属于 Surge Relay 管理")) }
        XCTAssertEqual(try Data(contentsOf: a.appending(path: next.name)), next.data)
    }

    func testExistingResourceIsRevalidatedAtCommitCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "Output")
        let config = root.appending(path: "Config")
        let cache = root.appending(path: "Cache")
        let original = PublishFile(name: "assets/demo.js", data: Data("const version = 1;".utf8))
        let store = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
        _ = try await store.exportPublishedFiles([original], toRootDirectory: output.path)
        try await store.acknowledgePublishedResources(paths: [original.name], rootDirectoryPath: output.path)
        let destination = output.appending(path: original.name)
        let external = Data("const externalEdit = true;".utf8)
        let racing = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config, resourceInterruption: {
            if $0 == .beforeRename { try external.write(to: destination, options: .atomic) }
        })
        do {
            _ = try await racing.exportPublishedFiles([PublishFile(name: original.name, data: Data("replacement".utf8))], toRootDirectory: output.path)
            XCTFail("The final precommit check must retain the external edit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("提交前变化")) }
        XCTAssertEqual(try Data(contentsOf: destination), external)
    }

    func testBatchRevalidatesResourceOwnershipBeforeEachCoordinatedWrite() async throws {
        for replacement in [Data("original resource".utf8), Data("external edit".utf8)] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let output = root.appending(path: "Output")
            let config = root.appending(path: "Config")
            let cache = root.appending(path: "Cache")
            let original = PublishFile(name: "assets/second.js", data: Data("original resource".utf8))
            let store = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
            _ = try await store.exportPublishedFiles([original], toRootDirectory: output.path)
            try await store.acknowledgePublishedResources(paths: [original.name], rootDirectoryPath: output.path)
            let destination = output.appending(path: original.name)
            let replacementURL = root.appending(path: "external.js")
            try replacement.write(to: replacementURL)
            let racing = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config, resourceInterruption: {
                if $0 == .renamed {
                    try FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: replacementURL, to: destination)
                }
            })
            let first = PublishFile(name: "assets/first.js", data: Data("first committed resource".utf8))
            do {
                _ = try await racing.exportPublishedFiles([first, PublishFile(name: original.name, data: Data("must not replace".utf8))],
                    toRootDirectory: output.path, knownManagedRelativePaths: [original.name])
                XCTFail("A receipt verified before the first write must not authorize a later replacement")
            } catch let failure as LocalPublishPartialFailure {
                XCTAssertEqual(failure.writtenPaths, [first.name])
                XCTAssertTrue(failure.localizedDescription.contains("发布预检后变化"))
            }
            XCTAssertEqual(try Data(contentsOf: destination), replacement)
            XCTAssertEqual(try Data(contentsOf: output.appending(path: first.name)), first.data)
        }
    }

    func testResourceCommitRejectsSameByteReplacementWithNewIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "Output")
        let config = root.appending(path: "Config")
        let cache = root.appending(path: "Cache")
        let original = PublishFile(name: "assets/demo.js", data: Data("original resource".utf8))
        let store = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
        _ = try await store.exportPublishedFiles([original], toRootDirectory: output.path)
        try await store.acknowledgePublishedResources(paths: [original.name], rootDirectoryPath: output.path)
        let destination = output.appending(path: original.name)
        let replacement = root.appending(path: "external.js")
        try original.data.write(to: replacement)
        let externalInode = try FileManager.default.attributesOfItem(atPath: replacement.path)[.systemFileNumber] as? NSNumber
        let racing = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config, resourceInterruption: {
            if $0 == .beforeRename {
                try FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: replacement, to: destination)
            }
        })
        do {
            _ = try await racing.exportPublishedFiles([PublishFile(name: original.name, data: Data("must not replace".utf8))],
                toRootDirectory: output.path)
            XCTFail("The final ownership check must compare file identity as well as bytes")
        } catch { XCTAssertTrue(error.localizedDescription.contains("提交前变化")) }
        XCTAssertEqual(try Data(contentsOf: destination), original.data)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? NSNumber, externalInode)
    }

    func testCleanupCASRejectsModifiedOrNewlyAppearedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        let path = "Demo.sgmodule"
        _ = try await store.exportPublishedFiles([PublishFile(name: path, data: Data("[Rule]\nFINAL,DIRECT".utf8))], toRootDirectory: root.path)
        let before = try Data(contentsOf: root.appending(path: path))
        let changed = ManagedPublishedFile.dataWrapping(Data("[Rule]\nFINAL,REJECT".utf8), relativePath: path)
        try changed.write(to: root.appending(path: path))
        for expected in [before.sha256String, "<missing>"] {
            do {
                _ = try await store.exportPublishedFiles([], toRootDirectory: root.path, removingObsoleteRelativePaths: [path], expectedExistingHashes: [path: expected])
                XCTFail("Changed cleanup target must not be deleted")
            } catch { XCTAssertTrue(error.localizedDescription.contains("清理预览后")) }
            XCTAssertEqual(try Data(contentsOf: root.appending(path: path)), changed)
        }
        _ = try await store.exportPublishedFiles([], toRootDirectory: root.path, removingObsoleteRelativePaths: [path], expectedExistingHashes: [path: changed.sha256String])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: path).path))
    }

    func testConditionalExportRejectsChangedLocalVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        _ = try await store.exportPublishedFiles([PublishFile(name: "Demo.sgmodule", data: Data("reviewed".utf8))], toRootDirectory: root.path)
        let url = root.appending(path: "Demo.sgmodule")
        let reviewed = try Data(contentsOf: url)
        let changed = ManagedPublishedFile.dataWrapping(Data("external edit".utf8), relativePath: "Demo.sgmodule")
        try changed.write(to: url)
        do {
            _ = try await store.exportPublishedFiles([PublishFile(name: "Demo.sgmodule", data: Data("winner".utf8))], toRootDirectory: root.path, expectedExistingHashes: ["Demo.sgmodule": reviewed.sha256String])
            XCTFail("A stale confirmation must not overwrite an external edit")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("重新比较"))
        }
        XCTAssertEqual(try Data(contentsOf: url), changed)
        _ = try await store.exportPublishedFiles([PublishFile(name: "Demo.sgmodule", data: Data("winner".utf8))], toRootDirectory: root.path, expectedExistingHashes: ["Demo.sgmodule": changed.sha256String])
        XCTAssertEqual(ModuleSyncPlanner.normalizedPublishedData(try Data(contentsOf: url)), Data("winner".utf8))
    }

    func testLocalPublishedExportRemovesManifestStaleFilesOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
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

        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
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

    func testRemovePublishedFileDeletesManagedButPreservesUnmanaged() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))

        // 受管输出文件：删除
        _ = try await store.exportPublishedFiles(
            [PublishFile(name: "Folder/Managed.sgmodule", data: Data("managed".utf8))],
            toRootDirectory: root.path
        )
        try await store.removePublishedFile(
            relativePath: "Folder/Managed.sgmodule",
            rootDirectoryPath: root.path
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Folder/Managed.sgmodule").path))

        // 非受管用户源文件：调用会抛错且文件保留
        let userFile = root.appending(path: "User.sgmodule")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!name=User\n[Rule]\nFINAL,DIRECT\n".utf8).write(to: userFile)
        do {
            try await store.removePublishedFile(relativePath: "User.sgmodule", rootDirectoryPath: root.path)
            XCTFail("不应删除非受管文件")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("不属于 Surge Relay 管理"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
    }

    func testRemovePublishedFileForcingDeletesUnmanagedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let userFile = root.appending(path: "SelfAuthored.sgmodule")
        try Data("#!name=SelfAuthored\n[Rule]\nFINAL,DIRECT\n".utf8).write(to: userFile)

        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        try await store.removePublishedFileForcing(
            relativePath: "SelfAuthored.sgmodule",
            rootDirectoryPath: root.path
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: userFile.path))
    }

    func testLocalPublishedExportMigratesKnownLegacyManagedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appending(path: "Legacy.sgmodule")
        try Data("#!name=Legacy\n[Rule]\nFINAL,DIRECT\n".utf8).write(to: destination)

        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
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

        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
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

        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
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
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        try FileManager.default.createDirectory(
            at: root.appending(path: "assets/custom", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try ManagedPublishedFile.dataWrapping(Data("combined".utf8), relativePath: "Surge-Relay.sgmodule")
            .write(to: root.appending(path: "Surge-Relay.sgmodule"))
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

    func testLegacyCleanupPreservesUnmarkedAndCopiedModuleFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let personal = Data("#!name=My Relay\n[Rule]\nFINAL,DIRECT".utf8)
        let copied = ManagedPublishedFile.dataWrapping(Data("copied".utf8), relativePath: "Different.sgmodule")
        try personal.write(to: root.appending(path: "Surge-Relay.sgmodule"))
        try copied.write(to: root.appending(path: "Script-Hub-Relay.sgmodule"))
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        let removed = try await store.removeLegacyPublishedFiles(in: root.path,
            relativePaths: ["Surge-Relay.sgmodule", "Script-Hub-Relay.sgmodule"])
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "Surge-Relay.sgmodule")), personal)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "Script-Hub-Relay.sgmodule")), copied)
    }

    func testGeneratedAssetFilesCanBeFilteredByModuleID() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let includedID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let excludedID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
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

private enum PublishedResourceCrash: Error { case interrupted }

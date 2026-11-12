import Foundation
import Observation
import XCTest
@testable import SurgeRelay

@MainActor
final class ClientStorageRoutingTests: XCTestCase {
    func testSameRootClientChangeProtectsCurrentOutputFromPreviousClientCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        let shared = root.appending(path: "Shared")
        configure(.surge, root: shared, model: model)
        configure(.egern, root: shared, model: model)
        let original = module("Foo", format: .surge)
        model.modules = [original]
        try await model.fileStore.writeComponent(content(for: .surge), id: original.id)
        let initial = await model.refreshModuleOutputs(schedulesAutomaticPublish: false)
        XCTAssertTrue(initial)
        var draft = ModuleDraft(module: original)
        draft.outputFormat = .egern
        try model.updateModule(id: original.id, from: draft)
        let current = try XCTUnwrap(model.modules.first)
        let converted = try await model.scriptHubClient.convert(module: current, sourceData: Data(content(for: .egern).utf8))
        try await model.fileStore.commitConversion(converted, id: current.id)
        model.modules[0].lastConvertedOutputFormat = .egern
        let updated = await model.refreshModuleOutputs(schedulesAutomaticPublish: false)
        XCTAssertTrue(updated)
        XCTAssertEqual(model.modules[0].publishedRelativePath, original.publishedRelativePath)
        XCTAssertTrue(model.settings.localStorage(for: .surge).publishedFilePaths.contains("Foo.sgmodule"))
        XCTAssertTrue(model.settings.localStorage(for: .egern).publishedFilePaths.contains("Foo.sgmodule"))
        let asset = "assets/\(original.id.uuidString.lowercased())/converted.js"
        var previousStorage = model.settings.localStorage(for: .surge)
        previousStorage.publishedFilePaths.append(asset)
        model.settings.setLocalStorage(previousStorage, for: .surge)
        let protection = model.localProtectedSourcePaths(targetDirectory: shared.path, outputFormat: .surge)
        XCTAssertTrue(protection.contains("Foo.sgmodule"))
        XCTAssertTrue(protection.contains(asset))
        XCTAssertFalse(model.localProtectedSourcePaths(targetDirectory: shared.path, outputFormat: .egern).contains("Foo.sgmodule"))
        let plan = LocalPublishedFilesPlanner.plan(files: [], targetDirectory: shared.path,
            previousRootDirectory: previousStorage.publishedRootDirectory, previousPublishedPaths: previousStorage.publishedFilePaths,
            protectedSourcePaths: protection)
        XCTAssertTrue(plan.stalePaths.isEmpty)
        let output = shared.appending(path: "Foo.sgmodule")
        let bytes = try Data(contentsOf: output)
        model.pendingPublishPreview = PublishPreview(destination: .local, targetDescription: shared.path,
            activeFiles: [], changedFiles: [], deletedFiles: ["Foo.sgmodule"],
            localExpectedHashes: ["Foo.sgmodule": bytes.sha256String],
            localReviewFingerprint: model.localCleanupReviewFingerprint(outputFormat: .surge), localOutputFormat: .surge)
        await model.confirmPendingPublish()
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertTrue(model.settings.localStorage(for: .surge).publishedFilePaths.contains("Foo.sgmodule"))
    }

    func testSameRootCleanupUsesPreviewClientInsteadOfFirstMatchingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        let shared = root.appending(path: "Shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        for (format, path) in [(ModuleOutputFormat.surge, "Surge-old.sgmodule"), (.egern, "Egern-old.sgmodule")] {
            configure(format, root: shared, model: model)
            var storage = model.settings.localStorage(for: format)
            storage.publishedRootDirectory = shared.path
            storage.publishedFilePaths = [path]
            model.settings.setLocalStorage(storage, for: format)
            try ManagedPublishedFile.dataWrapping(Data(content(for: format).utf8), relativePath: path)
                .write(to: shared.appending(path: path))
        }
        let storage = model.settings.localStorage(for: .egern)
        let plan = LocalPublishedFilesPlanner.plan(files: [], targetDirectory: shared.path,
            previousRootDirectory: storage.publishedRootDirectory, previousPublishedPaths: storage.publishedFilePaths)
        var preview = plan.cleanupPreview(outputFormat: .egern)
        let bytes = try Data(contentsOf: shared.appending(path: "Egern-old.sgmodule"))
        preview.localExpectedHashes = ["Egern-old.sgmodule": bytes.sha256String]
        preview.localReviewFingerprint = model.localCleanupReviewFingerprint(outputFormat: .egern)
        model.pendingPublishPreview = preview
        await model.confirmPendingPublish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appending(path: "Egern-old.sgmodule").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appending(path: "Surge-old.sgmodule").path))
        XCTAssertEqual(model.settings.localStorage(for: .surge).publishedFilePaths, ["Surge-old.sgmodule"])
        XCTAssertTrue(model.settings.localStorage(for: .egern).publishedFilePaths.isEmpty)
    }

    func testIndependentClientOutputsUseTheirOwnRootsAndManifests() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        configure(.surge, root: root.appending(path: "Surge"), model: model)
        configure(.egern, root: root.appending(path: "Egern"), model: model)
        configure(.loon, root: root.appending(path: "Loon"), model: model, enabled: false)
        let modules = [module("Surge", format: .surge), module("Egern", format: .egern), module("Loon", format: .loon)]
        model.modules = modules
        for item in modules { try await model.fileStore.writeComponent(content(for: item.outputFormat), id: item.id) }
        let result = await model.refreshModuleOutputs(schedulesAutomaticPublish: false)
        XCTAssertTrue(result)
        for item in modules.prefix(2) {
            let directory = root.appending(path: item.outputFormat.title)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: item.publishedRelativePath).path))
            XCTAssertEqual(model.settings.localStorage(for: item.outputFormat).publishedFilePaths, [item.publishedRelativePath])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Loon/Loon.plugin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Surge/Egern.sgmodule").path))
        XCTAssertEqual(model.settings.localPublishedFilePaths, ["Surge.sgmodule"])
        XCTAssertTrue(model.settings.localStorage(for: .loon).publishedFilePaths.isEmpty)
        XCTAssertNil(model.modules[2].localOutputError)
    }

    func testMixedClientWebReviewWritesBothRootsAndRejectsChangedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        configure(.surge, root: root.appending(path: "Surge"), model: model)
        configure(.loon, root: root.appending(path: "Loon"), model: model)
        model.modules = [module("Surge", format: .surge), module("Loon", format: .loon)]
        for item in model.modules { try await model.fileStore.writeComponent(content(for: item.outputFormat), id: item.id) }
        let ids = Set(model.modules.map(\.id))
        let preview = try await model.webPublishPreview(WebPublishPreviewRequest(moduleIDs: ids))
        XCTAssertEqual(Set(preview.previews.map(\.targetDescription)), [root.appending(path: "Surge").path, root.appending(path: "Loon").path])
        let published = try await model.confirmWebPublish(token: preview.token)
        XCTAssertTrue(published.ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Surge/Surge.sgmodule").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Loon/Loon.plugin").path))
        let stale = try await model.webPublishPreview(WebPublishPreviewRequest(moduleIDs: ids))
        var storage = model.settings.localStorage(for: .loon)
        storage.directory = root.appending(path: "Changed").path
        model.settings.setLocalStorage(storage, for: .loon)
        do {
            _ = try await model.confirmWebPublish(token: stale.token)
            XCTFail("A review for the old client directory must expire")
        } catch { XCTAssertEqual(error as? PreviewContentSaveError, .changed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Changed/Loon.plugin").path))
    }

    func testClientDirectoryChangeDoesNotTransferOldOverwriteAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        let first = root.appending(path: "Old")
        let next = root.appending(path: "New")
        configure(.egern, root: first, model: model)
        let item = module("Egern", format: .egern)
        model.modules = [item]
        try await model.fileStore.writeComponent(content(for: .egern), id: item.id)
        let initial = await model.refreshModuleOutputs(schedulesAutomaticPublish: false)
        XCTAssertTrue(initial)
        let oldBytes = try Data(contentsOf: first.appending(path: item.publishedRelativePath))
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        let personal = Data("#!name=Personal\n[Rule]\nFINAL,REJECT\n".utf8)
        try personal.write(to: next.appending(path: item.publishedRelativePath))
        var storage = model.settings.localStorage(for: .egern)
        storage.directory = next.path
        model.settings.setLocalStorage(storage, for: .egern)
        let changed = await model.refreshModuleOutputs(schedulesAutomaticPublish: false)
        XCTAssertFalse(changed)
        XCTAssertEqual(try Data(contentsOf: first.appending(path: item.publishedRelativePath)), oldBytes)
        XCTAssertEqual(try Data(contentsOf: next.appending(path: item.publishedRelativePath)), personal)
        XCTAssertEqual(model.settings.localStorage(for: .egern).publishedRootDirectory, first.path)
    }

    func testARegisteredSourceInsideAnotherClientRootRemainsProtected() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        let surge = root.appending(path: "Surge")
        configure(.surge, root: surge, model: model)
        configure(.loon, root: root.appending(path: "Loon"), model: model)
        try FileManager.default.createDirectory(at: surge, withIntermediateDirectories: true)
        let source = surge.appending(path: "Personal.sgmodule")
        let bytes = ManagedPublishedFile.dataWrapping(Data("#!name=Personal\n[Rule]\nFINAL,DIRECT\n".utf8), relativePath: "Personal.sgmodule")
        try bytes.write(to: source)
        var storage = model.settings.localStorage(for: .surge)
        storage.publishedRootDirectory = surge.path
        storage.publishedFilePaths = ["Personal.sgmodule"]
        model.settings.setLocalStorage(storage, for: .surge)
        let item = RelayModule(name: "Loon", sourceURL: source.absoluteString, sourceFormat: .surge, outputFormat: .loon,
            outputFileName: "Loon.plugin", storageLocation: .local)
        model.modules = [item]
        XCTAssertTrue(model.localProtectedSourcePaths(targetDirectory: surge.path).contains("Personal.sgmodule"))
        do {
            try await model.publishSelectedLocalFiles([PublishFile(name: "Personal.sgmodule", data: Data("#!name=Replacement\n[Rule]\nFINAL,REJECT\n".utf8))], outputFormat: .surge)
            XCTFail("Publishing cannot replace another client's registered physical source")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testSharedRootScanOffersEachPhysicalModuleOnceAndUsesSubscriptionTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        let shared = root.appending(path: "Shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        for format in [ModuleOutputFormat.surge, .egern, .shadowrocket] {
            configure(format, root: shared, model: model)
        }
        try Data(content(for: .surge).utf8).write(to: shared.appending(path: "Personal.sgmodule"))
        let subscribed = """
        #!name=Shadowrocket
        #SUBSCRIBED http://script.hub/file/_start_/https://example.com/original.sgmodule/_end_/Subscribed.sgmodule?type=surge-module&target=shadowrocket-module
        [Rule]
        FINAL,DIRECT
        """
        try Data(subscribed.utf8).write(to: shared.appending(path: "Subscribed.sgmodule"))

        let report = try await model.scanExistingLocalModules()
        XCTAssertEqual(report.candidates.count, 2)
        XCTAssertEqual(report.candidates.first { $0.relativePath == "Personal.sgmodule" }?.outputFormat, .surge)
        XCTAssertEqual(report.candidates.first { $0.relativePath == "Subscribed.sgmodule" }?.outputFormat, .shadowrocket)
        await model.importLocalModules(report.candidates)
        XCTAssertNil(model.presentedError)
        XCTAssertEqual(model.modules.count, 2)
        XCTAssertEqual(Set(model.modules.map(\.outputFormat)), [.surge, .shadowrocket])
        let repeated = try await model.scanExistingLocalModules()
        XCTAssertTrue(repeated.candidates.isEmpty)
    }

    func testNestedClientRootRegistrationExcludesParentCandidateAndRejectsStaleImport() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        let surge = root.appending(path: "Surge")
        let egern = surge.appending(path: "Egern")
        configure(.surge, root: surge, model: model)
        configure(.egern, root: egern, model: model)
        try FileManager.default.createDirectory(at: egern, withIntermediateDirectories: true)
        let source = egern.appending(path: "Demo.sgmodule")
        let bytes = Data("""
        #!name=Subscribed
        #SUBSCRIBED http://script.hub/file/_start_/https://example.com/original.sgmodule/_end_/Demo.sgmodule?type=surge-module&target=surge-module
        [Rule]
        FINAL,DIRECT
        """.utf8)
        try bytes.write(to: source)
        let initial = try await model.scanExistingLocalModules()
        let stale = try XCTUnwrap(initial.candidates.first { $0.outputFormat == .surge })
        XCTAssertEqual(stale.relativePath, "Egern/Demo.sgmodule")
        let child = try XCTUnwrap(LocalModuleScanner.report(in: egern.path, existingModules: [],
            publishedFilePaths: [], outputFormat: .egern).candidates.first)

        await model.importLocalModules([child])
        XCTAssertNil(model.presentedError)
        let registered = try XCTUnwrap(model.modules.first)
        XCTAssertEqual(model.modules.count, 1)
        XCTAssertEqual(registered.outputFormat, .egern)
        XCTAssertEqual(registered.sourceURL, "https://example.com/original.sgmodule")
        let repeated = try await model.scanExistingLocalModules()
        XCTAssertTrue(repeated.candidates.isEmpty)
        await model.importLocalModules([stale])
        XCTAssertEqual(model.modules.map(\.id), [registered.id])
        XCTAssertTrue(model.presentedError?.contains("本地模块路径已纳入管理") == true)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testIndependentSurgeFamilyRootsKeepSameNamedFilesForEachClient() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        for format in [ModuleOutputFormat.surge, .egern, .shadowrocket] {
            let directory = root.appending(path: format.rawValue)
            configure(format, root: directory, model: model)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(content(for: format).utf8).write(to: directory.appending(path: "Demo.sgmodule"))
        }

        let report = try await model.scanExistingLocalModules()
        XCTAssertEqual(report.candidates.count, 3)
        XCTAssertEqual(Set(report.candidates.map(\.outputFormat)), [.surge, .egern, .shadowrocket])
        XCTAssertEqual(Set(report.candidates.map(\.id)).count, 3)
        XCTAssertTrue(report.candidates.allSatisfy {
            $0.relativePath == "Demo.sgmodule" && $0.rootDirectoryPath
                == LocalSourcePathResolver.canonicalDirectoryURL(for: model.settings.localModuleDirectory(for: $0.outputFormat))?.path
        })
    }

    func testBackgroundLocalScanPreservesStatusAndWorkActivity() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        let directory = root.appending(path: "Surge")
        configure(.surge, root: directory, model: model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(content(for: .surge).utf8).write(to: directory.appending(path: "Demo.sgmodule"))
        model.statusMessage = "已保存模块"
        withObservationTracking {
            _ = model.statusMessage
            _ = model.isWorking
            _ = model.workActivity
        } onChange: {
            XCTFail("Background scanning must preserve the displayed status and work activity")
        }

        let report = try await model.scanExistingLocalModules(reportsProgress: false)
        XCTAssertEqual(report.candidates.map(\.relativePath), ["Demo.sgmodule"])
        XCTAssertEqual(model.statusMessage, "已保存模块")
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.workActivity.kind, .idle)
    }

    func testConfiguredSurgeFamilyRootsDetermineScanTargetAndFolderCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        for (format, name) in [(ModuleOutputFormat.surge, "Surge"), (.egern, "Egern")] {
            let directory = root.appending(path: name)
            configure(format, root: directory, model: model)
            try FileManager.default.createDirectory(at: directory.appending(path: name + "Folder"), withIntermediateDirectories: true)
            try Data(content(for: format).utf8).write(to: directory.appending(path: name + ".sgmodule"))
        }
        let report = try await model.scanExistingLocalModules()
        XCTAssertEqual(Set(report.candidates.map(\.outputFormat)), [.surge, .egern])
        XCTAssertEqual(Set(report.candidates.map(\.id)).count, 2)
        await model.importLocalModules(report.candidates)
        XCTAssertEqual(Set(model.modules.map(\.outputFormat)), [.surge, .egern])
        await model.refreshModuleOutputFolders(force: true)
        XCTAssertTrue(model.moduleOutputFolderOptions(storageLocation: .local, outputFormat: .egern).contains("EgernFolder"))
        XCTAssertFalse(model.moduleOutputFolderOptions(storageLocation: .local, outputFormat: .egern).contains("SurgeFolder"))
        XCTAssertTrue(model.moduleOutputFolderOptions(storageLocation: .local, outputFormat: .surge).contains("SurgeFolder"))
    }

    private func model(root: URL) -> AppModel {
        let context = WorkspaceContext(id: UUID(), name: "Client routing", configurationDirectory: root.appending(path: "Config"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        model.settings.automaticallyPublish = false
        model.settings.watchesLocalModuleChanges = false
        model.settings.refreshIntervalMinutes = 0
        return model
    }

    private func configure(_ format: ModuleOutputFormat, root: URL, model: AppModel, enabled: Bool = true) {
        model.settings.setLocalStorage(ClientLocalStorage(isEnabled: enabled, directory: root.path), for: format)
    }

    private func module(_ name: String, format: ModuleOutputFormat) -> RelayModule {
        RelayModule(name: name, sourceURL: "https://example.org/\(name).sgmodule", outputFormat: format,
            lastConvertedOutputFormat: format, outputFileName: name, storageLocation: .local)
    }

    private func content(for format: ModuleOutputFormat) -> String {
        format == .loon ? "#!name=Loon\n[Rewrite]\n^https://example.org - reject\n" : "#!name=Surge\n[Rule]\nFINAL,DIRECT\n"
    }
}

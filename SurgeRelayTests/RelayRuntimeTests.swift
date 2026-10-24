import Foundation
import XCTest
@testable import SurgeRelay

@MainActor
final class RelayRuntimeTests: XCTestCase {
    func testMovingModuleWritesNewOutputThenRemovesOnlyItsPreviousFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = pendingSaveModel(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        model.settings.localModuleDirectory = root.appending(path: "Modules").path
        model.settings.publishToLocal = true
        let module = RelayModule(name: "Move", sourceURL: "https://example.com/move.sgmodule", outputFileName: "Move.sgmodule",
            outputFolder: "Old", storageLocation: .local, localStorageRelativePath: "Old/Move.sgmodule")
        let other = RelayModule(name: "Other", sourceURL: "https://example.com/other.sgmodule", outputFileName: "Other.sgmodule", storageLocation: .local)
        model.modules = [module, other]
        for item in model.modules { try await model.fileStore.writeComponent("#!name=\(item.name)\n[Rule]\nFINAL,DIRECT", id: item.id) }
        let initial = await model.refreshModuleOutputs(schedulesAutomaticPublish: false)
        XCTAssertTrue(initial)
        let otherURL = URL(filePath: model.settings.localModuleDirectory).appending(path: "Other.sgmodule")
        let otherData = try Data(contentsOf: otherURL)
        var draft = ModuleDraft(module: module)
        draft.outputFolder = "New"
        draft.category = "New label"
        try await model.enqueueModuleSave(moduleID: module.id, draft: draft)
        await model.pendingModuleSaveTask?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Modules/Old/Move.sgmodule").path))
        let output = try String(contentsOf: root.appending(path: "Modules/New/Move.sgmodule"), encoding: .utf8)
        XCTAssertTrue(output.contains("#!category=New label"))
        XCTAssertTrue(output.contains("# surge-relay-relative-path: New/Move.sgmodule"))
        XCTAssertEqual(try Data(contentsOf: otherURL), otherData)
        XCTAssertEqual(Set(model.settings.localPublishedFilePaths), ["New/Move.sgmodule", "Other.sgmodule"])
        XCTAssertTrue(model.modules[0].pendingLocalOutputRetirements.isEmpty)
        let again = await model.refreshModuleOutputs(moduleIDs: [module.id], schedulesAutomaticPublish: false)
        XCTAssertTrue(again)
    }

    func testMoveKeepsOldFileIfNewOutputFailsAndResumesCleanupAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = pendingSaveModel(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        model.settings.localModuleDirectory = root.appending(path: "Modules").path
        model.settings.publishToLocal = true
        let module = RelayModule(name: "Move", sourceURL: "https://example.com/move.sgmodule", outputFileName: "Move.sgmodule",
            outputFolder: "Old", storageLocation: .local)
        model.modules = [module]
        try await model.fileStore.writeComponent("#!name=Move\n[Rule]\nFINAL,DIRECT", id: module.id)
        _ = await model.refreshModuleOutputs(schedulesAutomaticPublish: false)
        let oldURL = root.appending(path: "Modules/Old/Move.sgmodule")
        let oldData = try Data(contentsOf: oldURL)
        let newURL = root.appending(path: "Modules/New/Move.sgmodule")
        try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unrelated = Data("#!name=Personal\n[Rule]\nFINAL,REJECT".utf8)
        try unrelated.write(to: newURL)
        var draft = ModuleDraft(module: module)
        draft.outputFolder = "New"
        try await model.enqueueModuleSave(moduleID: module.id, draft: draft)
        await model.pendingModuleSaveTask?.value
        XCTAssertEqual(try Data(contentsOf: oldURL), oldData)
        XCTAssertEqual(try Data(contentsOf: newURL), unrelated)
        XCTAssertEqual(model.modules[0].pendingLocalOutputRetirements.count, 1)
        XCTAssertNotNil(model.modules[0].localOutputError)
        try await model.flushPersistence()
        try FileManager.default.removeItem(at: newURL)
        let reopened = pendingSaveModel(root: root)
        defer { reopened.persistenceFeedbackTask?.cancel() }
        reopened.settings.localModuleDirectory = model.settings.localModuleDirectory
        reopened.settings.publishToLocal = true
        let retried = await reopened.refreshModuleOutputs(schedulesAutomaticPublish: false)
        XCTAssertTrue(retried)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(reopened.modules[0].pendingLocalOutputRetirements.isEmpty)
    }

    func testMoveDoesNotDeleteOldFileChangedAfterMoveWasRequested() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = pendingSaveModel(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        model.settings.localModuleDirectory = root.appending(path: "Modules").path
        model.settings.publishToLocal = true
        let module = RelayModule(name: "Move", sourceURL: "https://example.com/move.sgmodule", outputFileName: "Move.sgmodule", outputFolder: "Old", storageLocation: .local)
        model.modules = [module]
        try await model.fileStore.writeComponent("[Rule]\nFINAL,DIRECT", id: module.id)
        _ = await model.refreshModuleOutputs(schedulesAutomaticPublish: false)
        let oldURL = root.appending(path: "Modules/Old/Move.sgmodule")
        var draft = ModuleDraft(module: module)
        draft.outputFolder = "New"
        try model.updateModule(id: module.id, from: draft)
        let edited = Data("#!name=External\n[Rule]\nFINAL,REJECT".utf8)
        try edited.write(to: oldURL)
        let result = await model.refreshModuleOutputs(schedulesAutomaticPublish: false)
        XCTAssertFalse(result)
        XCTAssertEqual(try Data(contentsOf: oldURL), edited)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Modules/New/Move.sgmodule").path))
        XCTAssertTrue(model.modules[0].localOutputError?.contains("已保留") == true)
    }

    func testRepeatedMovesAndLabelOnlyEditsKeepOneOutputAndStayWithinRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = pendingSaveModel(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        let modulesRoot = root.appending(path: "Modules")
        model.settings.localModuleDirectory = modulesRoot.path
        model.settings.publishToLocal = true
        let module = RelayModule(name: "Move", sourceURL: "https://example.com/move.sgmodule", outputFileName: "Move.sgmodule", outputFolder: "A", storageLocation: .local)
        model.modules = [module]
        try await model.fileStore.writeComponent("#!name=Move\n[Rule]\nFINAL,DIRECT", id: module.id)
        _ = await model.refreshModuleOutputs(schedulesAutomaticPublish: false)
        var draft = ModuleDraft(module: module)
        draft.category = "Changed label"
        try await model.enqueueModuleSave(moduleID: module.id, draft: draft)
        await model.pendingModuleSaveTask?.value
        XCTAssertTrue(model.modules[0].pendingLocalOutputRetirements.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modulesRoot.appending(path: "A/Move.sgmodule").path))
        for folder in ["B", "C"] {
            var move = ModuleDraft(module: model.modules[0])
            move.outputFolder = folder
            try await model.enqueueModuleSave(moduleID: module.id, draft: move)
            await model.pendingModuleSaveTask?.value
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: modulesRoot.appending(path: "A/Move.sgmodule").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: modulesRoot.appending(path: "B/Move.sgmodule").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: modulesRoot.appending(path: "C/Move.sgmodule").path))
        XCTAssertEqual(model.settings.localPublishedFilePaths, ["C/Move.sgmodule"])
        model.modules[0].pendingLocalOutputRetirements = [LocalOutputRetirement(rootDirectory: modulesRoot.path,
            relativePath: "C/Move.sgmodule", contentHash: nil)]
        model.settings.localModuleDirectory = root.appending(path: "OtherRoot").path
        var newRootDraft = ModuleDraft(module: model.modules[0])
        newRootDraft.outputFolder = "New"
        try await model.enqueueModuleSave(moduleID: module.id, draft: newRootDraft)
        await model.pendingModuleSaveTask?.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: modulesRoot.appending(path: "C/Move.sgmodule").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "OtherRoot/New/Move.sgmodule").path))
    }

    func testUpdateCleansLegacyDuplicateOnlyWhenSubscriptionAndFilenameMatch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = pendingSaveModel(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        model.settings.localModuleDirectory = root.appending(path: "Modules").path
        model.settings.publishToLocal = true
        let module = RelayModule(name: "Move", sourceURL: "https://example.com/move.sgmodule", outputFileName: "Move.sgmodule", outputFolder: "New", storageLocation: .local)
        model.modules = [module]
        let subscribed = "#!name=Move\n#SUBSCRIBED http://script.hub/file/_start_/https://example.com/move.sgmodule/_end_/Move.sgmodule?type=surge-module&target=surge-module\n[Rule]\nFINAL,DIRECT\n"
        let otherSource = subscribed.replacingOccurrences(of: "example.com/move.sgmodule", with: "example.com/other.sgmodule")
        let oldPath = "Old/Move.sgmodule"
        let unrelatedPath = "Unrelated/Move.sgmodule"
        _ = try await model.fileStore.exportPublishedFiles([PublishFile(name: oldPath, data: Data(subscribed.utf8)),
            PublishFile(name: unrelatedPath, data: Data(otherSource.utf8))], toRootDirectory: model.settings.localModuleDirectory)
        model.settings.localPublishedRootDirectory = model.settings.localModuleDirectory
        model.settings.localPublishedFilePaths = [oldPath, unrelatedPath]
        try await model.fileStore.writeComponent(subscribed, id: module.id)
        XCTAssertTrue(model.modules[0].pendingLocalOutputRetirements.isEmpty)
        let success = await model.refreshModuleOutputs(schedulesAutomaticPublish: false)
        XCTAssertTrue(success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Modules/Old/Move.sgmodule").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Modules/New/Move.sgmodule").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Modules/Unrelated/Move.sgmodule").path))
        XCTAssertEqual(Set(model.settings.localPublishedFilePaths), ["New/Move.sgmodule", unrelatedPath])
    }

    func testModuleParametersRemainConfigurableThroughPreviewEditingPublishResetAndUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Native arguments", configurationDirectory: root.appending(path: "Config"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        defer { model.persistenceFeedbackTask?.cancel() }
        model.settings.localModuleDirectory = root.appending(path: "Modules").path
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        model.settings.automaticallyPublish = false
        model.settings.watchesLocalModuleChanges = false
        let module = RelayModule(name: "iRingo.WeatherKit", sourceURL: "https://example.com/weather.sgmodule", sourceFormat: .surge,
            outputFileName: "iRingo.WeatherKit.sgmodule", storageTargets: [.local, .gitHub])
        model.modules = [module]
        let source = #"""
        #!name=iRingo.WeatherKit
        #!arguments=DataSets:"airQuality,currentWeather",Weather.Provider:"ColorfulClouds",API.Token:""
        #!arguments-desc=DataSets: 数据集\nWeather.Provider: 数据源
        [Script]
        Weather = type=http-response, script-path=https://example.com/weather.js, argument=DataSets="{{{DataSets}}}"&Weather.Provider="{{{Weather.Provider}}}"&Token="{{{API.Token}}}"
        """# + "\n"
        try await model.fileStore.writeComponent(source, id: module.id)
        let info = await model.moduleArgumentInfo(for: module)
        XCTAssertEqual(info.definitions.count, 3)
        XCTAssertEqual(info.definitions[0].defaultValue, "airQuality,currentWeather")

        model.setModuleArgument(moduleID: module.id, key: "Weather.Provider", value: "QWeather", defaultValue: "ColorfulClouds")
        let outputPath = root.appending(path: "Modules/iRingo.WeatherKit.sgmodule")
        for _ in 0..<100 {
            if let output = try? String(contentsOf: outputPath, encoding: .utf8), output.contains("Weather.Provider:\"QWeather\"") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let published = try String(contentsOf: outputPath, encoding: .utf8)
        XCTAssertTrue(published.contains("Weather.Provider:\"QWeather\""))
        XCTAssertTrue(published.contains("#!arguments-desc="))
        XCTAssertTrue(published.contains("{{{Weather.Provider}}}"))
        let githubFiles = try await model.publishedFiles(
            plan: PublishCoordinator.selectedPlan(modules: model.modules, moduleIDs: [module.id], destination: .gitHub),
            includeAssets: false, destination: .gitHub
        )
        let githubContent = String(decoding: try XCTUnwrap(githubFiles.first?.data), as: UTF8.self)
        XCTAssertTrue(githubContent.contains("Weather.Provider:\"QWeather\""))
        XCTAssertTrue(githubContent.contains("{{{Weather.Provider}}}"))

        let current = try XCTUnwrap(model.modules.first)
        let preview = try await model.previewContent(for: current)
        XCTAssertTrue(preview.contains("#!arguments=DataSets:"))
        XCTAssertTrue(preview.contains("Weather.Provider:\"ColorfulClouds\""))
        XCTAssertTrue(preview.contains("{{{DataSets}}}"))
        _ = try await model.savePreviewContent(preview + "# Edited source note\n", for: current)
        model.resetModuleArguments(moduleID: module.id)
        let restored = await model.refreshModuleOutputs(moduleIDs: [module.id], schedulesAutomaticPublish: false)
        XCTAssertTrue(restored)
        let reset = try String(contentsOf: outputPath, encoding: .utf8)
        XCTAssertTrue(reset.contains("Weather.Provider:\"ColorfulClouds\""))
        XCTAssertTrue(reset.contains("{{{Weather.Provider}}}"))
        XCTAssertTrue(reset.contains("# Edited source note"))
        try await model.flushPersistence()
        XCTAssertTrue(PersistenceStore.loadModules(in: context.configurationDirectory, allowLegacyFallback: false)[0].argumentOverrides.isEmpty)
    }

    private func pendingSaveModel(root: URL) -> AppModel {
        let context = WorkspaceContext(id: UUID(), name: "Pending saves",
            configurationDirectory: root.appending(path: "Config"), cacheDirectory: root.appending(path: "Cache"),
            allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = false
        model.settings.automaticallyPublish = false
        model.settings.watchesLocalModuleChanges = false
        model.settings.refreshIntervalMinutes = 0
        return model
    }

    func testManagedOutputRelocationRepairsStaleMarkerAfterPathChange() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Relocated output", configurationDirectory: root.appending(path: "Config"), cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        defer { model.persistenceFeedbackTask?.cancel() }
        model.settings.localModuleDirectory = root.path
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        let old = "Sgmodule(#1苹果服务)/Reddit-去广告.sgmodule"
        let current = "Sgmodule(#3广告模块)/Reddit-去广告.sgmodule"
        let module = RelayModule(name: "Reddit 去广告", sourceURL: "https://example.com/reddit.sgmodule", outputFileName: "Reddit-去广告.sgmodule", outputFolder: "Sgmodule(#3广告模块)", storageLocation: .local, localStorageRelativePath: current)
        model.modules = [module]
        let destination = root.appending(path: current)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldManaged = ManagedPublishedFile.dataWrapping(Data("#!name=Reddit 去广告\n#SUBSCRIBED http://script.hub/file/_start_/https://example.com/reddit.sgmodule/_end_/Reddit-去广告.sgmodule?type=surge-module&target=surge-module&del=true&jqEnabled=true&noNtf=true\n[Rule]\nDOMAIN,reddit.example,DIRECT\n".utf8), relativePath: old)
        try oldManaged.write(to: destination)
        model.settings.localPublishedRootDirectory = root.path
        model.settings.localPublishedFilePaths = [old]
        let knownPlan = LocalPublishedFilesPlanner.plan(files: [PublishFile(name: current, data: Data())], targetDirectory: root.path,
            previousRootDirectory: root.path, previousPublishedPaths: [old])
        XCTAssertEqual(knownPlan.knownManagedPaths, [old])
        try await model.fileStore.writeComponent("#!name=Reddit 去广告\n[Rule]\nDOMAIN,reddit.example,REJECT\n", id: module.id)
        let succeeded = await model.refreshModuleOutputs(moduleIDs: [module.id], schedulesAutomaticPublish: false)
        XCTAssertTrue(succeeded, model.modules[0].localOutputError ?? model.statusMessage)
        XCTAssertNil(model.modules[0].localOutputError, model.modules[0].localOutputError ?? "")
        let content = try Data(contentsOf: destination)
        XCTAssertTrue(ManagedPublishedFile.isManaged(content, relativePath: current), String(decoding: content, as: UTF8.self))
        XCTAssertFalse(ManagedPublishedFile.isManaged(content, relativePath: old), String(decoding: content, as: UTF8.self))
        let backups = try XCTUnwrap(FileManager.default.enumerator(at: context.configurationDirectory.appending(path: "Backups/LocalOutputAdoption"), includingPropertiesForKeys: nil)).allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "sgmodule" }
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(String(decoding: try Data(contentsOf: XCTUnwrap(backups.first)), as: UTF8.self).contains("reddit.example,DIRECT"))
    }

    func testRelocationDoesNotAutomaticallyClaimAnotherSourceAndCanBeConfirmed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = pendingSaveModel(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        model.settings.localModuleDirectory = root.appending(path: "Modules").path
        model.settings.publishToLocal = true
        let old = "Old/Reddit.sgmodule"
        let path = "Correct/Reddit.sgmodule"
        let module = RelayModule(name: "Reddit", sourceURL: "https://example.com/reddit.sgmodule", outputFileName: "Reddit.sgmodule", outputFolder: "Correct", storageLocation: .local, localStorageRelativePath: path)
        model.modules = [module]
        let rootURL = URL(filePath: model.settings.localModuleDirectory)
        let destination = rootURL.appending(path: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = ManagedPublishedFile.dataWrapping(Data("#!name=Unrelated\n#SUBSCRIBED http://script.hub/file/_start_/https://example.com/other.sgmodule/_end_/Reddit.sgmodule?type=surge-module&target=surge-module\n[Rule]\nFINAL,DIRECT\n".utf8), relativePath: old)
        try original.write(to: destination)
        model.settings.localPublishedRootDirectory = rootURL.path
        model.settings.localPublishedFilePaths = [old]
        try await model.fileStore.writeComponent("#!name=Reddit\n[Rule]\nDOMAIN,reddit.example,REJECT\n", id: module.id)
        let succeeded = await model.refreshModuleOutputs(moduleIDs: [module.id], schedulesAutomaticPublish: false)
        XCTAssertFalse(succeeded)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Config/Backups/LocalOutputAdoption").path))
        let review = try await model.prepareLocalOutputAdoption(moduleID: module.id)
        try await model.confirmLocalOutputAdoption(review)
        XCTAssertTrue(ManagedPublishedFile.isManaged(try Data(contentsOf: destination), relativePath: path))
        XCTAssertNil(model.modules[0].localOutputError)
    }

    func testDeletedOldOutputIsNotRecreatedAfterChangingFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = pendingSaveModel(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        model.settings.localModuleDirectory = root.appending(path: "Modules").path
        model.settings.publishToLocal = true
        let old = "Sgmodule(#1苹果服务)/Reddit.sgmodule"
        let current = "Sgmodule(#3广告模块)/Reddit.sgmodule"
        let module = RelayModule(name: "Reddit", sourceURL: "https://example.com/reddit.sgmodule", outputFileName: "Reddit.sgmodule", outputFolder: "Sgmodule(#1苹果服务)", storageLocation: .local, localStorageRelativePath: old)
        model.modules = [module]
        try await model.fileStore.writeComponent("#!name=Reddit\n[Rule]\nDOMAIN,reddit.example,REJECT\n", id: module.id)
        let initial = await model.refreshModuleOutputs(moduleIDs: [module.id], schedulesAutomaticPublish: false)
        XCTAssertTrue(initial)
        let oldURL = URL(filePath: model.settings.localModuleDirectory).appending(path: old)
        try FileManager.default.removeItem(at: oldURL)
        var draft = ModuleDraft(module: module)
        draft.outputFolder = "Sgmodule(#3广告模块)"
        try await model.enqueueModuleSave(moduleID: module.id, draft: draft)
        await model.pendingModuleSaveTask?.value
        let updated = await model.refreshModuleOutputs(moduleIDs: [module.id], schedulesAutomaticPublish: false)
        XCTAssertTrue(updated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(filePath: model.settings.localModuleDirectory).appending(path: current).path))
        let reloaded = ModuleNamingPlanner.normalizedModuleNaming(PersistenceStore.loadModules(in: root.appending(path: "Config"), allowLegacyFallback: false), localModuleDirectory: model.settings.localModuleDirectory)
        XCTAssertEqual(reloaded.first?.publishedRelativePath, current)
    }

    func testBusyModuleSavesKeepSnapshotsAndRunInSubmissionOrderAfterCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = pendingSaveModel(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        let module = RelayModule(name: "Original", sourceURL: "https://test.invalid/original.sgmodule", outputFileName: "Original")
        model.modules = [module]
        model.beginWork(.updatingModules)
        let generation = model.localChangeGeneration
        var draft = ModuleDraft(module: module)
        draft.name = "First click"
        try await model.enqueueModuleSave(moduleID: module.id, draft: draft)
        draft.name = "Second click"
        try await model.enqueueModuleSave(moduleID: module.id, draft: draft)
        draft.name = "Not submitted"
        XCTAssertEqual(model.modules[0].name, "Original")
        XCTAssertEqual(model.localChangeGeneration, generation)
        XCTAssertEqual(model.workActivity.kind, .updatingModules)
        XCTAssertEqual(model.pendingModuleSaves.map(\.draft.name), ["First click", "Second click"])
        XCTAssertNil(model.pendingModuleSaveTask)
        XCTAssertEqual(PersistenceStore.loadPendingModuleSaves(in: root.appending(path: "Config")).count, 2)

        XCTAssertTrue(model.cancelCurrentWork())
        model.endWork(.updatingModules)
        let processing = try XCTUnwrap(model.pendingModuleSaveTask)
        await processing.value

        XCTAssertEqual(model.modules[0].name, "Second click")
        XCTAssertEqual(model.localChangeGeneration, generation + 2)
        XCTAssertTrue(model.pendingModuleSaves.isEmpty)
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(PersistenceStore.loadModules(in: root.appending(path: "Config"), allowLegacyFallback: false)[0].name, "Second click")
        XCTAssertTrue(PersistenceStore.loadPendingModuleSaves(in: root.appending(path: "Config")).isEmpty)
    }

    func testPendingAdditionsRecoverAfterRestartWithoutDuplicatingAcknowledgedModules() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = pendingSaveModel(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        model.beginWork(.publishing)
        for name in ["First", "Second"] {
            var draft = ModuleDraft(defaultStorageLocation: .gitHub)
            draft.name = name
            draft.sourceURL = "https://test.invalid/\(name).sgmodule"
            try await model.enqueueModuleSave(moduleID: nil, draft: draft)
        }
        let intents = model.pendingModuleSaves
        let restarted = pendingSaveModel(root: root)
        defer { restarted.persistenceFeedbackTask?.cancel() }
        XCTAssertEqual(restarted.pendingModuleSaves.map(\.id), intents.map(\.id))
        restarted.schedulePendingModuleSaves()
        await restarted.pendingModuleSaveTask?.value
        XCTAssertEqual(restarted.modules.map(\.name), ["First", "Second"])
        XCTAssertEqual(restarted.modules.map(\.id), intents.map(\.id))
        restarted.enqueueConfiguration([intents[0]], fileName: "pending-module-saves.json")
        try await restarted.flushPersistence()
        let replayed = pendingSaveModel(root: root)
        defer { replayed.persistenceFeedbackTask?.cancel() }
        replayed.schedulePendingModuleSaves()
        await replayed.pendingModuleSaveTask?.value
        XCTAssertEqual(replayed.modules.map(\.id), intents.map(\.id))
        XCTAssertTrue(replayed.pendingModuleSaves.isEmpty)
    }

    func testFailedSaveStaysInQueueWithoutBlockingLaterItemsAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = pendingSaveModel(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        let original = RelayModule(name: "Removed while busy", sourceURL: "https://test.invalid/removed.sgmodule", outputFileName: "Removed")
        model.modules = [original]
        model.beginWork(.publishing)
        var edit = ModuleDraft(module: original)
        edit.name = "Saved after retry"
        try await model.enqueueModuleSave(moduleID: original.id, draft: edit)
        let failedID = try XCTUnwrap(model.pendingModuleSaves.first?.id)
        var add = ModuleDraft(defaultStorageLocation: .gitHub)
        add.name = "Independent addition"
        add.sourceURL = "https://test.invalid/addition.sgmodule"
        try await model.enqueueModuleSave(moduleID: nil, draft: add)
        model.modules = []
        model.endWork(.publishing)
        await model.pendingModuleSaveTask?.value
        XCTAssertEqual(model.modules.map(\.name), ["Independent addition"])
        XCTAssertEqual(model.pendingModuleSaves.map(\.id), [failedID])
        XCTAssertNotNil(model.pendingModuleSaves[0].errorMessage)
        XCTAssertFalse(model.pendingModuleSaves[0].errorMessage?.contains("转换结果") == true)
        XCTAssertNotNil(PersistenceStore.loadPendingModuleSaves(in: root.appending(path: "Config"))[0].errorMessage)

        model.modules.append(original)
        try await model.retryPendingModuleSave(id: failedID)
        await model.pendingModuleSaveTask?.value
        XCTAssertTrue(model.pendingModuleSaves.isEmpty)
        XCTAssertEqual(model.modules.last?.name, "Saved after retry")
    }

    func testPendingSaveCancellationAndWorkspaceRetirementPreserveIntentBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = pendingSaveModel(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        model.beginWork(.updatingModules)
        var draft = ModuleDraft(defaultStorageLocation: .gitHub)
        draft.name = "Cancelled"
        draft.sourceURL = "https://test.invalid/cancelled.sgmodule"
        try await model.enqueueModuleSave(moduleID: nil, draft: draft)
        try await model.cancelPendingModuleSave(id: XCTUnwrap(model.pendingModuleSaves.first?.id))
        XCTAssertTrue(PersistenceStore.loadPendingModuleSaves(in: root.appending(path: "Config")).isEmpty)
        draft.name = "Old workspace only"
        try await model.enqueueModuleSave(moduleID: nil, draft: draft)
        model.isWorkspaceTransitioning = true
        model.endWork(.updatingModules)
        model.finishWorkspaceRetirement()
        model.schedulePendingModuleSaves()
        XCTAssertNil(model.pendingModuleSaveTask)
        XCTAssertTrue(model.modules.isEmpty)
        let other = pendingSaveModel(root: root.appending(path: "Other"))
        XCTAssertTrue(other.pendingModuleSaves.isEmpty)
        let reopened = pendingSaveModel(root: root)
        defer { reopened.persistenceFeedbackTask?.cancel() }
        reopened.schedulePendingModuleSaves()
        await reopened.pendingModuleSaveTask?.value
        XCTAssertEqual(reopened.modules.map(\.name), ["Old workspace only"])
    }

    func testQueuedSaveDoesNotInheritCancellationFromTheFinishingTask() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = pendingSaveModel(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let waiting = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let operation = Task { @MainActor in
            model.beginWork(.updatingModules)
            defer { model.endWork(.updatingModules) }
            var draft = ModuleDraft(defaultStorageLocation: .gitHub)
            draft.name = "Survives cancellation"
            draft.sourceURL = "https://test.invalid/cancel-parent.sgmodule"
            try await model.enqueueModuleSave(moduleID: nil, draft: draft)
            ready.continuation.yield(())
            for await _ in waiting.stream {}
        }
        var events = ready.stream.makeAsyncIterator()
        _ = await events.next()
        operation.cancel()
        try await operation.value
        await model.pendingModuleSaveTask?.value
        XCTAssertEqual(model.modules.map(\.name), ["Survives cancellation"])
        XCTAssertTrue(model.pendingModuleSaves.isEmpty)
        XCTAssertFalse(model.isWorking)
    }

    func testUnmanagedBaiduOutputDoesNotBlockOtherModulesAndCanBeAdopted() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Independent local outputs",
            configurationDirectory: root.appending(path: "Config"), cacheDirectory: root.appending(path: "Cache"),
            allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        defer { model.persistenceFeedbackTask?.cancel() }
        let directory = root.appending(path: "Modules")
        model.settings.localModuleDirectory = directory.path
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        let blocked = RelayModule(name: "百度网盘去广告", sourceURL: "https://test.invalid/Baidu.plugin", sourceFormat: .loon,
            outputFileName: "百度网盘去广告.beta.sgmodule", outputFolder: "Sgmodule(#3广告模块)", storageLocation: .local)
        let ready = RelayModule(name: "Biliverse.Enhanced", sourceURL: "https://test.invalid/Biliverse.sgmodule",
            outputFileName: "Biliverse.Enhanced.sgmodule", outputFolder: "Sgmodule(#7增强模块)", storageLocation: .local)
        model.modules = [blocked, ready]
        let originalURL = directory.appending(path: blocked.publishedRelativePath)
        let original = Data("#!name=Personal\n[Rule]\nDOMAIN,original.example,DIRECT\n".utf8)
        try FileManager.default.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: originalURL)
        for module in model.modules {
            try await model.fileStore.writeComponent("#!name=Cached\n[Rule]\nDOMAIN,updated.example,REJECT\n", id: module.id)
        }

        let succeeded = await model.refreshModuleOutputs(schedulesAutomaticPublish: false)

        XCTAssertFalse(succeeded)
        XCTAssertNil(model.presentedError, "One output conflict must not open a global failure dialog")
        XCTAssertNotNil(model.modules[0].localOutputError)
        XCTAssertNil(model.modules[1].localOutputError)
        XCTAssertEqual(model.moduleSummary.attentionCount, 1)
        XCTAssertTrue(ModuleFilter.attention.matches(model.modules[0]))
        XCTAssertEqual(ModuleSidebarSectionPlanner.sections(for: model.modules).first?.modules.map(\.id), [blocked.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: ready.publishedRelativePath).path))
        XCTAssertEqual(try Data(contentsOf: originalURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.cacheDirectory.appending(path: "Combined.cache").path))

        let review = try await model.prepareLocalOutputAdoption(moduleID: blocked.id)
        try await model.confirmLocalOutputAdoption(review)

        XCTAssertNil(model.modules[0].localOutputError)
        XCTAssertEqual(model.moduleSummary.attentionCount, 0)
        XCTAssertTrue(String(decoding: try Data(contentsOf: originalURL), as: UTF8.self).contains("updated.example"))
        let backups = try XCTUnwrap(FileManager.default.enumerator(at: context.configurationDirectory.appending(path: "Backups/LocalOutputAdoption"), includingPropertiesForKeys: nil))
            .allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "sgmodule" }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
    }

    func testRefreshingOneModuleDoesNotReadOrPublishUnrelatedModules() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Selected output isolation",
            configurationDirectory: root.appending(path: "Config"), cacheDirectory: root.appending(path: "Cache"),
            allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        defer { model.persistenceFeedbackTask?.cancel() }
        model.settings.localModuleDirectory = root.appending(path: "Modules").path
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        let unrelated = RelayModule(name: "No cache", sourceURL: "https://test.invalid/missing.sgmodule",
            outputFileName: "Missing", storageLocation: .local)
        let selected = RelayModule(name: "Selected", sourceURL: "https://test.invalid/selected.sgmodule",
            outputFileName: "Selected", storageLocation: .local)
        model.modules = [unrelated, selected]
        try await model.fileStore.writeComponent("[Rule]\nDOMAIN,selected.example,DIRECT", id: selected.id)

        let succeeded = await model.refreshModuleOutputs(moduleIDs: [selected.id], schedulesAutomaticPublish: false)

        XCTAssertTrue(succeeded)
        XCTAssertNil(model.modules[0].localOutputError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Modules/Selected.sgmodule").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Modules/Missing.sgmodule").path))
    }

    func testNativeUpdateCommitsSnapshotAndFinishesActivity() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Runtime.sgmodule")
        try Data("#!name=Runtime\n[Rule]\nDOMAIN,example.org,DIRECT\n".utf8).write(to: source)
        let model = isolatedModel()
        let module = RelayModule(name: "Runtime", sourceURL: source.absoluteString, outputFileName: "Runtime")
        model.modules = [module]
        await model.updateAll(refreshesScriptHubEngine: false)
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.workActivity.isActive)
        XCTAssertTrue(model.synchronizingModuleIDs.isEmpty)
        XCTAssertEqual(model.synchronizationCompletedCount, 1)
        XCTAssertEqual(model.modules.first?.state, .current)
        XCTAssertNotNil(model.modules.first?.sourceContentHash)
        let content = try await model.fileStore.readConvertedComponent(id: module.id)
        XCTAssertTrue(content.contains("DOMAIN,example.org,DIRECT"))
        XCTAssertEqual(model.updateHistory.first?.outcome, .updated)
        try await model.fileStore.removeComponent(id: module.id)
    }

    func testCancelledQueuedUpdateDoesNotChangeWorkState() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        model.modules = [RelayModule(name: "Queued", sourceURL: "https://test.invalid/queued.sgmodule", outputFileName: "Queued")]
        await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await model.updateAll()
        }.value
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.modules.first?.state, .never)
        XCTAssertTrue(model.updateHistory.isEmpty)
    }

    func testSummaryCacheInvalidatesAndDoesNotDoubleCountAttention() throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        model.modules = [RelayModule(name: "DNS", sourceURL: "https://test.invalid/dns.sgmodule", outputFileName: "DNS")]
        XCTAssertEqual(model.moduleSummary.attentionCount, 0)
        model.modules[0].state = .failed
        model.modules[0].hasOverrideConflict = true
        XCTAssertEqual(model.moduleSummary.attentionCount, 1)
        XCTAssertEqual(model.moduleSummary.overrideConflictCount, 1)
        model.modules = []
        XCTAssertEqual(model.moduleSummary.totalCount, 0)
    }

    func testStreamingFingerprintPreservesExistingHashes() async {
        let content = "#!name=Streaming\n"
        let assets = [GeneratedAsset(relativePath: "assets/b.js", data: Data("second".utf8)), GeneratedAsset(relativePath: "assets/a.js", data: Data("first".utf8))]
        var legacy = Data(content.utf8)
        for asset in assets.sorted(by: { $0.relativePath < $1.relativePath }) {
            legacy.append(0); legacy.append(contentsOf: asset.relativePath.utf8); legacy.append(0); legacy.append(asset.data)
        }
        let fingerprint = await ModuleProcessingWorker().contentFingerprint(of: content, assets: assets)
        XCTAssertEqual(fingerprint, legacy.sha256String)
    }

    func testArgumentChangesInvalidateContentSearchCache() {
        var module = RelayModule(name: "Args", sourceURL: "https://test.invalid/args.sgmodule", outputFileName: "Args")
        module.contentHash = "same-conversion"
        let before = ModuleSearchIndex.contentCacheKey(for: module)
        module.argumentOverrides["policy"] = "Proxy"
        XCTAssertNotEqual(before, ModuleSearchIndex.contentCacheKey(for: module))
    }



    func testSelectedPublishCannotReuseOverwritePermissionFromAnotherRoot() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "Demo.sgmodule"
        let original = Data("#!name=User-owned\n[Rule]\nDOMAIN,user.example,DIRECT".utf8)
        try original.write(to: root.appending(path: path))
        let model = isolatedModel()
        model.settings.localModuleDirectory = root.path
        model.settings.localPublishedRootDirectory = root.appending(path: "old-root").path
        model.settings.localPublishedFilePaths = [path]
        do {
            try await model.publishSelectedLocalFiles([PublishFile(name: path, data: Data("replacement".utf8))])
            XCTFail("A previous root must not authorize overwriting an unrelated file")
        } catch {
            XCTAssertEqual(try Data(contentsOf: root.appending(path: path)), original)
        }
        XCTAssertNotEqual(model.settings.localPublishedRootDirectory, root.path)
    }


    func testSelectedPublishDropsUnrelatedManifestAfterRootChange() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = isolatedModel()
        model.settings.localModuleDirectory = root.path
        model.settings.localPublishedRootDirectory = root.appending(path: "old-root").path
        model.settings.localPublishedFilePaths = ["Old.sgmodule"]
        try await model.publishSelectedLocalFiles([PublishFile(name: "New.sgmodule", data: Data("#!name=New".utf8))])
        XCTAssertEqual(model.settings.localPublishedFilePaths, ["New.sgmodule"])
        XCTAssertEqual(model.settings.localPublishedRootDirectory, root.path)
    }

    func testCurrentAndSelectedPublishDoNotReplaceManifestAfterRootChangesDuringExport() async throws {
        for selected in [false, true] {
            try await assertLocalPublishRejectsContextChange(.root, selected: selected)
        }
    }

    func testCurrentAndSelectedPublishRetainJournalAfterGenerationOrWorkspaceChangesDuringExport() async throws {
        for selected in [false, true] {
            for change in [LocalPublishContextChange.generation, .transition, .retirement] {
                try await assertLocalPublishRejectsContextChange(change, selected: selected)
            }
        }
    }

    func testPartialLocalPublishDoesNotReplaceManifestAfterRootChangesDuringExport() async throws {
        for selected in [false, true] {
            try await assertLocalPublishRejectsContextChange(.root, selected: selected, failsAfterWrite: true)
        }
    }

    func testFailedRestorePreservesManualOverride() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        let module = RelayModule(name: "Draft", sourceURL: "https://test.invalid/draft.sgmodule", outputFileName: "Draft")
        model.modules = [module]
        try await model.fileStore.writeComponentOverride("precious manual edit", id: module.id)
        let original = try await model.fileStore.readComponent(id: module.id)
        do {
            _ = try await model.restorePreviewContent(for: module)
            XCTFail("Restoring without converted content must fail")
        } catch {
            let retained = try await model.fileStore.readComponent(id: module.id)
            XCTAssertEqual(retained, original)
        }
        XCTAssertFalse(model.isWorking)
        try await model.fileStore.removeComponent(id: module.id)
    }

    func testWebPreviewETagRejectsStaleWriteAndTracksRestoredContent() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        let module = RelayModule(name: "Conditional Draft", sourceURL: "https://test.invalid/conditional.sgmodule", outputFileName: "Conditional")
        model.modules = [module]
        try await model.fileStore.writeComponent("#!name=Conditional Draft\n[Rule]\nDOMAIN,original.example,DIRECT", id: module.id)
        let path = "/api/modules/\(module.id)/preview"
        let original = await WebManagementAPI.response(for: previewRequest("GET", path: path), model: model)
        XCTAssertEqual(original.status, 200)
        let originalETag = try XCTUnwrap(original.headers["ETag"])
        XCTAssertEqual(originalETag, WebManagementAPI.previewETag(for: String(decoding: original.body, as: UTF8.self)))
        let saved = await WebManagementAPI.response(
            for: previewRequest("PUT", path: path, content: "[Rule]\nDOMAIN,first.example,DIRECT", etag: originalETag), model: model
        )
        XCTAssertEqual(saved.status, 200)
        let latest = await WebManagementAPI.response(for: previewRequest("GET", path: path), model: model)
        XCTAssertEqual(saved.headers["ETag"], latest.headers["ETag"])
        XCTAssertNotEqual(saved.headers["ETag"], originalETag)
        let stale = await WebManagementAPI.response(
            for: previewRequest("PUT", path: path, content: "[Rule]\nDOMAIN,stale.example,DIRECT", etag: originalETag), model: model
        )
        XCTAssertEqual(stale.status, 412)
        XCTAssertEqual(stale.reason, "Precondition Failed")
        let retained = await WebManagementAPI.response(for: previewRequest("GET", path: path), model: model)
        XCTAssertEqual(retained.body, latest.body)
        XCTAssertFalse(model.isWorking)
        let confirmed = await WebManagementAPI.response(
            for: previewRequest("PUT", path: path, content: "[Rule]\nDOMAIN,confirmed.example,DIRECT", etag: saved.headers["ETag"]), model: model
        )
        XCTAssertEqual(confirmed.status, 200)
        let restored = await WebManagementAPI.response(for: previewRequest("DELETE", path: path), model: model)
        XCTAssertEqual(restored.status, 200)
        let afterRestore = await WebManagementAPI.response(for: previewRequest("GET", path: path), model: model)
        XCTAssertEqual(restored.headers["ETag"], afterRestore.headers["ETag"])
        XCTAssertEqual(restored.body, afterRestore.body)
        XCTAssertTrue(String(decoding: restored.body, as: UTF8.self).contains("original.example"))
        try await model.fileStore.removeComponent(id: module.id)
    }

    func testConcurrentWebPreviewWritesCannotBothUseSameBaseVersion() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        let module = RelayModule(name: "Concurrent Draft", sourceURL: "https://test.invalid/concurrent.sgmodule", outputFileName: "Concurrent")
        model.modules = [module]
        try await model.fileStore.writeComponent("#!name=Concurrent Draft\n[Rule]\nDOMAIN,original.example,DIRECT", id: module.id)
        let path = "/api/modules/\(module.id)/preview"
        let original = await WebManagementAPI.response(for: previewRequest("GET", path: path), model: model)
        let etag = try XCTUnwrap(original.headers["ETag"])
        let firstRequest = previewRequest("PUT", path: path, content: "[Rule]\nDOMAIN,first.example,DIRECT", etag: etag)
        let secondRequest = previewRequest("PUT", path: path, content: "[Rule]\nDOMAIN,second.example,DIRECT", etag: etag)
        let first = Task { @MainActor in await WebManagementAPI.response(for: firstRequest, model: model) }
        let second = Task { @MainActor in await WebManagementAPI.response(for: secondRequest, model: model) }
        let responses = await [first.value, second.value]
        XCTAssertEqual(responses.filter { $0.status == 200 }.count, 1)
        XCTAssertEqual(responses.filter { $0.status == 409 || $0.status == 412 }.count, 1)
        let latest = await WebManagementAPI.response(for: previewRequest("GET", path: path), model: model)
        let winner = try XCTUnwrap(responses.firstIndex { $0.status == 200 })
        XCTAssertEqual(latest.headers["ETag"], responses[winner].headers["ETag"])
        XCTAssertTrue(String(decoding: latest.body, as: UTF8.self).contains(winner == 0 ? "first.example" : "second.example"))
        XCTAssertFalse(model.isWorking)
        try await model.fileStore.removeComponent(id: module.id)
    }

    func testSavingPreviewRejectsMetadataDeletionAndArgumentMutations() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        let module = RelayModule(name: "Protected", sourceURL: "https://test.invalid/protected.sgmodule", outputFileName: "Protected", argumentOverrides: ["policy": "Original"])
        model.modules = [module]
        try await model.fileStore.writeComponent("#!name=Protected\n[Rule]\nDOMAIN,original.example,DIRECT", id: module.id)
        let cached = try await model.fileStore.readComponent(id: module.id)
        let generation = model.localChangeGeneration
        model.beginWork(.savingPreview)
        var draft = ModuleDraft(module: module)
        draft.name = "Changed while saving"
        XCTAssertThrowsError(try model.updateModule(id: module.id, from: draft)) { XCTAssertEqual($0 as? PreviewContentSaveError, .busy) }
        XCTAssertThrowsError(try model.duplicateModule(id: module.id)) { XCTAssertEqual($0 as? PreviewContentSaveError, .busy) }
        model.setModuleArgument(moduleID: module.id, key: "policy", value: "New", defaultValue: "Default")
        model.resetModuleArguments(moduleID: module.id)
        model.resetModuleArguments(moduleID: module.id)
        await model.deleteModule(id: module.id)
        await model.acceptOverrideConflict(moduleID: module.id)
        XCTAssertEqual(model.modules, [module])
        XCTAssertEqual(model.localChangeGeneration, generation)
        let retained = try await model.fileStore.readComponent(id: module.id)
        XCTAssertEqual(retained, cached)
        XCTAssertEqual(model.workActivity.kind, .savingPreview)
        model.endWork(.savingPreview)
        try await model.fileStore.removeComponent(id: module.id)
    }

    func testWebMutationsReturnBusyDuringPreviewSaveBeforeChangingState() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        let module = RelayModule(name: "Busy", sourceURL: "https://test.invalid/busy.sgmodule", outputFileName: "Busy")
        model.modules = [module]
        model.beginWork(.savingPreview)
        defer { model.endWork(.savingPreview) }
        let base = "/api/modules/\(module.id)"
        for (method, path) in [("PUT", base), ("DELETE", base), ("PUT", base + "/arguments"), ("DELETE", base + "/arguments"), ("POST", base + "/enabled"), ("POST", base + "/override-conflict"), ("POST", "/api/modules")] {
            let response = await WebManagementAPI.response(for: previewRequest(method, path: path, content: "{}"), model: model)
            XCTAssertEqual(response.status, 409, "\(method) \(path) must reject a busy mutation")
        }
        XCTAssertEqual(model.modules, [module])
    }

    func testDeletedModuleCannotBeSavedOrRestoredFromStaleEditorReference() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        let removed = RelayModule(name: "Removed", sourceURL: "https://test.invalid/removed.sgmodule", outputFileName: "Removed")
        model.modules = []
        do {
            _ = try await model.savePreviewContent("orphaned edit", for: removed)
            XCTFail("A removed module must not recreate its override")
        } catch { XCTAssertTrue(error.localizedDescription.contains("已移除")) }
        do {
            _ = try await model.restorePreviewContent(for: removed)
            XCTFail("A removed module must not be restored")
        } catch { XCTAssertTrue(error.localizedDescription.contains("已移除")) }
        let hasOverride = await model.fileStore.hasOverride(id: removed.id)
        XCTAssertFalse(hasOverride)
        XCTAssertFalse(model.isWorking)
    }

    func testPreviewSaveResultSeparatesCanonicalContentFromHash() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        let module = RelayModule(name: "Canonical", sourceURL: "https://test.invalid/canonical.sgmodule", outputFileName: "Canonical")
        model.modules = [module]
        try await model.fileStore.writeComponent("#!name=Canonical\n[Rule]\nFINAL,DIRECT", id: module.id)
        let result = try await model.savePreviewContent("[Rule]\nDOMAIN,edited.example,DIRECT", for: module)
        XCTAssertTrue(result.content.contains("#!name=Canonical"))
        XCTAssertTrue(result.content.contains("edited.example"))
        XCTAssertEqual(result.contentHash, Data(result.content.utf8).sha256String)
        XCTAssertNotEqual(result.content, result.contentHash)
        let actual = try await model.previewContent(for: model.modules[0])
        XCTAssertEqual(result.content, actual)
        try await model.fileStore.removeComponent(id: module.id)
    }

    private func previewRequest(_ method: String, path: String, content: String = "", etag: String? = nil) -> WebHTTPRequest {
        WebHTTPRequest(method: method, path: path, query: [:], headers: etag.map { ["if-match": $0] } ?? [:],
                       body: Data(content.utf8), isLoopback: true)
    }

    func testModuleMutationFlushPersistsLatestSnapshotBeforeReturning() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        model.modules = [RelayModule(name: "Queued persistence", sourceURL: "https://test.invalid/persist.sgmodule", outputFileName: "Persist")]
        try model.persistModules()
        model.modules[0].name = "Latest queued persistence"
        try model.persistModules()
        try await model.flushPersistence()
        let data = try Data(contentsOf: PersistenceStore.registryURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode([RelayModule].self, from: data)
        XCTAssertEqual(stored.first?.name, "Latest queued persistence")
        XCTAssertNil(model.persistenceError)
    }

    func testDuplicateLocalModuleKeepsDistinctOutputAfterReload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(
            id: UUID(), name: "Duplicate regression",
            configurationDirectory: root.appending(path: "Configuration"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false
        )
        let model = AppModel(context: context, persistsOnInit: false)
        model.workspaceIsActive = false
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = false
        model.settings.localModuleDirectory = root.appending(path: "Modules").path
        var source = RelayModule(
            name: "Local",
            sourceURL: root.appending(path: "Modules/My Module.sgmodule").absoluteString,
            outputFileName: "My Module.sgmodule",
            storageLocation: .local,
            localStorageRelativePath: "My Module.sgmodule"
        )
        source.localOutputError = "Original target is occupied"
        model.modules = [source]

        try model.duplicateModule(id: source.id)
        try await model.flushPersistence()
        let copy = try XCTUnwrap(model.modules.last)
        XCTAssertNil(copy.localOutputError)
        XCTAssertEqual(copy.outputFileName, "My Module-2.sgmodule")
        XCTAssertEqual(copy.localStorageRelativePath, "My Module-2.sgmodule")
        XCTAssertNotEqual(copy.publishedRelativePath, source.publishedRelativePath)
        let restored = ModuleNamingPlanner.normalizedModuleNaming(
            model.modules,
            localModuleDirectory: model.settings.localModuleDirectory
        )
        XCTAssertEqual(restored, model.modules)
        model.persistenceFeedbackTask?.cancel()
    }

    func testMissingBiliverseOutputCanBeWrittenDespiteUnrelatedUnmanagedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Missing local output",
            configurationDirectory: root.appending(path: "Config"), cacheDirectory: root.appending(path: "Cache"),
            allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        defer { model.persistenceFeedbackTask?.cancel() }
        let directory = root.appending(path: "Modules")
        model.settings.localModuleDirectory = directory.path
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = true
        var missing = RelayModule(name: "Biliverse.Enhanced", sourceURL: "https://test.invalid/Biliverse.sgmodule",
            outputFileName: "Biliverse.Enhanced.sgmodule", outputFolder: "Sgmodule(#7增强模块)",
            storageLocation: .local, localStorageRelativePath: "Sgmodule(#7增强模块)/Biliverse.Enhanced.sgmodule")
        missing.storageTargets = [.local, .gitHub]
        let blocked = RelayModule(name: "Unmanaged", sourceURL: "https://test.invalid/Unmanaged.sgmodule",
            outputFileName: "Unmanaged.sgmodule", storageLocation: .local)
        model.modules = [blocked, missing]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("#!name=Personal\n[Rule]\nFINAL,DIRECT\n".utf8)
        try original.write(to: directory.appending(path: blocked.publishedRelativePath))
        for module in model.modules {
            try await model.fileStore.writeComponent("#!name=Cached\n[Rule]\nDOMAIN,example.org,DIRECT\n", id: module.id)
        }
        let before = await model.localModuleOutputSnapshot(for: missing)
        XCTAssertEqual(before.state, .missing)
        let rebuilt = await model.refreshModuleOutputs(schedulesAutomaticPublish: false)
        XCTAssertFalse(rebuilt)

        try await model.writeLocalModuleOutput(moduleID: missing.id)

        let after = await model.localModuleOutputSnapshot(for: missing)
        XCTAssertEqual(after.state, .present)
        XCTAssertTrue(after.hasManagementHeader)
        XCTAssertTrue(model.settings.localPublishedFilePaths.contains(missing.publishedRelativePath))
        XCTAssertNil(model.presentedError)
        XCTAssertNil(model.latestGitHubPublish)
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: blocked.publishedRelativePath)), original)
    }

    func testLocalOutputAdoptionReviewsCurrentOutputAndRejectsChangedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Recover changed source",
            configurationDirectory: root.appending(path: "Config"), cacheDirectory: root.appending(path: "Cache"),
            allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        defer { model.persistenceFeedbackTask?.cancel() }
        let directory = root.appending(path: "Modules")
        model.settings.localModuleDirectory = directory.path
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        let module = RelayModule(name: "百度网盘去广告", sourceURL: "https://test.invalid/Baidu.plugin", sourceFormat: .loon,
            outputFileName: "百度网盘去广告.beta.sgmodule", outputFolder: "Sgmodule(#3广告模块)",
            storageLocation: .local, localStorageRelativePath: "Sgmodule(#3广告模块)/百度网盘去广告.beta.sgmodule")
        model.modules = [module]
        let destination = directory.appending(path: module.publishedRelativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("#!name=Personal\n[Rule]\nDOMAIN,old.example,DIRECT\n".utf8)
        try original.write(to: destination)
        try await model.fileStore.writeComponent("#!name=Converted\n[Rule]\nDOMAIN,new.example,REJECT\n", id: module.id)
        let review = try await model.prepareLocalOutputAdoption(moduleID: module.id)
        XCTAssertGreaterThan(review.diff.addedCount, 0)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let edited = original + Data("# Edited after review\n".utf8)
        try edited.write(to: destination)
        do {
            try await model.confirmLocalOutputAdoption(review)
            XCTFail("Adoption must reject a file changed since comparison")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: destination), edited)

        let refreshed = try await model.prepareLocalOutputAdoption(moduleID: module.id)
        try await model.confirmLocalOutputAdoption(refreshed)
        XCTAssertTrue(ManagedPublishedFile.isManaged(try Data(contentsOf: destination), relativePath: module.publishedRelativePath))
        XCTAssertTrue(String(decoding: try Data(contentsOf: destination), as: UTF8.self).contains("DOMAIN,new.example,REJECT"))
        let backups = try XCTUnwrap(FileManager.default.enumerator(at: context.configurationDirectory.appending(path: "Backups/LocalOutputAdoption"),
            includingPropertiesForKeys: nil)).allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "sgmodule" }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), edited)
    }

    func testFullLocalRebuildPublishesAndRetainsCurrentAssets() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Local asset regression",
            configurationDirectory: root.appending(path: "Configuration"), cacheDirectory: root.appending(path: "Cache"),
            allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        let directory = root.appending(path: "Modules")
        model.settings.localModuleDirectory = directory.path
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        model.settings.watchesLocalModuleChanges = false
        model.settings.automaticallyPublish = false
        let module = RelayModule(name: "With assets", sourceURL: "https://test.invalid/assets.sgmodule", sourceFormat: .surge,
            outputFileName: "With-assets.sgmodule", storageLocation: .local)
        model.modules = [module]
        let assetPath = "assets/\(module.id.uuidString.lowercased())/demo.js"
        let content = "#!name=With assets\n[Script]\nDemo = type=http-request, pattern=^https://example.org, script-path=\(assetPath)\n"
        let firstAsset = Data("const version = 1;".utf8)
        try await model.fileStore.commitConversion(ConversionResult(content: content,
            requestURL: try XCTUnwrap(URL(string: module.sourceURL)), assets: [GeneratedAsset(relativePath: assetPath, data: firstAsset)]), id: module.id)
        let selected = try await model.selectedLocalPublishedFiles(moduleIDs: [module.id])
        try await model.publishSelectedLocalFiles(selected)
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: assetPath)), firstAsset)

        for revision in [1, 2] {
            let currentAsset = Data("const revision = \(revision);".utf8)
            try await model.fileStore.replaceAssets([GeneratedAsset(relativePath: assetPath, data: currentAsset)], id: module.id)
            let succeeded = await model.refreshModuleOutputs(schedulesAutomaticPublish: false)
            XCTAssertTrue(succeeded, model.presentedError ?? "Local rebuild failed")
            XCTAssertNil(model.pendingPublishPreview, "Current assets must never appear in obsolete-file cleanup")
            XCTAssertTrue(model.settings.localPublishedFilePaths.contains(assetPath))
            XCTAssertEqual(try Data(contentsOf: directory.appending(path: assetPath)), currentAsset)
        }
        model.persistenceFeedbackTask?.cancel()
    }

    func testLocalSelfExportSourceIsNeverProposedOrDeletedByCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Source cleanup regression",
            configurationDirectory: root.appending(path: "Configuration"), cacheDirectory: root.appending(path: "Cache"),
            allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        let directory = root.appending(path: "Modules")
        model.settings.localModuleDirectory = directory.path
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        model.settings.watchesLocalModuleChanges = false
        model.settings.automaticallyPublish = false
        let sourcePath = "Source.sgmodule"
        _ = try await model.fileStore.exportPublishedFiles([
            PublishFile(name: sourcePath, data: Data("#!name=Source\n[General]\n".utf8)),
            PublishFile(name: "Old.sgmodule", data: Data("#!name=Old\n[General]\n".utf8))
        ], toRootDirectory: directory.path)
        let source = directory.appending(path: sourcePath)
        let original = try Data(contentsOf: source)
        model.settings.localPublishedRootDirectory = directory.path
        model.settings.localPublishedFilePaths = [sourcePath, "Old.sgmodule"]
        model.modules = [RelayModule(name: "Source", sourceURL: source.absoluteString, sourceFormat: .surge,
            outputFileName: sourcePath, storageLocation: .local, localStorageRelativePath: sourcePath)]

        _ = await model.refreshModuleOutputs(schedulesAutomaticPublish: false)
        XCTAssertNil(model.pendingPublishPreview)
        XCTAssertEqual(model.settings.localPublishedFilePaths, ["Old.sgmodule"])
        let oldData = try Data(contentsOf: directory.appending(path: "Old.sgmodule"))
        model.pendingPublishPreview = PublishPreview(destination: .local, targetDescription: directory.path, activeFiles: [],
            changedFiles: [], deletedFiles: ["Old.sgmodule"], localExpectedHashes: ["Old.sgmodule": oldData.sha256String],
            localReviewFingerprint: model.localCleanupReviewFingerprint())
        await model.confirmPendingPublish()
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "Old.sgmodule").path))
        XCTAssertNil(model.pendingPublishPreview)

        model.pendingPublishPreview = PublishPreview(destination: .local, targetDescription: directory.path,
            activeFiles: [], changedFiles: [], deletedFiles: [sourcePath], localExpectedHashes: [sourcePath: original.sha256String],
            localReviewFingerprint: model.localCleanupReviewFingerprint())
        await model.confirmPendingPublish()
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertNotNil(model.presentedError)
        model.persistenceFeedbackTask?.cancel()
    }

    func testLocalImportIsIdempotentAndNeverChangesSourceFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = root.appending(path: "Modules")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("#!name=Local\n[General]\n".utf8)
        let source = directory.appending(path: "My Module.sgmodule")
        try original.write(to: source)
        let context = WorkspaceContext(
            id: UUID(), name: "Import regression",
            configurationDirectory: root.appending(path: "Configuration"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false
        )
        let model = AppModel(context: context, persistsOnInit: false)
        model.settings.localModuleDirectory = directory.path
        model.settings.watchesLocalModuleChanges = false
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        model.settings.automaticallyPublish = false
        model.settings.localPublishedRootDirectory = root.appending(path: "Previous").path
        model.settings.localPublishedFilePaths = ["My Module.sgmodule"]

        let report = try await model.scanExistingLocalModules()
        XCTAssertEqual(report.candidates.count, 1)
        await model.importLocalModules(report.candidates)
        XCTAssertEqual(model.modules.count, 1)
        XCTAssertEqual(model.statusMessage, "已导入 1 个本地模块")
        let imported = try XCTUnwrap(model.modules.first)
        let content = try await model.fileStore.readConvertedComponent(id: imported.id)
        XCTAssertTrue(content.contains("#!name=Local"))
        await model.importLocalModules(report.candidates)
        XCTAssertEqual(model.modules.count, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["My Module.sgmodule"])
        model.persistenceFeedbackTask?.cancel()
    }

    func testClearOutputPreservesRegisteredSourceWithManagedMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "Modules")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "Source.sgmodule")
        let original = ManagedPublishedFile.dataWrapping(Data("#!name=Source\n[Rule]\nFINAL,DIRECT\n".utf8),
            relativePath: "Source.sgmodule")
        try original.write(to: source)
        let context = WorkspaceContext(id: UUID(), name: "Delete regression",
            configurationDirectory: root.appending(path: "Configuration"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        model.settings.localModuleDirectory = directory.path
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = false
        model.settings.watchesLocalModuleChanges = false
        let module = RelayModule(name: "Source", sourceURL: source.absoluteString,
            outputFileName: "Source.sgmodule", storageLocation: .local,
            localStorageRelativePath: "Source.sgmodule")
        model.modules = [module]

        model.settings.publishToLocal = true
        model.settings.localPublishedRootDirectory = directory.path
        model.settings.localPublishedFilePaths = ["Source.sgmodule"]

        await model.deleteModule(id: module.id, mode: .clearOutput)

        XCTAssertTrue(model.modules.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(model.pendingPublishPreview?.deletedFiles.contains("Source.sgmodule") == true)
        XCTAssertFalse(model.settings.localPublishedFilePaths.contains("Source.sgmodule"))
        XCTAssertFalse(model.isWorking)
        model.persistenceFeedbackTask?.cancel()
    }

    func testFailedOutputDeletionRetainsModuleAndCachedContent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "Modules")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "Source.sgmodule")
        let personal = Data("personal module".utf8)
        try personal.write(to: source)
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "Output.sgmodule"),
            withDestinationURL: source)
        let context = WorkspaceContext(id: UUID(), name: "Failed delete regression",
            configurationDirectory: root.appending(path: "Configuration"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        model.settings.localModuleDirectory = directory.path
        model.settings.watchesLocalModuleChanges = false
        let module = RelayModule(name: "Output", sourceURL: "https://test.invalid/output.sgmodule",
            outputFileName: "Output.sgmodule", storageLocation: .local,
            localStorageRelativePath: "Output.sgmodule")
        model.modules = [module]
        try await model.fileStore.writeComponent("[Rule]\nFINAL,DIRECT", id: module.id)
        let cached = try await model.fileStore.readComponent(id: module.id)

        await model.deleteModule(id: module.id, mode: .clearOutput)

        XCTAssertEqual(model.modules, [module])
        XCTAssertTrue(model.presentedError?.contains("符号链接") == true)
        let retained = try await model.fileStore.readComponent(id: module.id)
        XCTAssertEqual(retained, cached)
        XCTAssertEqual(try Data(contentsOf: source), personal)
        XCTAssertFalse(model.isWorking)
        model.persistenceFeedbackTask?.cancel()
    }

    func testSubscribedLocalImportUsesPhysicalBytesAndOnlyRebuildsCache() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = root.appending(path: "Modules")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory.appending(path: "assets"), withIntermediateDirectories: true)
        let source = directory.appending(path: "Subscribed.sgmodule")
        let original = Data("""
        #!name=Subscribed Local
        #SUBSCRIBED http://script.hub/file/_start_/https://upstream.invalid/Loon/demo.plugin/_end_/Subscribed.sgmodule?type=loon-plugin&target=surge-module
        # Keep this local explanation
        [Script]
        Local = type=http-request, pattern=^https://local.example, script-path=assets/local.js
        """.utf8)
        let resource = Data("const retained = true;".utf8)
        try original.write(to: source)
        try resource.write(to: directory.appending(path: "assets/local.js"))
        let context = WorkspaceContext(
            id: UUID(), name: "Subscribed import regression",
            configurationDirectory: root.appending(path: "Configuration"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false
        )
        let model = AppModel(context: context, persistsOnInit: false)
        model.settings.localModuleDirectory = directory.path
        model.settings.watchesLocalModuleChanges = false
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = true
        model.settings.automaticallyPublish = true
        let contributor = RelayModule(name: "Combined contributor", sourceURL: "https://test.invalid/existing.sgmodule",
                                      outputFileName: "Existing")
        model.modules = [contributor]
        try await model.fileStore.writeComponent("[Rule]\nDOMAIN,existing.example,DIRECT", id: contributor.id)

        let report = try await model.scanExistingLocalModules()
        await model.importLocalModules(report.candidates)

        XCTAssertEqual(model.modules.count, 2)
        XCTAssertEqual(model.statusMessage, "已导入 1 个本地模块")
        XCTAssertNil(model.presentedError)
        XCTAssertNil(model.automaticPublishRunsAt)
        let imported = try XCTUnwrap(model.modules.last)
        XCTAssertEqual(imported.sourceFormat, .loon)
        XCTAssertEqual(imported.updateSourceURL, "https://upstream.invalid/Loon/demo.plugin")
        XCTAssertEqual(imported.initialSource, .subscribed(.loon))
        let cached = try await model.fileStore.readConvertedComponent(id: imported.id)
        XCTAssertTrue(cached.contains("# Keep this local explanation"))
        XCTAssertTrue(cached.contains("script-path=assets/local.js"))
        let retained = try await model.fileStore.readComponent(id: contributor.id)
        XCTAssertTrue(retained.contains("existing.example"))
        await model.importLocalModules(report.candidates)
        XCTAssertEqual(model.modules.count, 2)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: "assets/local.js")), resource)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["Subscribed.sgmodule", "assets"])
        model.persistenceFeedbackTask?.cancel()
    }

    func testScheduledRefreshUpdatesOnlyDueModulesAndPreservesOtherCaches() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fastURL = root.appending(path: "Fast.sgmodule")
        try Data("#!name=Fast\n[Rule]\nDOMAIN,fast-new.example,DIRECT".utf8).write(to: fastURL)
        let now = Date.now
        let fast = RelayModule(name: "Fast", sourceURL: fastURL.absoluteString, outputFileName: "Fast",
                               lastUpdatedAt: now.addingTimeInterval(-7_200), refreshIntervalMinutes: 5,
                               lastRefreshAttemptAt: now.addingTimeInterval(-7_200))
        let slow = RelayModule(name: "Slow", sourceURL: root.appending(path: "Missing-but-not-due.sgmodule").absoluteString,
                               outputFileName: "Slow", lastUpdatedAt: now,
                               refreshIntervalMinutes: 60, lastRefreshAttemptAt: now)
        let context = WorkspaceContext(
            id: UUID(), name: "Scheduled refresh regression",
            configurationDirectory: root.appending(path: "Configuration"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false
        )
        let model = AppModel(context: context, persistsOnInit: false)
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = false
        model.settings.automaticallyUpdateScriptHub = false
        model.settings.automaticallyPublish = false
        model.settings.watchesLocalModuleChanges = false
        model.settings.localModuleDirectory = root.path
        model.modules = [fast, slow]
        try await model.fileStore.writeComponent("#!name=Fast\n[Rule]\nDOMAIN,fast-old.example,DIRECT", id: fast.id)
        try await model.fileStore.writeComponent("#!name=Slow\n[Rule]\nDOMAIN,slow-cached.example,DIRECT", id: slow.id)
        await model.updateAll(refreshesScriptHubEngine: false, trigger: .scheduled)
        XCTAssertEqual(model.synchronizationTotalCount, 1)
        XCTAssertEqual(model.modules.first(where: { $0.id == slow.id })?.lastRefreshAttemptAt, now)
        let updatedFast = try await model.fileStore.readComponent(id: fast.id)
        let retainedSlow = try await model.fileStore.readComponent(id: slow.id)
        XCTAssertTrue(updatedFast.contains("fast-new.example"))
        XCTAssertTrue(retainedSlow.contains("slow-cached.example"))
        try await model.fileStore.removeComponent(id: fast.id)
        try await model.fileStore.removeComponent(id: slow.id)
        model.persistenceFeedbackTask?.cancel()
    }

    func testManualRefreshBypassesOrdinaryBackoffButWaitsForServer() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Manual.sgmodule")
        try Data("#!name=Manual\n[Rule]\nDOMAIN,manual.example,DIRECT".utf8).write(to: source)
        var module = RelayModule(name: "Manual", sourceURL: source.absoluteString, outputFileName: "Manual",
                                 consecutiveFailureCount: 3, nextRetryAt: .now.addingTimeInterval(3_600))
        let model = isolatedModel()
        model.modules = [module]
        await model.updateAll(refreshesScriptHubEngine: false)
        let saved = try XCTUnwrap(model.modules.first)
        XCTAssertEqual(saved.consecutiveFailureCount, 0)
        XCTAssertNil(saved.nextRetryAt)
        XCTAssertNotNil(saved.lastUpdatedAt)
        module = saved
        module.serverRetryAfter = .now.addingTimeInterval(3_600)
        module.serverRetrySourceURL = module.updateSourceURL
        model.modules = [module]
        await model.updateAll(refreshesScriptHubEngine: false)
        XCTAssertEqual(model.modules.first?.lastRefreshAttemptAt, module.lastRefreshAttemptAt)
        XCTAssertTrue(model.statusMessage.contains("Retry-After"))
        try await model.fileStore.removeComponent(id: module.id)
    }

    private enum LocalPublishContextChange {
        case root, generation, transition, retirement
    }

    private func assertLocalPublishRejectsContextChange(
        _ change: LocalPublishContextChange,
        selected: Bool,
        failsAfterWrite: Bool = false
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Local publish context regression",
            configurationDirectory: root.appending(path: "Configuration"), cacheDirectory: root.appending(path: "Cache"),
            allowsLegacyFallback: false)
        let oldDirectory = root.appending(path: "OldModules")
        let newDirectory = root.appending(path: "NewModules")
        let checkpoint = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let store = ModuleFileStore(cacheDirectory: context.cacheDirectory, configurationDirectory: context.configurationDirectory,
            allowsLegacyFallback: false, resourceInterruption: { phase in
                guard phase == .renamed else { return }
                checkpoint.continuation.yield(())
                guard resume.wait(timeout: .now() + 10) == .success else {
                    throw RelayError.invalidOutput("Timed out waiting for the context change")
                }
                if failsAfterWrite { throw RelayError.invalidOutput("Injected post-write failure") }
            })
        let model = AppModel(context: context, fileStore: store, persistsOnInit: false)
        defer { model.persistenceFeedbackTask?.cancel() }
        model.settings.localModuleDirectory = oldDirectory.path
        model.settings.localPublishedRootDirectory = oldDirectory.path
        model.settings.localPublishedFilePaths = ["Existing.sgmodule"]
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        model.settings.automaticallyPublish = false
        model.settings.watchesLocalModuleChanges = false
        let module = RelayModule(name: "Context", sourceURL: "https://test.invalid/context.sgmodule", sourceFormat: .surge,
            outputFileName: "Context.sgmodule", storageLocation: .local)
        model.modules = [module]
        let assetPath = "assets/\(module.id.uuidString.lowercased())/context.js"
        let assetData = Data("const context = 1;".utf8)
        let content = "#!name=Context\n[Script]\nContext = type=http-request, pattern=^https://example.org, script-path=\(assetPath)\n"
        try await store.commitConversion(ConversionResult(content: content,
            requestURL: try XCTUnwrap(URL(string: module.sourceURL)),
            assets: [GeneratedAsset(relativePath: assetPath, data: assetData)]), id: module.id)
        let files = [PublishFile(name: module.publishedRelativePath, data: Data(content.utf8)),
                     PublishFile(name: assetPath, data: assetData)]
        let publish = Task { @MainActor in
            defer { checkpoint.continuation.finish() }
            if selected {
                try await model.publishSelectedLocalFiles(files)
                return true
            }
            return await model.refreshModuleOutputs(schedulesAutomaticPublish: false)
        }
        var events = checkpoint.stream.makeAsyncIterator()
        let reachedCheckpoint = await events.next()
        XCTAssertNotNil(reachedCheckpoint)
        switch change {
        case .root:
            model.settings.localModuleDirectory = newDirectory.path
            model.settings.localPublishedRootDirectory = newDirectory.path
            model.settings.localPublishedFilePaths = ["New.sgmodule"]
        case .generation:
            model.registerLocalChange()
        case .transition:
            model.isWorkspaceTransitioning = true
        case .retirement:
            model.workspaceIsActive = false
        }
        let expectedRoot = model.settings.localPublishedRootDirectory
        let expectedPaths = model.settings.localPublishedFilePaths
        resume.signal()
        do {
            let succeeded = try await publish.value
            XCTAssertFalse(succeeded, "A stale publish must reject the previous context")
        } catch {
            XCTAssertTrue(error is CancellationError, error.localizedDescription)
        }
        XCTAssertEqual(model.settings.localPublishedRootDirectory, expectedRoot)
        XCTAssertEqual(model.settings.localPublishedFilePaths, expectedPaths)
        XCTAssertNil(model.pendingPublishPreview)
        XCTAssertEqual(try Data(contentsOf: oldDirectory.appending(path: assetPath)), assetData)
        let recovered = try await store.recoverPublishedResourcePaths(rootDirectoryPath: oldDirectory.path)
        XCTAssertEqual(recovered, [assetPath])
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDirectory.path))
    }

    private func isolatedModel() -> AppModel {
        let model = AppModel()
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = false
        model.settings.automaticallyUpdateScriptHub = false
        model.settings.automaticallyPublish = false
        model.settings.github.owner = ""
        model.settings.github.repository = ""
        model.updateHistory = []
        return model
    }
}

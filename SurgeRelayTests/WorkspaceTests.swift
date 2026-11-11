import Foundation
import XCTest
@testable import SurgeRelay

@MainActor
final class WorkspaceTests: XCTestCase {
    func testWorkspaceMigrationKeepsUserFilesWhenGeneralSettingsMovedConfigurationIntoCache() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for selectsCacheRoot in [true, false] {
            let caseRoot = root.appending(path: selectsCacheRoot ? "Cache root" : "Cache child")
            let context = makeContext(root: caseRoot, name: "Workspace")
            try writeState(context, moduleName: "Existing")
            try FileManager.default.createDirectory(at: context.cacheDirectory, withIntermediateDirectories: true)
            let cacheBytes = Data("cached data".utf8)
            try cacheBytes.write(to: context.cacheDirectory.appending(path: "cached.bin"))
            let store = WorkspaceStore(registryURL: caseRoot.appending(path: "registry.json"))
            try store.save(WorkspaceRegistry(activeID: context.id, workspaces: [WorkspaceDescriptor(context: context)]))
            let controller = WorkspaceController(store: store, defaultContext: context, startsServices: false)
            let selectedConfiguration = selectsCacheRoot ? context.cacheDirectory
                : context.cacheDirectory.appending(path: "Selected configuration", directoryHint: .isDirectory)
            try await controller.activeModel.migrateConfiguration(to: selectedConfiguration.path)
            let userFile = selectedConfiguration.appending(path: "Personal.txt")
            let userBytes = Data("keep this user file".utf8)
            try userBytes.write(to: userFile)
            let destination = caseRoot.appending(path: "Moved")

            try await controller.migrateWorkspace(id: context.id, to: destination)

            XCTAssertEqual(controller.activeModel.configurationStorageDirectory.path, destination.appending(path: "Configuration").path)
            XCTAssertEqual(controller.activeModel.cacheDirectoryURL.path, destination.appending(path: "Cache").path)
            XCTAssertEqual(controller.activeModel.modules.first?.name, "Existing")
            XCTAssertEqual(try Data(contentsOf: userFile), userBytes)
            XCTAssertEqual(try Data(contentsOf: destination.appending(path: "Cache/cached.bin")), cacheBytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: selectedConfiguration.appending(path: "settings.json").path))
            XCTAssertTrue(controller.errorMessage?.contains("旧缓存") == true)
            XCTAssertTrue(controller.activeModel.statusMessage.contains("已保留"))
            let loaded = try store.load(defaultContext: context)
            XCTAssertEqual(loaded.workspaces.first?.cacheDirectory.path, destination.appending(path: "Cache").path)
        }
    }

    func testActiveWorkspaceMigrationPreservesCompleteAppDataAndRetiresOldWriter() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = makeContext(root: root, name: "Original")
        let moduleID = UUID()
        try writeState(context, moduleName: "Preserved", id: moduleID)
        try LocalCredentialStore.saveGitHubToken("workspace-token", directory: context.configurationDirectory)
        try LocalCredentialStore.saveWebAccessToken("workspace-web", directory: context.configurationDirectory)
        let store = WorkspaceStore(registryURL: root.appending(path: "registry.json"))
        try store.save(WorkspaceRegistry(activeID: context.id, workspaces: [WorkspaceDescriptor(context: context)]))
        let controller = WorkspaceController(store: store, defaultContext: context, startsServices: false)
        let old = controller.activeModel
        let module = try XCTUnwrap(old.modules.first)
        old.selectedModuleID = AppModel.conversionToolsSelectionID
        old.settingsPage = .workspaces
        old.presentsSettings = true
        old.conversionToolDraft.kind = .script
        old.conversionToolDraft.sourceText = "$done({body: 'kept'});"
        old.nativeToolResult = ConversionToolResult(fileName: "Kept.js", content: "output", outputFormat: .quantumultX, kind: .script)
        old.nativeToolError = "Save file was unavailable"
        old.modulePreviewDrafts[moduleID] = ModulePreviewDraft(text: "unsaved draft", savedText: "saved base")
        old.moduleTemplates = [try ModuleTemplatePlanner.template(from: module, name: "Reusable")]
        old.enqueueConfiguration(old.moduleTemplates, fileName: "module-templates.json")
        old.pendingModuleSaves = [PendingModuleSave(moduleID: moduleID, draft: ModuleDraft(module: module), errorMessage: "Review")]
        let assetPath = "assets/\(moduleID.uuidString.lowercased())/script.js"
        let content = "[Script]\nDemo = type=http-request, pattern=^https://example.org, script-path=\(assetPath)\n"
        try await old.fileStore.commitConversion(ConversionResult(content: content, requestURL: URL(string: module.sourceURL)!,
            assets: [GeneratedAsset(relativePath: assetPath, data: Data("$done({});".utf8))]), id: moduleID)
        _ = try await old.fileStore.recordCurrentVersion(id: moduleID, reason: .current)
        try await old.engineStore.save(scripts: ["Rewrite-Parser.js": Data("engine".utf8)])
        let originalRoot = old.settings.localModuleDirectory
        let destinationRoot = root.appending(path: "Moved")

        try await controller.migrateWorkspace(id: context.id, to: destinationRoot)

        let active = controller.activeModel
        XCTAssertFalse(active === old)
        XCTAssertEqual(active.workspaceID, context.id)
        XCTAssertEqual(active.workspaceName, context.name)
        XCTAssertEqual(active.selectedModuleID, AppModel.conversionToolsSelectionID)
        XCTAssertEqual(active.settingsPage, .workspaces)
        XCTAssertTrue(active.presentsSettings)
        XCTAssertEqual(active.conversionToolDraft, old.conversionToolDraft)
        XCTAssertEqual(active.nativeToolResult?.fileName, "Kept.js")
        XCTAssertEqual(active.nativeToolResult?.content, "output")
        XCTAssertEqual(active.nativeToolError, "Save file was unavailable")
        XCTAssertEqual(active.configurationStorageDirectory.path, destinationRoot.appending(path: "Configuration").path)
        XCTAssertEqual(active.cacheDirectoryURL.path, destinationRoot.appending(path: "Cache").path)
        XCTAssertEqual(active.modules.map(\.id), [moduleID])
        XCTAssertEqual(active.modulePreviewDrafts[moduleID]?.text, "unsaved draft")
        XCTAssertEqual(active.moduleTemplates.map(\.name), ["Reusable"])
        XCTAssertEqual(active.pendingModuleSaves.first?.errorMessage, "Review")
        XCTAssertEqual(active.settings.localModuleDirectory, originalRoot)
        XCTAssertEqual(active.ensureGitHubTokenLoaded(), "workspace-token")
        XCTAssertEqual(active.ensureWebAccessTokenForEditing(), "workspace-web")
        let restoredContent = try await active.fileStore.readComponent(id: moduleID)
        XCTAssertEqual(restoredContent, content)
        let assets = try await active.fileStore.generatedAssetFiles(for: [moduleID])
        XCTAssertEqual(assets.first?.data, Data("$done({});".utf8))
        let engine = try await active.engineStore.script(named: "Rewrite-Parser.js")
        XCTAssertEqual(engine, "engine")
        let versions = try await active.fileStore.moduleVersions(id: moduleID)
        XCTAssertEqual(versions.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.configurationDirectory.appending(path: "modules.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.cacheDirectory.path))
        old.modulePreviewDrafts[moduleID] = ModulePreviewDraft(text: "stale view", savedText: "old base")
        await old.flushPreviewDrafts()
        await controller.finishViewRetirement(old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.configurationDirectory.appending(path: "preview-drafts.json").path))
        let reloaded = WorkspaceController(store: store, defaultContext: context, startsServices: false)
        XCTAssertEqual(reloaded.activeModel.cacheDirectoryURL, active.cacheDirectoryURL)
        XCTAssertEqual(reloaded.activeModel.modulePreviewDrafts[moduleID]?.text, "unsaved draft")
        old.previewDraftPersistenceTask?.cancel()
        active.persistenceFeedbackTask?.cancel()
    }

    func testInactiveWorkspaceMigrationDoesNotSwitchActiveWorkspaceOrMoveUserFiles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = makeContext(root: root, name: "A")
        let b = makeContext(root: root, name: "B")
        try writeState(a, moduleName: "A")
        try writeState(b, moduleName: "B")
        let notes = b.configurationDirectory.appending(path: "Personal.txt")
        try Data("user file".utf8).write(to: notes)
        try FileManager.default.createDirectory(at: b.cacheDirectory, withIntermediateDirectories: true)
        try Data("cached value".utf8).write(to: b.cacheDirectory.appending(path: "cached.bin"))
        let store = WorkspaceStore(registryURL: root.appending(path: "registry.json"))
        try store.save(WorkspaceRegistry(activeID: a.id, workspaces: [a, b].map(WorkspaceDescriptor.init(context:))))
        let controller = WorkspaceController(store: store, defaultContext: a, startsServices: false)
        let active = controller.activeModel
        let destination = root.appending(path: "Moved B")
        try await controller.migrateWorkspace(id: b.id, to: destination)
        XCTAssertTrue(controller.activeModel === active)
        XCTAssertEqual(controller.registry.activeID, a.id)
        XCTAssertEqual(try Data(contentsOf: notes), Data("user file".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.configurationDirectory.appending(path: "settings.json").path))
        XCTAssertEqual(try Data(contentsOf: destination.appending(path: "Cache/cached.bin")), Data("cached value".utf8))
        try await controller.switchWorkspace(to: b.id)
        XCTAssertEqual(controller.activeModel.modules.first?.name, "B")
        XCTAssertEqual(controller.activeModel.configurationStorageDirectory.path, destination.appending(path: "Configuration").path)
    }

    func testWorkspaceMigrationRegistryFailureRollsBackNewTreesAndKeepsOldRuntime() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = makeContext(root: root, name: "Existing")
        try writeState(context, moduleName: "Existing")
        try FileManager.default.createDirectory(at: context.cacheDirectory, withIntermediateDirectories: true)
        let oldCache = context.cacheDirectory.appending(path: "cached.bin")
        try Data("cache".utf8).write(to: oldCache)
        let failure = WorkspaceWriteFailure()
        let store = WorkspaceStore(registryURL: root.appending(path: "registry.json"), writeData: { data, url in
            if failure.enabled { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        try store.save(WorkspaceRegistry(activeID: context.id, workspaces: [WorkspaceDescriptor(context: context)]))
        let originalRegistry = try Data(contentsOf: store.registryURL)
        let controller = WorkspaceController(store: store, defaultContext: context, startsServices: false)
        let old = controller.activeModel
        let destination = root.appending(path: "Rejected")
        failure.enabled = true
        do { try await controller.migrateWorkspace(id: context.id, to: destination); XCTFail("Registry commit must fail") }
        catch {}
        XCTAssertTrue(controller.activeModel === old)
        XCTAssertTrue(old.workspaceIsActive)
        XCTAssertFalse(old.isWorkspaceTransitioning)
        XCTAssertFalse(old.isWorking)
        XCTAssertEqual(try Data(contentsOf: store.registryURL), originalRegistry)
        XCTAssertEqual(try Data(contentsOf: oldCache), Data("cache".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.configurationDirectory.appending(path: "modules.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appending(path: "Configuration").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appending(path: "Cache").path))
        old.enqueueConfiguration(["value": "still active"], fileName: "after-failure.json")
        try await old.flushPersistence()
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.configurationDirectory.appending(path: "after-failure.json").path))
    }

    func testWorkspaceMigrationRejectsOccupiedNestedAndOtherWorkspaceTargets() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = makeContext(root: root, name: "A")
        let b = makeContext(root: root, name: "B")
        try writeState(a, moduleName: "A")
        try writeState(b, moduleName: "B")
        let store = WorkspaceStore(registryURL: root.appending(path: "registry.json"))
        let registry = WorkspaceRegistry(activeID: a.id, workspaces: [a, b].map(WorkspaceDescriptor.init(context:)))
        try store.save(registry)
        let occupied = root.appending(path: "Occupied")
        try FileManager.default.createDirectory(at: occupied.appending(path: "Configuration"), withIntermediateDirectories: true)
        let owned = occupied.appending(path: "Configuration/Personal.txt")
        try Data("keep".utf8).write(to: owned)
        for target in [occupied, a.configurationDirectory.appending(path: "Nested"), b.configurationDirectory] {
            XCTAssertThrowsError(try store.migrateWorkspace(id: a.id, to: target, registry: registry))
        }
        XCTAssertEqual(try Data(contentsOf: owned), Data("keep".utf8))
        XCTAssertEqual(try store.load(defaultContext: a), registry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.configurationDirectory.appending(path: "modules.json").path))
    }

    func testDefaultWorkspaceMigrationUpdatesFallbackDirectoriesAndMaterializesLegacyCache() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA directory selectors") }
        let previousConfiguration = PersistenceStore.configurationDirectoryURL
        let previousCache = PersistenceStore.cacheDirectoryURL
        defer {
            PersistenceStore.selectConfigurationDirectory(previousConfiguration)
            PersistenceStore.selectCacheDirectory(previousCache)
        }
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: WorkspaceContext.legacyID, name: "Default",
            configurationDirectory: root.appending(path: "Original/Config"), cacheDirectory: root.appending(path: "Original/Cache"),
            allowsLegacyFallback: false)
        let id = UUID()
        try writeState(context, moduleName: "Legacy", id: id)
        let legacy = root.appending(path: "Legacy Components")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let bytes = Data("[Rule]\nDOMAIN,legacy.example,DIRECT".utf8)
        try bytes.write(to: legacy.appending(path: "\(id.uuidString).sgmodule"))
        let store = WorkspaceStore(registryURL: root.appending(path: "registry.json"), legacyComponentsDirectory: legacy)
        let controller = WorkspaceController(store: store, defaultContext: context, startsServices: false)
        let destination = root.appending(path: "Moved")
        try await controller.migrateWorkspace(id: context.id, to: destination)
        XCTAssertEqual(PersistenceStore.configurationDirectoryURL.path, destination.appending(path: "Configuration").path)
        XCTAssertEqual(PersistenceStore.cacheDirectoryURL.path, destination.appending(path: "Cache").path)
        let content = try await controller.activeModel.fileStore.readConvertedComponent(id: id)
        XCTAssertEqual(Data(content.utf8), bytes)
        XCTAssertEqual(WorkspaceContext.legacyDefault.cacheDirectory.path, destination.appending(path: "Cache").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appending(path: "\(id.uuidString).sgmodule").path))
    }

    func testMigratingConfigurationParentKeepsRegistryAndUnrelatedWorkspace() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Parent", configurationDirectory: root,
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false)
        let other = makeContext(root: root, name: "Other")
        try writeState(context, moduleName: "Parent")
        try writeState(other, moduleName: "Other")
        let store = WorkspaceStore(registryURL: root.appending(path: "registry.json"))
        try store.save(WorkspaceRegistry(activeID: context.id, workspaces: [context, other].map(WorkspaceDescriptor.init(context:))))
        let controller = WorkspaceController(store: store, defaultContext: context, startsServices: false)
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await controller.migrateWorkspace(id: context.id, to: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.registryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.configurationDirectory.appending(path: "modules.json").path))
        XCTAssertEqual(try store.load(defaultContext: context).activeID, context.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "settings.json").path))
        try await controller.switchWorkspace(to: other.id)
        XCTAssertEqual(controller.activeModel.modules.first?.name, "Other")
    }

    func testDefaultRegistrationDoesNotMoveOrRewriteExistingFiles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = makeContext(root: root, name: "Existing")
        try writeState(context, moduleName: "Existing")
        let modules = context.configurationDirectory.appending(path: "modules.json")
        let original = try Data(contentsOf: modules)
        let store = WorkspaceStore(registryURL: root.appending(path: "registry.json"))
        let registry = try store.load(defaultContext: context)
        XCTAssertEqual(registry.workspaces.count, 1)
        XCTAssertEqual(registry.workspaces[0].configurationDirectory, context.configurationDirectory)
        XCTAssertEqual(registry.workspaces[0].cacheDirectory, context.cacheDirectory)
        XCTAssertEqual(try Data(contentsOf: modules), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.registryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Workspaces").path))
    }

    func testSwitchIsolatesCredentialsDraftsVersionsAndSameIDCache() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let a = makeContext(root: root, name: "A")
        let b = makeContext(root: root, name: "B")
        try writeState(a, moduleName: "A module", id: id)
        try writeState(b, moduleName: "B module", id: id)
        try write([id: ModulePreviewDraft(text: "A draft", savedText: "A base")], to: a.configurationDirectory.appending(path: "preview-drafts.json"))
        try write([id: ModulePreviewDraft(text: "B draft", savedText: "B base")], to: b.configurationDirectory.appending(path: "preview-drafts.json"))
        try LocalCredentialStore.saveGitHubToken("A-secret", directory: a.configurationDirectory)
        try LocalCredentialStore.saveGitHubToken("B-secret", directory: b.configurationDirectory)
        try LocalCredentialStore.saveWebAccessToken("A-web", directory: a.configurationDirectory)
        try LocalCredentialStore.saveWebAccessToken("B-web", directory: b.configurationDirectory)
        let store = WorkspaceStore(registryURL: root.appending(path: "registry.json"))
        try store.save(WorkspaceRegistry(activeID: a.id, workspaces: [WorkspaceDescriptor(context: a), WorkspaceDescriptor(context: b)]))
        let controller = WorkspaceController(store: store, defaultContext: a, startsServices: false)
        let old = controller.activeModel
        let otherStore = ModuleFileStore(cacheDirectory: b.cacheDirectory, configurationDirectory: b.configurationDirectory)
        try await old.fileStore.writeComponent("[Rule]\nDOMAIN,a.example,DIRECT", id: id)
        try await otherStore.writeComponent("[Rule]\nDOMAIN,b.example,DIRECT", id: id)
        _ = try await old.fileStore.recordCurrentVersion(id: id, reason: .current)
        _ = try await otherStore.recordCurrentVersion(id: id, reason: .current)
        XCTAssertEqual(old.ensureGitHubTokenLoaded(), "A-secret")
        try await controller.switchWorkspace(to: b.id)
        let active = controller.activeModel
        XCTAssertEqual(active.workspaceID, b.id)
        XCTAssertEqual(active.modules.first?.name, "B module")
        XCTAssertEqual(active.modulePreviewDrafts[id]?.text, "B draft")
        XCTAssertEqual(active.ensureGitHubTokenLoaded(), "B-secret")
        XCTAssertEqual(active.ensureWebAccessTokenForEditing(), "B-web")
        let activeContent = try await active.fileStore.readComponent(id: id)
        XCTAssertTrue(activeContent.contains("b.example"))
        let versions = try await active.fileStore.moduleVersions(id: id)
        XCTAssertEqual(versions.count, 1)
        let version = try await active.fileStore.readModuleVersion(id: id, versionID: versions[0].id)
        XCTAssertTrue(version.content.contains("b.example"))
        XCTAssertFalse(active.settings.webServerEnabled)
        XCTAssertEqual(active.webServerState, .stopped)
        XCTAssertFalse(old.workspaceIsActive)
        XCTAssertTrue(old.githubToken.isEmpty)
        XCTAssertEqual(try LocalCredentialStore.loadGitHubToken(directory: a.configurationDirectory), "A-secret")
        await controller.finishViewRetirement(old)
        active.previewDraftPersistenceTask?.cancel()
        active.persistenceFeedbackTask?.cancel()
    }

    func testLateOldWriterAndIconCompletionStayInOldWorkspace() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = makeContext(root: root, name: "A")
        let b = makeContext(root: root, name: "B")
        try writeState(a, moduleName: "A")
        try writeState(b, moduleName: "B")
        let store = WorkspaceStore(registryURL: root.appending(path: "registry.json"))
        try store.save(WorkspaceRegistry(activeID: a.id, workspaces: [WorkspaceDescriptor(context: a), WorkspaceDescriptor(context: b)]))
        let controller = WorkspaceController(store: store, defaultContext: a, startsServices: false)
        let old = controller.activeModel
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceIconURLProtocol.self]
        let iconStore = ModuleIconStore(cacheDirectory: a.cacheDirectory, session: URLSession(configuration: configuration))
        let iconID = UUID()
        let download = Task { try await iconStore.cacheIcon(from: URL(string: "https://test.invalid/icon")!, for: iconID) }
        try await controller.switchWorkspace(to: b.id)
        old.enqueueConfiguration(["value": "late A response"], fileName: "late.json")
        try await old.flushPersistence()
        try await download.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.configurationDirectory.appending(path: "late.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.configurationDirectory.appending(path: "late.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ModuleIconStore.cachedURL(for: iconID, cacheDirectory: a.cacheDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModuleIconStore.cachedURL(for: iconID, cacheDirectory: b.cacheDirectory).path))
        await controller.finishViewRetirement(old)
    }

    func testRegistryCommitFailureKeepsOldWorkspaceAndCredentials() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = makeContext(root: root, name: "A")
        let b = makeContext(root: root, name: "B")
        try writeState(a, moduleName: "A")
        try writeState(b, moduleName: "B")
        let failure = WorkspaceWriteFailure()
        let store = WorkspaceStore(registryURL: root.appending(path: "registry.json"), writeData: { data, url in
            if failure.enabled { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        try store.save(WorkspaceRegistry(activeID: a.id, workspaces: [WorkspaceDescriptor(context: a), WorkspaceDescriptor(context: b)]))
        let originalRegistry = try Data(contentsOf: store.registryURL)
        let controller = WorkspaceController(store: store, defaultContext: a, startsServices: false)
        let original = controller.activeModel
        original.githubToken = "unsaved A input"
        failure.enabled = true
        do { try await controller.switchWorkspace(to: b.id); XCTFail("Registry write should fail") }
        catch {}
        XCTAssertTrue(controller.activeModel === original)
        XCTAssertTrue(original.workspaceIsActive)
        XCTAssertFalse(original.isWorkspaceTransitioning)
        XCTAssertFalse(original.isWorking)
        XCTAssertEqual(original.githubToken, "unsaved A input")
        XCTAssertEqual(try Data(contentsOf: store.registryURL), originalRegistry)
        XCTAssertEqual(controller.registry.activeID, a.id)
    }

    func testNonCancellableTaskRejectsSwitchAndCancellableTaskIsJoined() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = makeContext(root: root, name: "A")
        let b = makeContext(root: root, name: "B")
        try writeState(a, moduleName: "A")
        try writeState(b, moduleName: "B")
        let store = WorkspaceStore(registryURL: root.appending(path: "registry.json"))
        try store.save(WorkspaceRegistry(activeID: a.id, workspaces: [WorkspaceDescriptor(context: a), WorkspaceDescriptor(context: b)]))
        let controller = WorkspaceController(store: store, defaultContext: a, startsServices: false)
        let old = controller.activeModel
        old.beginWork(.confirmingPublish)
        old.workActivity.canCancel = false
        do { try await controller.switchWorkspace(to: b.id); XCTFail("Commit phase cannot be interrupted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("不可取消")) }
        XCTAssertTrue(controller.activeModel === old)
        XCTAssertEqual(old.workActivity.kind, .confirmingPublish)
        old.endWork(.confirmingPublish)
        old.beginWork(.updatingModules)
        old.foregroundWorkTask = Task { @MainActor in
            defer { old.endWork(.updatingModules) }
            try? await Task.sleep(for: .seconds(30))
        }
        try await controller.switchWorkspace(to: b.id)
        XCTAssertTrue(old.foregroundWorkTask?.isCancelled == true)
        XCTAssertFalse(old.workActivity.isActive)
        XCTAssertEqual(controller.activeModel.workspaceID, b.id)
        await controller.finishViewRetirement(old)
    }

    func testInvalidTargetAndMigrationIntoOtherWorkspaceAreRejectedWithoutCopying() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = makeContext(root: root, name: "A")
        let b = makeContext(root: root, name: "B")
        try writeState(a, moduleName: "A")
        try writeState(b, moduleName: "B")
        let store = WorkspaceStore(registryURL: root.appending(path: "registry.json"))
        let registry = WorkspaceRegistry(activeID: a.id, workspaces: [WorkspaceDescriptor(context: a), WorkspaceDescriptor(context: b)])
        try store.save(registry)
        let controller = WorkspaceController(store: store, defaultContext: a, startsServices: false)
        let old = controller.activeModel
        let before = try Data(contentsOf: a.configurationDirectory.appending(path: "modules.json"))
        XCTAssertThrowsError(try store.validateRelocation(id: a.id, to: b.configurationDirectory, registry: registry))
        try Data("not JSON".utf8).write(to: b.configurationDirectory.appending(path: "modules.json"))
        do { try await controller.switchWorkspace(to: b.id); XCTFail("Corrupt target must fail") }
        catch {}
        XCTAssertTrue(controller.activeModel === old)
        XCTAssertFalse(old.isWorkspaceTransitioning)
        XCTAssertEqual(try Data(contentsOf: a.configurationDirectory.appending(path: "modules.json")), before)
    }

    func testNewWorkspaceStartsEmptyWithoutCopyingCredentialFiles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = makeContext(root: root, name: "A")
        try writeState(a, moduleName: "A")
        try LocalCredentialStore.saveGitHubToken("private A token", directory: a.configurationDirectory)
        let store = WorkspaceStore(registryURL: root.appending(path: "registry.json"))
        let registry = try store.create(name: "Empty", in: WorkspaceRegistry(activeID: a.id, workspaces: [WorkspaceDescriptor(context: a)]))
        let created = try XCTUnwrap(registry.workspaces.last)
        let model = AppModel(context: created.context, persistsOnInit: false)
        XCTAssertTrue(model.modules.isEmpty)
        XCTAssertTrue(model.modulePreviewDrafts.isEmpty)
        XCTAssertTrue(model.moduleTemplates.isEmpty)
        XCTAssertFalse(model.settings.webServerEnabled)
        XCTAssertFalse(model.settings.publishToGitHub)
        XCTAssertTrue(model.settings.publishToLocal)
        XCTAssertTrue(model.githubToken.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.configurationDirectory.appending(path: "credentials.encrypted").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.configurationDirectory.appending(path: "credentials.key").path))
    }

    func testBackupsAndRecoveryStayInsideTheirWorkspace() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = makeContext(root: root, name: "A")
        let b = makeContext(root: root, name: "B")
        try writeState(a, moduleName: "A original")
        try writeState(b, moduleName: "B original")
        let writerA = ConfigurationPersistenceWriter(directory: a.configurationDirectory)
        let writerB = ConfigurationPersistenceWriter(directory: b.configurationDirectory)
        writerA.enqueue([RelayModule(name: "A newer", sourceURL: "https://test.invalid/a.sgmodule", outputFileName: "A")], fileName: "modules.json")
        writerB.enqueue([RelayModule(name: "B newer", sourceURL: "https://test.invalid/b.sgmodule", outputFileName: "B")], fileName: "modules.json")
        try await writerA.flush()
        try await writerB.flush()
        try Data("corrupt".utf8).write(to: b.configurationDirectory.appending(path: "modules.json"))
        let recovered = PersistenceStore.loadModules(in: b.configurationDirectory, allowLegacyFallback: false)
        XCTAssertEqual(recovered.first?.name, "B original")
        let id = UUID()
        let filesA = ModuleFileStore(cacheDirectory: a.cacheDirectory, configurationDirectory: a.configurationDirectory)
        let filesB = ModuleFileStore(cacheDirectory: b.cacheDirectory, configurationDirectory: b.configurationDirectory)
        try await filesA.writeComponentOverride("A-one", id: id)
        try await filesA.writeComponentOverride("A-two", id: id)
        try await filesB.writeComponentOverride("B-one", id: id)
        try await filesB.writeComponentOverride("B-two", id: id)
        let backupsA = try FileManager.default.contentsOfDirectory(at: a.configurationDirectory.appending(path: "Backups/\(id.uuidString).module"), includingPropertiesForKeys: nil)
        let backupsB = try FileManager.default.contentsOfDirectory(at: b.configurationDirectory.appending(path: "Backups/\(id.uuidString).module"), includingPropertiesForKeys: nil)
        XCTAssertTrue(try String(contentsOf: XCTUnwrap(backupsA.first), encoding: .utf8).contains("A-one"))
        XCTAssertTrue(try String(contentsOf: XCTUnwrap(backupsB.first), encoding: .utf8).contains("B-one"))
    }

    func testStartupFallbackPreservesOtherRegisteredWorkspacesOnNextSave() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = makeContext(root: root, name: "A")
        let b = makeContext(root: root, name: "B")
        let c = makeContext(root: root, name: "C")
        try writeState(a, moduleName: "A")
        try writeState(b, moduleName: "B")
        try writeState(c, moduleName: "C")
        let store = WorkspaceStore(registryURL: root.appending(path: "registry.json"))
        try store.save(WorkspaceRegistry(activeID: b.id, workspaces: [a, b, c].map(WorkspaceDescriptor.init(context:))))
        let corrupted = Data("broken B configuration".utf8)
        try corrupted.write(to: b.configurationDirectory.appending(path: "modules.json"))
        let controller = WorkspaceController(store: store, defaultContext: a, startsServices: false)
        XCTAssertEqual(controller.activeModel.workspaceID, a.id)
        XCTAssertEqual(Set(controller.registry.workspaces.map(\.id)), [a.id, b.id, c.id])
        try controller.renameWorkspace(id: a.id, name: "Renamed A")
        let persisted = try store.load(defaultContext: a)
        XCTAssertEqual(Set(persisted.workspaces.map(\.id)), [a.id, b.id, c.id])
        XCTAssertEqual(try Data(contentsOf: b.configurationDirectory.appending(path: "modules.json")), corrupted)
    }

    func testWorkspaceDeadlineIncludesUnresponsiveTaskValueWait() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = makeContext(root: root, name: "A")
        try writeState(context, moduleName: "A")
        let model = AppModel(context: context, persistsOnInit: false)
        let gate = WorkspaceUnresponsiveGate()
        model.startupTask = Task { await gate.wait() }
        let start = ContinuousClock.now
        do {
            try await model.prepareForWorkspaceSwitch(timeout: .milliseconds(60))
            XCTFail("An unresponsive task must not let switching continue")
        } catch { XCTAssertTrue(error.localizedDescription.contains("尚未完成取消")) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertTrue(model.workspaceIsActive)
        model.resumeAfterWorkspaceSwitchFailure()
        XCTAssertFalse(model.isWorkspaceTransitioning)
        XCTAssertFalse(model.isWorking)
        await gate.release()
        await model.startupTask?.value
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func makeContext(root: URL, name: String) -> WorkspaceContext {
        WorkspaceContext(id: UUID(), name: name, configurationDirectory: root.appending(path: "\(name)/Config", directoryHint: .isDirectory),
                         cacheDirectory: root.appending(path: "\(name)/Cache", directoryHint: .isDirectory), allowsLegacyFallback: false)
    }

    private func writeState(_ context: WorkspaceContext, moduleName: String, id: UUID = UUID()) throws {
        try FileManager.default.createDirectory(at: context.configurationDirectory, withIntermediateDirectories: true)
        var settings = AppSettings()
        settings.publishToLocal = false
        settings.publishToGitHub = false
        settings.automaticallyPublish = false
        settings.automaticallyUpdateOnLaunch = false
        settings.webServerEnabled = false
        try write(settings, to: context.configurationDirectory.appending(path: "settings.json"))
        try write([RelayModule(id: id, name: moduleName, sourceURL: "https://test.invalid/\(moduleName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!).sgmodule", outputFileName: moduleName)],
                  to: context.configurationDirectory.appending(path: "modules.json"))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

private final class WorkspaceWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var enabled: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class WorkspaceIconURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(75)) { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([0x89, 0x50, 0x4e, 0x47]))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private actor WorkspaceUnresponsiveGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

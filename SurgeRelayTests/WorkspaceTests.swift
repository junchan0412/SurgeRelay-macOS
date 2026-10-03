import Foundation
import XCTest
@testable import SurgeRelay

@MainActor
final class WorkspaceTests: XCTestCase {
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
        XCTAssertFalse(model.settings.publishToLocal)
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

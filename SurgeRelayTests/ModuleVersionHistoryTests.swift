import Foundation
import XCTest
@testable import SurgeRelay

final class ModuleVersionHistoryTests: XCTestCase {
    func testConversionArchivesPreviousTextAndAssetsBeforeReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        let id = UUID()
        try await store.commitConversion(conversion("old", id: id), id: id)
        try await store.commitConversion(conversion("new", id: id), id: id)
        let versions = try await store.moduleVersions(id: id)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions[0].reason, .beforeUpdate)
        let old = try await store.readModuleVersion(id: id, versionID: versions[0].id)
        XCTAssertTrue(old.content.contains("old.example"))
        XCTAssertEqual(old.assets.map(\.data), [Data("old script".utf8)])
        _ = try await store.recordCurrentVersion(id: id, reason: .current)
        let after = try await store.moduleVersions(id: id)
        XCTAssertEqual(after.count, 2)
    }

    func testRestoreRestoresMatchingContentAndAssetsAndArchivesCurrentState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root.appending(path: "Cache"), configurationDirectory: root.appending(path: "Config"))
        let id = UUID()
        try await store.commitConversion(conversion("old", id: id), id: id)
        let saved = try await store.recordCurrentVersion(id: id, reason: .current)
        let old = try XCTUnwrap(saved)
        try await store.commitConversion(conversion("new", id: id), id: id)
        let currentValue = try await store.currentVersionContent(id: id)
        let current = try XCTUnwrap(currentValue)
        _ = try await store.restoreModuleVersion(id: id, versionID: old.id, expectedFingerprint: current.record.fingerprint)
        let restored = try await store.readComponent(id: id)
        let converted = try await store.readConvertedComponent(id: id)
        let assets = try await store.generatedAssetFiles(for: [id])
        XCTAssertTrue(restored.contains("old.example"))
        XCTAssertEqual(restored, converted)
        XCTAssertEqual(assets.map(\.data), [Data("old script".utf8)])
        let history = try await store.moduleVersions(id: id)
        XCTAssertTrue(history.contains { $0.fingerprint == current.record.fingerprint })
    }

    func testAssetOnlyChangeInvalidatesRestoreConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root)
        let id = UUID()
        try await store.commitConversion(conversion("old", id: id), id: id)
        let oldValue = try await store.recordCurrentVersion(id: id, reason: .current)
        let old = try XCTUnwrap(oldValue)
        try await store.replaceAssets([GeneratedAsset(relativePath: "assets/\(id.uuidString.lowercased())/old.js", data: Data("external new script".utf8))], id: id)
        do {
            _ = try await store.restoreModuleVersion(id: id, versionID: old.id, expectedFingerprint: old.fingerprint)
            XCTFail("Changing only a script must invalidate the comparison")
        } catch { XCTAssertTrue(error.localizedDescription.contains("重新比较")) }
        let assets = try await store.generatedAssetFiles(for: [id])
        XCTAssertEqual(assets.first?.data, Data("external new script".utf8))
    }

    func testCorruptHistoricalAssetCannotReplaceCurrentSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root)
        let id = UUID()
        try await store.commitConversion(conversion("old", id: id), id: id)
        let oldValue = try await store.recordCurrentVersion(id: id, reason: .current)
        let old = try XCTUnwrap(oldValue)
        try await store.commitConversion(conversion("new", id: id), id: id)
        let currentValue = try await store.currentVersionContent(id: id)
        let current = try XCTUnwrap(currentValue)
        let asset = root.appending(path: "ModuleVersions/\(id.uuidString.lowercased())/\(old.id.uuidString.lowercased())/Assets/old.js")
        try Data("corrupt".utf8).write(to: asset)
        do {
            _ = try await store.restoreModuleVersion(id: id, versionID: old.id, expectedFingerprint: current.record.fingerprint)
            XCTFail("A corrupt archive must not be restored")
        } catch { XCTAssertTrue(error.localizedDescription.contains("校验失败")) }
        let retained = try await store.currentVersionContent(id: id)
        XCTAssertEqual(retained?.record.fingerprint, current.record.fingerprint)
    }

    func testHistoryDeduplicatesUnchangedStateAndKeepsTwentyVersions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore(cacheDirectory: root, configurationDirectory: root)
        let id = UUID()
        for index in 0..<25 {
            try await store.writeComponentOverride("version-\(index)\n", id: id)
            _ = try await store.recordCurrentVersion(id: id, reason: .manualEdit)
        }
        let before = try await store.moduleVersions(id: id)
        _ = try await store.recordCurrentVersion(id: id, reason: .current)
        let after = try await store.moduleVersions(id: id)
        XCTAssertEqual(before.count, ModuleFileStore.maximumVersionCount)
        XCTAssertEqual(before, after)
        let latest = try await store.readModuleVersion(id: id, versionID: after[0].id)
        XCTAssertTrue(latest.content.contains("version-24"))
        XCTAssertTrue(after.allSatisfy { $0.byteCount > 0 && !$0.fingerprint.isEmpty })
    }

    func testEveryRestoreCommitBoundaryRecoversOneCompleteGeneration() async throws {
        for phase in [ModuleRestorePhase.prepared, .overrideInstalled, .snapshotInstalled, .metadataPending, .committed, .finalized] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = root.appending(path: "Cache")
            let config = root.appending(path: "Config")
            let original = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
            let id = UUID()
            try await original.commitConversion(conversion("old", id: id), id: id)
            let targetValue = try await original.recordCurrentVersion(id: id, reason: .current)
            let target = try XCTUnwrap(targetValue)
            try await original.commitConversion(conversion("new", id: id), id: id)
            let currentValue = try await original.currentVersionContent(id: id)
            let current = try XCTUnwrap(currentValue)
            try await original.writeCombined("previous combined data")
            let interrupted = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config, restoreInterruption: {
                if $0 == phase { throw VersionRestoreCrash.interrupted }
            })
            do {
                _ = try await interrupted.restoreModuleVersion(id: id, versionID: target.id, expectedFingerprint: current.record.fingerprint)
                XCTFail("Expected interruption at \(phase)")
            } catch {}
            let restarted = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
            let needsRebuild = try await restarted.recoverInterruptedVersionRestores()
            XCTAssertTrue(needsRebuild)
            let expected = phase == .committed || phase == .finalized ? "old" : "new"
            let content = try await restarted.readComponent(id: id)
            let converted = try await restarted.readConvertedComponent(id: id)
            let assets = try await restarted.generatedAssetFiles(for: [id])
            XCTAssertTrue(content.contains("\(expected).example"), "boundary: \(phase)")
            XCTAssertEqual(content, converted)
            XCTAssertEqual(assets.map(\.data), [Data("\(expected) script".utf8)])
            do { _ = try await restarted.readCombined(); XCTFail("Old combined output must not be readable") }
            catch { XCTAssertTrue(error.localizedDescription.contains("重建")) }
            let pending = try await restarted.pendingVersionRestoreModuleIDs()
            XCTAssertEqual(pending, phase == .committed || phase == .finalized ? [id] : [])
            try await restarted.writeCombined("rebuilt combined data")
            try await restarted.acknowledgeVersionRestoreMetadata(ids: pending)
            let combined = try await restarted.readCombined()
            XCTAssertEqual(combined, Data("rebuilt combined data".utf8))
        }
    }

    func testRecoveryCanItselfBeInterruptedAndRepeatedSafely() async throws {
        for recoveryPhase in [ModuleRestorePhase.recoverySnapshotInstalled, .recoveryOverrideInstalled] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = root.appending(path: "Cache")
            let config = root.appending(path: "Config")
            let id = UUID()
            let store = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
            try await store.commitConversion(conversion("old", id: id), id: id)
            let versionValue = try await store.recordCurrentVersion(id: id, reason: .current)
            let version = try XCTUnwrap(versionValue)
            try await store.commitConversion(conversion("new", id: id), id: id)
            let currentValue = try await store.currentVersionContent(id: id)
            let current = try XCTUnwrap(currentValue)
            let crash = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config, restoreInterruption: {
                if $0 == .snapshotInstalled { throw VersionRestoreCrash.interrupted }
            })
            do { _ = try await crash.restoreModuleVersion(id: id, versionID: version.id, expectedFingerprint: current.record.fingerprint) }
            catch {}
            let recoveryCrash = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config, restoreInterruption: {
                if $0 == recoveryPhase { throw VersionRestoreCrash.interrupted }
            })
            do { _ = try await recoveryCrash.readComponent(id: id); XCTFail("Interrupted recovery must not return mixed content") }
            catch {}
            let restarted = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
            let content = try await restarted.readComponent(id: id)
            let assets = try await restarted.generatedAssetFiles(for: [id])
            XCTAssertTrue(content.contains("new.example"))
            XCTAssertEqual(assets.map(\.data), [Data("new script".utf8)])
        }
    }

    func testFinalizedJournalCannotOverwriteLaterManualEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "Cache")
        let config = root.appending(path: "Config")
        let id = UUID()
        let store = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
        try await store.commitConversion(conversion("old", id: id), id: id)
        let versionValue = try await store.recordCurrentVersion(id: id, reason: .current)
        let version = try XCTUnwrap(versionValue)
        let crash = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config, restoreInterruption: {
            if $0 == .finalized { throw VersionRestoreCrash.interrupted }
        })
        do { _ = try await crash.restoreModuleVersion(id: id, versionID: version.id, expectedFingerprint: version.fingerprint) }
        catch {}
        let restarted = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
        try await restarted.writeComponentOverride("[Rule]\nDOMAIN,later-edit.example,DIRECT", id: id)
        let again = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
        let content = try await again.readComponent(id: id)
        XCTAssertTrue(content.contains("later-edit.example"))
    }

    func testInterruptedSecondRestoreRetainsEarlierPendingMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "Cache")
        let config = root.appending(path: "Config")
        let id = UUID()
        let store = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
        try await store.commitConversion(conversion("first", id: id), id: id)
        let firstValue = try await store.recordCurrentVersion(id: id, reason: .current)
        let first = try XCTUnwrap(firstValue)
        try await store.commitConversion(conversion("second", id: id), id: id)
        let secondValue = try await store.recordCurrentVersion(id: id, reason: .current)
        let second = try XCTUnwrap(secondValue)
        _ = try await store.restoreModuleVersion(id: id, versionID: first.id, expectedFingerprint: second.fingerprint)
        let priorPending = try await store.pendingVersionRestoreModuleIDs()
        XCTAssertEqual(priorPending, [id])
        let current = try await store.currentVersionState(id: id)
        let interrupted = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config, restoreInterruption: {
            if $0 == .metadataPending { throw VersionRestoreCrash.interrupted }
        })
        do { _ = try await interrupted.restoreModuleVersion(id: id, versionID: second.id, expectedFingerprint: current.fingerprint) }
        catch {}
        let restarted = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
        let pending = try await restarted.pendingVersionRestoreModuleIDs()
        XCTAssertEqual(pending, [id])
        let recovered = try await restarted.readComponent(id: id)
        XCTAssertTrue(recovered.contains("first.example"))
    }

    func testCorruptCurrentBodyCanBeRestoredWithRawBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "Cache")
        let config = root.appending(path: "Config")
        let id = UUID()
        let store = ModuleFileStore(cacheDirectory: cache, configurationDirectory: config)
        try await store.commitConversion(conversion("old", id: id), id: id)
        let versionValue = try await store.recordCurrentVersion(id: id, reason: .current)
        let version = try XCTUnwrap(versionValue)
        let corrupt = Data([0xff, 0xfe, 0x00])
        try corrupt.write(to: cache.appending(path: "Snapshots/\(id.uuidString.lowercased())/Content.cache"))
        let current = try await store.currentVersionState(id: id)
        XCTAssertNotNil(current.problem)
        XCTAssertNil(current.content)
        _ = try await store.restoreModuleVersion(id: id, versionID: version.id, expectedFingerprint: current.fingerprint)
        let restored = try await store.readComponent(id: id)
        XCTAssertTrue(restored.contains("old.example"))
        let backups = try FileManager.default.contentsOfDirectory(at: config.appending(path: "Backups/DamagedModule/\(id.uuidString.lowercased())"), includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try Data(contentsOf: backup.appending(path: "Content.cache")), corrupt)
    }

    private func conversion(_ name: String, id: UUID) -> ConversionResult {
        ConversionResult(content: "#!name=History\n[Rule]\nDOMAIN,\(name).example,DIRECT\n", requestURL: URL(string: "https://test.invalid/module")!,
                         assets: [GeneratedAsset(relativePath: "assets/\(id.uuidString.lowercased())/\(name).js", data: Data("\(name) script".utf8))])
    }
}

@MainActor
final class ModuleVersionRuntimeTests: XCTestCase {
    func testRestorePreservesNewDraftAndPublishedFilesAndRebuildsCombinedCache() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel()
        let module = RelayModule(name: "History", sourceURL: "https://test.invalid/history.sgmodule", outputFileName: "History", storageTargets: [.local, .gitHub], isEnabled: true)
        model.modules = [module]
        model.settings.combinedModuleEnabled = true
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = true
        model.settings.localModuleDirectory = root.path
        model.settings.automaticallyPublish = true
        let published = root.appending(path: module.publishedRelativePath)
        let publishedData = Data("published file must remain unchanged".utf8)
        try publishedData.write(to: published)
        try await model.fileStore.commitConversion(ConversionResult(content: "[Rule]\nDOMAIN,old.example,DIRECT", requestURL: URL(string: module.sourceURL)!), id: module.id)
        let versionValue = try await model.fileStore.recordCurrentVersion(id: module.id, reason: .current)
        let version = try XCTUnwrap(versionValue)
        try await model.fileStore.commitConversion(ConversionResult(content: "[Rule]\nDOMAIN,new.example,DIRECT", requestURL: URL(string: module.sourceURL)!), id: module.id)
        let comparison = try await model.compareModuleVersion(moduleID: module.id, versionID: version.id)
        model.modulePreviewDrafts[module.id] = ModulePreviewDraft(text: "new unsaved draft", savedText: "current baseline")
        try await model.restoreModuleVersion(comparison)
        XCTAssertEqual(model.modulePreviewDrafts[module.id]?.text, "new unsaved draft")
        XCTAssertEqual(try Data(contentsOf: published), publishedData)
        XCTAssertNil(model.automaticPublishRunsAt)
        let combined = try await model.fileStore.readCombined()
        XCTAssertTrue(String(decoding: combined, as: UTF8.self).contains("old.example"))
        XCTAssertFalse(String(decoding: combined, as: UTF8.self).contains("new.example"))
        XCTAssertFalse(model.isWorking)
        XCTAssertTrue(model.statusMessage.contains("未发布"))
        model.modulePreviewDrafts.removeValue(forKey: module.id)
        await model.flushPreviewDrafts()
        try await model.fileStore.removeComponent(id: module.id)
        try await model.fileStore.removeAssets(id: module.id)
        try await model.fileStore.removeModuleVersions(id: module.id)
        try await model.fileStore.removeCombined()
    }

    func testHistoryListingAndRestoreRemainAvailableWhenCurrentBodyIsCorrupt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Corrupt cache test", configurationDirectory: root.appending(path: "Config"),
                                       cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        let module = RelayModule(name: "Recoverable", sourceURL: "https://test.invalid/recoverable.sgmodule", outputFileName: "Recoverable")
        model.modules = [module]
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = false
        model.settings.automaticallyPublish = false
        try await model.fileStore.commitConversion(ConversionResult(content: "[Rule]\nFINAL,DIRECT", requestURL: URL(string: module.sourceURL)!), id: module.id)
        _ = try await model.fileStore.recordCurrentVersion(id: module.id, reason: .current)
        try Data([0xff, 0xfe]).write(to: context.cacheDirectory.appending(path: "Snapshots/\(module.id.uuidString.lowercased())/Content.cache"))
        let versions = try await model.moduleVersions(moduleID: module.id)
        XCTAssertFalse(versions.isEmpty)
        let comparison = try await model.compareModuleVersion(moduleID: module.id, versionID: versions[0].id)
        XCTAssertNotNil(comparison.currentContentProblem)
        try await model.restoreModuleVersion(comparison)
        let content = try await model.fileStore.readComponent(id: module.id)
        XCTAssertTrue(content.contains("FINAL,DIRECT"))
        let pending = try await model.fileStore.pendingVersionRestoreModuleIDs()
        XCTAssertTrue(pending.isEmpty)
        model.persistenceFeedbackTask?.cancel()
    }

    func testRestoreRejectsBusyAndChangedModuleMetadata() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = AppModel()
        let module = RelayModule(name: "History Gate", sourceURL: "https://test.invalid/history-gate.sgmodule", outputFileName: "HistoryGate")
        model.modules = [module]
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = false
        model.settings.automaticallyPublish = false
        try await model.fileStore.writeComponent("[Rule]\nFINAL,DIRECT", id: module.id)
        let versionValue = try await model.fileStore.recordCurrentVersion(id: module.id, reason: .current)
        let version = try XCTUnwrap(versionValue)
        let comparison = try await model.compareModuleVersion(moduleID: module.id, versionID: version.id)
        model.beginWork(.savingPreview)
        do { try await model.restoreModuleVersion(comparison); XCTFail("Busy restore must fail") }
        catch { XCTAssertEqual(error as? PreviewContentSaveError, .busy) }
        model.endWork(.savingPreview)
        model.modules[0].name = "New metadata"
        do { try await model.restoreModuleVersion(comparison); XCTFail("Stale metadata must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("重新比较")) }
        XCTAssertFalse(model.isWorking)
        try await model.fileStore.removeComponent(id: module.id)
        try await model.fileStore.removeModuleVersions(id: module.id)
    }
}

private enum VersionRestoreCrash: Error { case interrupted }

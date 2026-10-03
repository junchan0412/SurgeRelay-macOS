import Foundation
import Observation

enum WebManagementController {
    static func accessModeTitle(settings: AppSettings) -> String {
        settings.webServerAllowRemoteAccess ? "局域网" : "仅本机"
    }

    static func host(settings: AppSettings, processInfo: ProcessInfo = .processInfo) -> String {
        guard settings.webServerAllowRemoteAccess else { return "127.0.0.1" }
        var host = processInfo.hostName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if !host.contains(".") { host += ".local" }
        return host
    }

    static func url(settings: AppSettings, accessToken: String, includingToken: Bool) -> URL? {
        guard settings.webServerEnabled else { return nil }
        return WebManagementURLFactory.url(
            host: host(settings: settings),
            port: settings.webServerPort,
            accessToken: accessToken,
            includingToken: includingToken
        )
    }
}

final class WebEventPayloadCache: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = true
    @MainActor private var cached: String?
    @MainActor private let build: () -> String

    @MainActor
    init(build: @escaping @MainActor () -> String) {
        self.build = build
    }

    @MainActor
    func payload() -> String {
        let needsBuild = lock.withLock {
            let result = invalidated
            invalidated = false
            return result
        }
        if !needsBuild, let cached { return cached }
        let payload = withObservationTracking { build() } onChange: { [weak self] in
            guard let self else { return }
            lock.withLock { invalidated = true }
        }
        cached = payload
        return payload
    }
}

struct WebCoreSnapshot: Sendable {
    let modules: [RelayModule]
    let moduleRevision: UInt64
    let activity: WebActivitySnapshot
    let settings: AppSettings
    let localFolders: [String]
    let githubFolders: [String]
    let historyCount: Int
    let recentHistory: [UpdateHistoryEntry]
    let workspaceID: String
    let workspaceName: String
    let isLegacyWorkspace: Bool
    let cacheDirectory: URL
    let runtimeID: String
    let revision: UInt64
}

struct WebActivitySnapshot: Sendable {
    let workspaceID: String
    let runtimeID: String
    let revision: UInt64
    let isWorking: Bool
    let workActivity: WorkActivity
    let statusMessage: String
    let completedCount: Int
    let totalCount: Int
    let synchronizingModuleIDs: Set<UUID>
    let automaticPublishScheduledAt: Date?
    let automaticPublishRunsAt: Date?
    let history: [UpdateHistoryEntry]
    let githubSettings: GitHubSettings
    let error: String?
    let cancellationRequested: Bool
}

struct WebManagementSnapshot: Sendable {
    let state: WebCoreSnapshot
    let activity: WebActivitySnapshot
    let includesLegacy: Bool
}

struct WebPreparedEventPayload: Sendable {
    let state: WebStatePayload
    let activity: WebActivityEventPayload
    let includesLegacy: Bool
}

private final class WebSnapshotInvalidation: @unchecked Sendable {
    private let lock = NSLock()
    private var dirty = true
    func invalidate() { lock.withLock { dirty = true } }
    func consume() -> Bool { lock.withLock { let value = dirty; dirty = false; return value } }
}

@MainActor
final class WebManagementSnapshotSource {
    private weak var model: AppModel?
    private let coreInvalidation = WebSnapshotInvalidation()
    private let activityInvalidation = WebSnapshotInvalidation()
    private var state: WebCoreSnapshot?
    private var activity: WebActivitySnapshot?

    init(model: AppModel) { self.model = model }

    static func capture(model: AppModel) -> WebManagementSnapshot {
        model.webSnapshotRevision &+= 1
        let revision = model.webSnapshotRevision
        let activity = captureActivity(model: model, revision: revision)
        return WebManagementSnapshot(state: captureCore(model: model, revision: revision, activity: activity),
            activity: activity, includesLegacy: false)
    }

    func snapshot(includingLegacy: Bool) throws -> WebManagementSnapshot {
        try Task.checkCancellation()
        guard let model else { throw CancellationError() }
        let coreChanged = coreInvalidation.consume()
        let activityChanged = activityInvalidation.consume()
        if coreChanged || activityChanged || state == nil || activity == nil {
            model.webSnapshotRevision &+= 1
            let revision = model.webSnapshotRevision
            let activityInvalidation = activityInvalidation
            activity = withObservationTracking {
                Self.captureActivity(model: model, revision: revision)
            } onChange: { activityInvalidation.invalidate() }
            if coreChanged || state == nil {
                let coreInvalidation = coreInvalidation
                state = withObservationTracking {
                    Self.captureCore(model: model, revision: revision, activity: activity!)
                } onChange: { coreInvalidation.invalidate() }
            }
        }
        return WebManagementSnapshot(state: state!, activity: activity!, includesLegacy: includingLegacy)
    }

    private static func captureCore(model: AppModel, revision: UInt64, activity: WebActivitySnapshot) -> WebCoreSnapshot {
        WebCoreSnapshot(modules: model.modules, moduleRevision: model.moduleRevision, activity: activity, settings: model.settings,
            localFolders: model.localModuleOutputFolders, githubFolders: model.githubModuleOutputFolders,
            historyCount: model.updateHistory.count,
            recentHistory: model.updateHistory.prefix(4).map { entry in var summary = entry; summary.stageMetrics = nil; return summary },
            workspaceID: model.workspaceID.uuidString, workspaceName: model.workspaceName,
            isLegacyWorkspace: model.isLegacyWorkspace, cacheDirectory: model.cacheDirectoryURL,
            runtimeID: model.runtimeID.uuidString, revision: revision)
    }

    private static func captureActivity(model: AppModel, revision: UInt64) -> WebActivitySnapshot {
        WebActivitySnapshot(workspaceID: model.workspaceID.uuidString, runtimeID: model.runtimeID.uuidString,
            revision: revision, isWorking: model.isWorking, workActivity: model.workActivity,
            statusMessage: model.statusMessage, completedCount: model.synchronizationCompletedCount,
            totalCount: model.synchronizationTotalCount, synchronizingModuleIDs: model.synchronizingModuleIDs,
            automaticPublishScheduledAt: model.automaticPublishScheduledAt,
            automaticPublishRunsAt: model.automaticPublishRunsAt, history: model.updateHistory,
            githubSettings: model.settings.github, error: model.presentedError,
            cancellationRequested: model.workCancellationRequested)
    }
}

actor WebManagementJSONEncoder {
    static let http = WebManagementJSONEncoder()
    private var state: WebEventMessage?
    private var activityMessage: WebEventMessage?
    private var legacy: WebEventMessage?
    private var corePayload: WebStatePayload?
    private var activityPayload: WebActivityEventPayload?
    private var encodedCorePayload: WebStatePayload?
    private var encodedActivityPayload: WebActivityEventPayload?
    private var coreSnapshot: WebCoreSnapshot?
    private var activitySnapshot: WebActivitySnapshot?
    private var cachedProjection: (runtimeID: String, moduleRevision: UInt64, settings: AppSettings, cacheDirectory: URL, modules: [WebModulePayload])?
    private var cachedSummary: (runtimeID: String, moduleRevision: UInt64, combinedEnabled: Bool, value: ModuleCollectionSummary)?

    func encodeState(_ snapshot: WebManagementSnapshot) throws -> Data {
        try Task.checkCancellation()
        let summary = summary(for: snapshot.state)
        let activity = WebManagementStateBuilder.activityPayload(snapshot: snapshot.activity, core: snapshot.state, summary: summary)
        let payload = try prepareState(core: snapshot.state, activity: activity, summary: summary)
        return try Self.encodeJSON(payload)
    }

    func activity(_ snapshot: WebManagementSnapshot) throws -> WebActivityEventPayload {
        try Task.checkCancellation()
        let payload = WebManagementStateBuilder.activityPayload(snapshot: snapshot.activity, core: snapshot.state,
            summary: summary(for: snapshot.state))
        try Task.checkCancellation()
        return WebActivityEventPayload(workspaceID: snapshot.activity.workspaceID, runtimeID: snapshot.activity.runtimeID,
            revision: snapshot.activity.revision, activity: payload)
    }

    func encode(_ snapshot: WebManagementSnapshot) throws -> WebEventPayload {
        try encode(prepare(snapshot))
    }

    func prepare(_ snapshot: WebManagementSnapshot) throws -> WebPreparedEventPayload {
        try Task.checkCancellation()
        if coreSnapshot == nil || snapshot.state.revision > coreSnapshot!.revision { coreSnapshot = snapshot.state }
        if activitySnapshot == nil || snapshot.activity.revision > activitySnapshot!.revision { activitySnapshot = snapshot.activity }
        let core = coreSnapshot!
        let currentActivity = activitySnapshot!
        let summary = summary(for: core)
        if activityPayload == nil || currentActivity.revision > activityPayload!.revision {
            let payload = WebManagementStateBuilder.activityPayload(snapshot: currentActivity, core: core, summary: summary)
            activityPayload = WebActivityEventPayload(workspaceID: currentActivity.workspaceID, runtimeID: currentActivity.runtimeID,
                revision: currentActivity.revision, activity: payload)
        }
        if corePayload == nil || core.revision > corePayload!.revision! {
            let capturedActivity = WebManagementStateBuilder.activityPayload(snapshot: core.activity, core: core, summary: summary)
            corePayload = try prepareState(core: core, activity: capturedActivity, summary: summary)
        }
        try Task.checkCancellation()
        return WebPreparedEventPayload(state: corePayload!, activity: activityPayload!, includesLegacy: snapshot.includesLegacy)
    }

    func encode(_ prepared: WebPreparedEventPayload) throws -> WebEventPayload {
        try Task.checkCancellation()
        if state == nil || prepared.state.revision! > state!.revision! {
            state = WebEventMessage(data: try Self.encodeJSON(prepared.state), revision: prepared.state.revision)
            encodedCorePayload = prepared.state
        }
        if activityMessage == nil || prepared.activity.revision > activityMessage!.revision! {
            activityMessage = WebEventMessage(data: try Self.encodeJSON(prepared.activity), revision: prepared.activity.revision)
            encodedActivityPayload = prepared.activity
        }
        if prepared.includesLegacy {
            let latestActivity = encodedActivityPayload!
            if latestActivity.revision <= state!.revision! {
                legacy = state
            } else if legacy == nil || latestActivity.revision > legacy!.revision! {
                var current = encodedCorePayload!
                current.activity = latestActivity.activity
                current.revision = latestActivity.revision
                legacy = WebEventMessage(data: try Self.encodeJSON(current), revision: current.revision)
            }
        } else { legacy = nil }
        try Task.checkCancellation()
        return WebEventPayload(state: state!, activity: activityMessage, legacyState: legacy)
    }

    private func prepareState(core: WebCoreSnapshot, activity: WebActivityPayload, summary: ModuleCollectionSummary) throws -> WebStatePayload {
        let modules: [WebModulePayload]
        if let cachedProjection, cachedProjection.runtimeID == core.runtimeID,
           cachedProjection.moduleRevision == core.moduleRevision, cachedProjection.settings == core.settings,
           cachedProjection.cacheDirectory == core.cacheDirectory {
            modules = cachedProjection.modules
        } else {
            modules = try WebManagementStateBuilder.moduleProjection(snapshot: core)
            cachedProjection = (core.runtimeID, core.moduleRevision, core.settings, core.cacheDirectory, modules)
        }
        try Task.checkCancellation()
        return WebManagementStateBuilder.payload(snapshot: core, activity: activity, summary: summary, modules: modules)
    }

    private func summary(for core: WebCoreSnapshot) -> ModuleCollectionSummary {
        if let cachedSummary, cachedSummary.runtimeID == core.runtimeID,
           cachedSummary.moduleRevision == core.moduleRevision,
           cachedSummary.combinedEnabled == core.settings.combinedModuleEnabled { return cachedSummary.value }
        let summary = ModuleCollectionSummary(modules: core.modules) {
            ModuleRefreshPlanner.isUpdateable($0, combinedModuleEnabled: core.settings.combinedModuleEnabled)
        }
        cachedSummary = (core.runtimeID, core.moduleRevision, core.settings.combinedModuleEnabled, summary)
        return summary
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try Task.checkCancellation()
        return data
    }
}

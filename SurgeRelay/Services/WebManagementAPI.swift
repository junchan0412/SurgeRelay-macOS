import Foundation

@MainActor
enum WebManagementAPI {
    static func response(for request: WebHTTPRequest, model: AppModel) async -> WebHTTPResponse {
        if !request.path.hasPrefix("/api/") {
            return WebManagementAssets.assetResponse(for: request.path)
        }

        do {
            if !["/api/state", "/api/session", "/api/source/name"].contains(request.path) {
                if let workspace = request.headers["x-relay-workspace"],
                   workspace.lowercased() != model.workspaceID.uuidString.lowercased() {
                    throw PreviewContentSaveError.changed
                }
                if request.method != "GET", !model.isLegacyWorkspace, request.headers["x-relay-workspace"] == nil {
                    throw PreviewContentSaveError.changed
                }
            }
            switch (request.method, request.path) {
            case ("POST", "/api/session"):
                return .json(
                    ActionPayload(ok: true, message: "Web 管理会话已建立。"),
                    headers: [
                        "Cache-Control": "no-store",
                        "Set-Cookie": WebRequestSecurity.sessionCookieHeader(accessToken: model.webAccessToken)
                    ]
                )
            case ("GET", "/api/state"):
                let snapshot = WebManagementSnapshotSource.capture(model: model)
                let data = try await WebManagementJSONEncoder.http.encodeState(snapshot)
                return WebHTTPResponse(status: 200, reason: "OK", headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"], body: data)
            case ("GET", "/api/activity"):
                let snapshot = WebManagementSnapshotSource.capture(model: model)
                let event = try await WebManagementJSONEncoder.http.activity(snapshot)
                var payload = event.activity
                payload.runtimeID = event.runtimeID
                payload.revision = event.revision
                payload.workspaceID = event.workspaceID
                return .json(payload)
            case ("GET", "/api/history"):
                return .json(model.updateHistory)
            case ("POST", "/api/activity/error/dismiss"):
                model.presentedError = nil
                return .json(ActionPayload(ok: true, message: "已清除错误提示。"))
            case ("GET", "/api/publishing"):
                return .json(WebPublishingPayload(attempt: model.selectedPublishAttempt,
                    canPublishToGitHub: model.settings.publishToGitHub && model.settings.github.isConfigured,
                    localEnabled: model.settings.publishToLocal))
            case ("POST", "/api/publish/preview"):
                return .json(try await model.webPublishPreview(request.decodeBody(WebPublishPreviewRequest.self)))
            case ("POST", "/api/publish"):
                let body = try request.decodeBody(WebActionTokenRequest.self)
                return .json(try await model.confirmWebPublish(token: body.token))
            case ("POST", "/api/update-all"):
                let admission = model.updateAdmission
                guard admission.isAccepted else {
                    return .json(
                        ActionPayload(ok: false, message: admission.message),
                        status: 409,
                        reason: "Conflict"
                    )
                }
                model.startUpdateAll()
                return .json(ActionPayload(ok: true, message: admission.message), status: 202, reason: "Accepted")
            case ("POST", "/api/cancel-work"):
                guard model.workActivity.isActive, model.workActivity.canCancel else {
                    return .json(
                        ActionPayload(ok: false, message: "当前没有可取消的任务。"),
                        status: 409,
                        reason: "Conflict"
                    )
                }
                let accepted = model.cancelCurrentWork()
                return .json(
                    ActionPayload(ok: accepted, message: model.statusMessage),
                    status: accepted ? 202 : 409,
                    reason: accepted ? "Accepted" : "Conflict"
                )
            case ("POST", "/api/modules"):
                guard !model.isWorking else { throw PreviewContentSaveError.busy }
                let mutation = try request.decodeBody(WebModuleMutation.self)
                try model.addModule(from: mutation.draft(
                    defaultStorageLocation: .preferredDefault(
                        publishToLocal: model.settings.publishToLocal
                    )
                ))
                try await model.flushPersistence()
                return .json(ActionPayload(ok: true, message: model.statusMessage), status: 201, reason: "Created")
            case ("POST", "/api/source/name"):
                let payload = try request.decodeBody(WebSourceNameRequest.self)
                return .json(try await sourceNamePayload(for: payload.url))
            case ("GET", "/api/combined/preview"):
                return .text(try await model.combinedPreviewContent())
            default:
                return try await moduleResponse(for: request, model: model)
            }
        } catch let error as PreviewContentSaveError {
            return .error(status: error == .changed ? 412 : 409, message: error.localizedDescription)
        } catch let error as WebAPIError {
            return .error(status: error.status, message: error.localizedDescription)
        } catch let error as RelayError {
            let status = switch error {
            case .duplicateSourceURL: 409
            default: 400
            }
            return .error(status: status, message: error.localizedDescription)
        } catch {
            return .error(status: 400, message: error.localizedDescription)
        }
    }

    static func previewETag(for content: String) -> String {
        "\"\(Data(content.utf8).sha256String)\""
    }

    static func previewContentHash(fromIfMatch header: String?) throws -> String? {
        guard let header else { return nil }
        let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.utf8.count == 66 else {
            throw PreviewContentSaveError.changed
        }
        let hash = String(value.dropFirst().dropLast())
        guard hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw PreviewContentSaveError.changed
        }
        return hash
    }

    static func sourceNamePayload(
        for sourceURL: String,
        fetchData: @Sendable (URLRequest) async throws -> Data = BoundedRemoteDataFetcher.sourceNameLookup.data(for:)
    ) async throws -> WebSourceNamePayload {
        guard let url = ModuleEditorSourceNameLookup.remoteURL(from: sourceURL) else {
            throw WebAPIError.invalidSourceURL
        }
        try BoundedRemoteDataFetcher.validateRemoteRequest(URLRequest(url: url))
        let name = try await ModuleEditorSourceNameLookup.resolvedName(
            from: sourceURL,
            fetchData: fetchData
        )
        return WebSourceNamePayload(name: name)
    }

    private static func moduleResponse(for request: WebHTTPRequest, model: AppModel) async throws -> WebHTTPResponse {
        if request.method != "GET", model.isWorking { throw PreviewContentSaveError.busy }
        let components = request.path.split(separator: "/").map(String.init)
        guard components.count >= 3, components[0] == "api", components[1] == "modules",
              let id = UUID(uuidString: components[2]),
              let module = model.modules.first(where: { $0.id == id }) else {
            throw WebAPIError.moduleNotFound
        }

        if components.count == 3 {
            switch request.method {
            case "PUT":
                let mutation = try request.decodeBody(WebModuleMutation.self)
                try model.updateModule(id: id, from: mutation.draft(existing: module))
                try await model.flushPersistence()
                return .json(ActionPayload(ok: true, message: model.statusMessage))
            case "DELETE":
                await model.deleteModule(id: id)
                try await model.flushPersistence()
                return .json(ActionPayload(ok: true, message: model.statusMessage))
            default:
                throw WebAPIError.methodNotAllowed
            }
        }

        if components[3] == "versions" {
            if request.method == "GET", components.count == 4 {
                return .json(try await model.moduleVersions(moduleID: id))
            }
            guard components.count >= 5, let versionID = UUID(uuidString: components[4]) else { throw WebAPIError.invalidBody }
            if request.method == "GET", components.count == 5 {
                let comparison = try await model.compareModuleVersion(moduleID: id, versionID: versionID)
                return .json(WebVersionComparisonPayload(token: try model.webActionTickets.storeVersion(comparison),
                    version: comparison.version, diff: comparison.diff, changedAssets: comparison.changedAssets))
            }
            if request.method == "POST", components.count == 6, components[5] == "restore" {
                let body = try request.decodeBody(WebActionTokenRequest.self)
                let comparison = try model.webActionTickets.consumeVersion(body.token, moduleID: id, versionID: versionID)
                let current = try await model.compareModuleVersion(moduleID: id, versionID: versionID)
                guard current.expectedFingerprint == comparison.expectedFingerprint, current.module == comparison.module else {
                    throw PreviewContentSaveError.changed
                }
                try await model.restoreModuleVersion(comparison)
                return .json(ActionPayload(ok: true, message: model.statusMessage))
            }
            throw WebAPIError.methodNotAllowed
        }

        switch (request.method, components[3]) {
        case ("POST", "enabled"):
            let payload = try request.decodeBody(WebEnabledRequest.self)
            model.setModuleIncludedInCombined(id: id, included: payload.enabled)
            try await model.flushPersistence()
                return .json(ActionPayload(ok: true, message: model.statusMessage))
        case ("POST", "update"):
            let admission = model.updateAdmission(for: module)
            guard admission.isAccepted else {
                return .json(
                    ActionPayload(ok: false, message: admission.message),
                    status: 409,
                    reason: "Conflict"
                )
            }
            model.startUpdate(moduleID: id)
            return .json(ActionPayload(ok: true, message: admission.message), status: 202, reason: "Accepted")
        case ("GET", "sync-conflict"):
            let comparison = try await model.moduleSyncComparison(moduleID: id)
            let token = try model.webActionTickets.storeComparison(comparison)
            return .json(WebSyncPayload(token: token, state: comparison.metadata.comparisonState.rawValue,
                stateTitle: comparison.metadata.comparisonState.title,
                localContent: String(decoding: comparison.localData, as: UTF8.self),
                gitHubContent: String(decoding: comparison.githubData, as: UTF8.self),
                localUpdatedAt: comparison.metadata.localUpdatedAt, gitHubUpdatedAt: comparison.metadata.githubUpdatedAt,
                diff: comparison.diff))
        case ("POST", "sync-conflict"):
            let body = try request.decodeBody(WebSyncResolutionRequest.self)
            guard ["localToGitHub", "gitHubToLocal"].contains(body.direction) else { throw WebAPIError.invalidBody }
            let comparison = try model.webActionTickets.consumeComparison(body.token, moduleID: id)
            let current = try await model.moduleSyncComparison(moduleID: id)
            guard ModuleSyncPlanner.isCurrent(comparison, comparedTo: current) else { throw PreviewContentSaveError.changed }
            let success = await model.resolveModuleSyncConflict(moduleID: id,
                resolution: body.direction == "localToGitHub" ? .localWins : .githubWins, comparison: comparison)
            guard success else { return .error(status: 409, message: model.presentedError ?? "同步未完成，请重新比较。") }
            try await model.flushPersistence()
                return .json(ActionPayload(ok: true, message: model.statusMessage))
        case ("GET", "preview"):
            let content = try await model.previewContent(for: module)
            return .text(content, headers: ["ETag": previewETag(for: content)])
        case ("PUT", "preview"):
            guard let content = String(data: request.body, encoding: .utf8) else {
                throw WebAPIError.invalidBody
            }
            let saved = try await model.savePreviewContent(
                content, for: module,
                expectedContentHash: previewContentHash(fromIfMatch: request.headers["if-match"])
            )
            return .json(ActionPayload(ok: true, message: model.statusMessage, content: saved.content), headers: ["ETag": "\"\(saved.contentHash)\""])
        case ("DELETE", "preview"):
            let restored = try await model.restorePreviewContent(for: module, expectedContentHash: previewContentHash(fromIfMatch: request.headers["if-match"]))
            return .text(restored, headers: ["ETag": previewETag(for: restored)])
        case ("POST", "override-conflict"):
            await model.acceptOverrideConflict(moduleID: id)
            try await model.flushPersistence()
                return .json(ActionPayload(ok: true, message: model.statusMessage))
        case ("GET", "arguments"):
            let info = await model.moduleArgumentInfo(for: module)
            let values = info.definitions.map { definition in
                WebArgumentPayload(
                    key: definition.key,
                    defaultValue: definition.defaultValue,
                    value: module.argumentOverrides[definition.key] ?? definition.defaultValue
                )
            }
            return .json(WebArgumentsPayload(arguments: values, help: info.helpText))
        case ("PUT", "arguments"):
            let payload = try request.decodeBody(WebArgumentMutation.self)
            let info = await model.moduleArgumentInfo(for: module)
            guard let definition = info.definitions.first(where: { $0.key == payload.key }) else {
                throw WebAPIError.invalidArgument
            }
            guard !model.isWorking else { throw PreviewContentSaveError.busy }
            model.setModuleArgument(
                moduleID: id,
                key: payload.key,
                value: payload.value,
                defaultValue: definition.defaultValue
            )
            try await model.flushPersistence()
                return .json(ActionPayload(ok: true, message: model.statusMessage))
        case ("DELETE", "arguments"):
            model.resetModuleArguments(moduleID: id)
            try await model.flushPersistence()
                return .json(ActionPayload(ok: true, message: model.statusMessage))
        case ("GET", "icon"):
            return WebManagementAssets.iconResponse(for: module, cacheDirectory: model.cacheDirectoryURL)
        default:
            throw WebAPIError.methodNotAllowed
        }
    }

}

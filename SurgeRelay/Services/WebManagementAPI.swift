import Foundation

@MainActor
enum WebManagementAPI {
    static func eventPayload(model: AppModel) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(WebManagementStateBuilder.payload(model: model)) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func response(for request: WebHTTPRequest, model: AppModel) async -> WebHTTPResponse {
        if !request.path.hasPrefix("/api/") {
            return WebManagementAssets.assetResponse(for: request.path)
        }

        do {
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
                return .json(WebManagementStateBuilder.payload(model: model))
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
                let mutation = try request.decodeBody(WebModuleMutation.self)
                try model.addModule(from: mutation.draft())
                return .json(ActionPayload(ok: true, message: model.statusMessage), status: 201, reason: "Created")
            case ("POST", "/api/source/name"):
                let payload = try request.decodeBody(WebSourceNameRequest.self)
                return .json(try await sourceNamePayload(for: payload.url))
            case ("GET", "/api/combined/preview"):
                return .text(try await model.combinedPreviewContent())
            default:
                return try await moduleResponse(for: request, model: model)
            }
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
                return .json(ActionPayload(ok: true, message: model.statusMessage))
            case "DELETE":
                await model.deleteModule(id: id)
                return .json(ActionPayload(ok: true, message: model.statusMessage))
            default:
                throw WebAPIError.methodNotAllowed
            }
        }

        switch (request.method, components[3]) {
        case ("POST", "enabled"):
            let payload = try request.decodeBody(WebEnabledRequest.self)
            model.setModuleEnabled(id: id, enabled: payload.enabled)
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
        case ("GET", "preview"):
            return .text(try await model.previewContent(for: module))
        case ("PUT", "preview"):
            guard let content = String(data: request.body, encoding: .utf8) else {
                throw WebAPIError.invalidBody
            }
            try await model.savePreviewContent(content, for: module)
            return .json(ActionPayload(ok: true, message: model.statusMessage))
        case ("DELETE", "preview"):
            let restored = try await model.restorePreviewContent(for: module)
            return .text(restored)
        case ("POST", "override-conflict"):
            await model.acceptOverrideConflict(moduleID: id)
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
            model.setModuleArgument(
                moduleID: id,
                key: payload.key,
                value: payload.value,
                defaultValue: definition.defaultValue
            )
            return .json(ActionPayload(ok: true, message: model.statusMessage))
        case ("DELETE", "arguments"):
            model.resetModuleArguments(moduleID: id)
            return .json(ActionPayload(ok: true, message: model.statusMessage))
        case ("GET", "icon"):
            return WebManagementAssets.iconResponse(for: module)
        default:
            throw WebAPIError.methodNotAllowed
        }
    }

}

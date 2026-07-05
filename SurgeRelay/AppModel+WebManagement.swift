import Foundation

@MainActor
extension AppModel {
    @discardableResult
    private func ensureWebAccessTokenLoaded(showStatusMessage: Bool = false) -> String {
        let current = webAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty || webAccessTokenStorageStatus == .notChecked else { return current }

        let tokenLoad = CredentialTokenCoordinator.loadWebAccessToken()
        webAccessToken = tokenLoad.token
        webAccessTokenStorageStatus = tokenLoad.storageStatus
        if showStatusMessage, let message = tokenLoad.statusMessage {
            statusMessage = message
        }
        return tokenLoad.token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func ensureWebAccessTokenForEditing(showStatusMessage: Bool = false) -> String {
        ensureWebAccessTokenLoaded(showStatusMessage: showStatusMessage)
    }

    func saveWebAccessToken() {
        webAccessToken = webAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !webAccessToken.isEmpty else {
            presentedError = "Web 管理令牌不能为空。可以点击“生成新令牌”后保存。"
            statusMessage = "Web 管理令牌未保存"
            return
        }
        do {
            try KeychainStore.saveWebAccessToken(webAccessToken)
            webAccessTokenStorageStatus = .keychain
            statusMessage = "Web 管理访问令牌已保存到系统钥匙串"
        } catch {
            webAccessTokenStorageStatus = .memoryOnly
            presentedError = "无法保存 Web 管理访问令牌：\(error.localizedDescription)"
            statusMessage = "Web 管理访问令牌仅在本次运行中有效"
        }
        applyWebServerSettings()
    }

    func resetWebAccessToken() {
        let token = CredentialTokenCoordinator.generateWebAccessToken()
        webAccessToken = token
        do {
            try KeychainStore.saveWebAccessToken(token)
            webAccessTokenStorageStatus = .keychain
            statusMessage = "Web 管理访问令牌已重置"
        } catch {
            webAccessTokenStorageStatus = .memoryOnly
            presentedError = "无法保存 Web 管理访问令牌：\(error.localizedDescription)"
            statusMessage = "Web 管理访问令牌仅在本次运行中有效"
        }
        applyWebServerSettings()
    }

    func applyWebServerSettings(persist: Bool = true) {
        guard (1...65_535).contains(settings.webServerPort),
              let port = UInt16(exactly: settings.webServerPort) else {
            webServerState = .failed("端口必须在 1–65535 之间。")
            return
        }
        if persist { saveSettings() }
        webServer.stop()
        guard settings.webServerEnabled else {
            webServerState = .stopped
            return
        }

        let token = ensureWebAccessTokenLoaded(showStatusMessage: true)
        guard !token.isEmpty else {
            webServerState = .failed("无法生成 Web 管理访问令牌。")
            return
        }

        let configuration = WebServerConfiguration(
            port: port,
            allowRemoteAccess: settings.webServerAllowRemoteAccess,
            accessToken: token
        )
        do {
            try webServer.start(
                configuration: configuration,
                stateHandler: { [weak self] state in
                    Task { @MainActor [weak self] in self?.webServerState = state }
                },
                eventHandler: { [weak self] in
                    guard let self else { return "{}" }
                    return await WebManagementAPI.eventPayload(model: self)
                },
                requestHandler: { [weak self] request in
                    if !request.path.hasPrefix("/api/") {
                        return WebManagementAssets.assetResponse(for: request.path)
                    }
                    guard let self else {
                        return .error(status: 500, message: "Surge Relay 已停止。")
                    }
                    return await WebManagementAPI.response(for: request, model: self)
                }
            )
        } catch {
            webServerState = .failed(error.localizedDescription)
        }
    }

    var webManagementURL: URL? {
        WebManagementController.url(settings: settings, accessToken: webAccessToken, includingToken: true)
    }

    var webManagementDisplayURL: URL? {
        WebManagementController.url(settings: settings, accessToken: webAccessToken, includingToken: false)
    }

    var webManagementAccessModeTitle: String {
        WebManagementController.accessModeTitle(settings: settings)
    }
}

import Security
import XCTest
@testable import SurgeRelay

final class SurgeRelayTests: XCTestCase {
    func testFilenameSanitizerCreatesSurgeModuleExtension() {
        XCTAssertEqual(FilenameSanitizer.sgmoduleName(from: "YouTube Ads.sgmodule"), "YouTube-Ads.sgmodule")
        XCTAssertEqual(FilenameSanitizer.existingSgmoduleName(from: "YouTube Ads.sgmodule"), "YouTube Ads.sgmodule")
        XCTAssertEqual(FilenameSanitizer.sgmoduleName(from: "folder/bad:name"), "folder-bad-name.sgmodule")
        XCTAssertEqual(FilenameSanitizer.existingSgmoduleName(from: "folder/bad:name"), "bad-name.sgmodule")
    }

    func testAutomaticSourceFormat() throws {
        XCTAssertEqual(ModuleSourceFormat.automatic.scriptHubType(for: try XCTUnwrap(URL(string: "https://example.com/test.plugin"))), "loon-plugin")
        XCTAssertEqual(ModuleSourceFormat.automatic.scriptHubType(for: try XCTUnwrap(URL(string: "https://hub.kelee.one/Tool/Loon/Demo.lpx"))), "loon-plugin")
        XCTAssertEqual(ModuleSourceFormat.automatic.scriptHubType(for: try XCTUnwrap(URL(string: "https://example.com/test.sgmodule"))), "surge-module")
        XCTAssertEqual(ModuleSourceFormat.automatic.scriptHubType(for: try XCTUnwrap(URL(string: "https://example.com/rewrite.conf"))), "qx-rewrite")
        XCTAssertTrue(ModuleSourceFormat.automatic.isNativeSurgeModule(for: try XCTUnwrap(URL(string: "https://example.com/test.sgmodule?x=1"))))
        XCTAssertTrue(ModuleSourceFormat.surge.isNativeSurgeModule(for: try XCTUnwrap(URL(string: "https://example.com/no-extension"))))

        let detected = RelayModule(
            name: "Detected",
            sourceURL: "https://example.com/demo.lpx",
            outputFileName: "detected",
            detectedSourceFormat: .loon
        )
        XCTAssertEqual(detected.sourceFormatDisplayTitle, "自动识别（Loon）")
    }

    func testModuleSourceIdentityPreventsEquivalentDuplicates() {
        XCTAssertTrue(ModuleSourceIdentity.matches(
            " HTTPS://Example.com:443/path/module.sgmodule#preview ",
            "https://example.com/path/module.sgmodule"
        ))
        XCTAssertTrue(ModuleSourceIdentity.matches("http://example.com", "http://EXAMPLE.com:80/"))
        XCTAssertFalse(ModuleSourceIdentity.matches(
            "https://example.com/path/module.sgmodule?variant=one",
            "https://example.com/path/module.sgmodule?variant=two"
        ))
    }

    func testLocalFileSourceIsAcceptedForSurgeModules() {
        var draft = ModuleDraft()
        draft.name = "Local"
        draft.sourceURL = URL(filePath: "/tmp/Local Demo.sgmodule").absoluteString
        draft.sourceFormat = .automatic

        XCTAssertNil(draft.validationMessage)
        XCTAssertFalse(draft.isEnabled)
        XCTAssertTrue(ModuleSourceIdentity.matches(
            draft.sourceURL,
            URL(filePath: "/tmp/./Local Demo.sgmodule").standardizedFileURL.absoluteString
        ))
    }

    func testModuleDraftValidatesCustomIconURL() {
        var draft = ModuleDraft()
        draft.name = "Icon"
        draft.sourceURL = "https://example.com/icon.sgmodule"
        draft.sourceFormat = .surge
        draft.iconURL = "https://example.com/icon.png"
        XCTAssertNil(draft.validationMessage)
        XCTAssertEqual(draft.normalizedCustomIconURL, "https://example.com/icon.png")

        draft.iconURL = "http://example.com/icon.png"
        XCTAssertNil(draft.validationMessage)
        XCTAssertEqual(draft.normalizedCustomIconURL, "http://example.com/icon.png")

        draft.iconURL = "data:image/png;base64,abc"
        XCTAssertEqual(draft.validationMessage, "图标 URL 仅支持 HTTP 或 HTTPS 地址。")

        draft.iconURL = "https://"
        XCTAssertEqual(draft.validationMessage, "图标 URL 仅支持 HTTP 或 HTTPS 地址。")

        draft.sourceURL = URL(filePath: "/tmp/Icon.sgmodule").absoluteString
        XCTAssertEqual(draft.validationMessage, "图标 URL 仅支持 HTTP 或 HTTPS 地址。")
    }

    func testRelayModuleDefaultsDoNotJoinCombinedModule() throws {
        let module = RelayModule(
            name: "Default",
            sourceURL: "https://example.com/default.sgmodule",
            outputFileName: "Default"
        )
        XCTAssertFalse(module.isEnabled)

        let legacyData = Data("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Legacy",
          "sourceURL": "https://example.com/legacy.sgmodule",
          "sourceFormat": "automatic",
          "outputFileName": "Legacy",
          "publishesStandalone": true
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(RelayModule.self, from: legacyData)
        XCTAssertFalse(decoded.isEnabled)
    }

    func testLocalFileModulePreservesExistingPublishedFileName() {
        let module = RelayModule(
            name: "Local Demo",
            sourceURL: URL(filePath: "/tmp/Local Demo.sgmodule").absoluteString,
            sourceFormat: .surge,
            outputFileName: "Local Demo.sgmodule",
            outputFolder: "Local Modules"
        )

        XCTAssertEqual(module.outputFileName, "Local Demo.sgmodule")
        XCTAssertEqual(module.publishedRelativePath, "Local Modules/Local Demo.sgmodule")
    }

    func testModuleDraftPublishedPathPrefersExplicitOutputFileName() {
        var draft = ModuleDraft()
        draft.name = "Renamed Display"
        draft.sourceURL = "https://example.com/source.sgmodule"
        draft.outputFileName = "Stable Name.sgmodule"
        draft.outputFolder = "Ads"

        XCTAssertEqual(draft.normalizedOutputFileName(), "Stable-Name.sgmodule")
        XCTAssertEqual(draft.publishedRelativePath(), "Ads/Stable-Name.sgmodule")

        draft.outputFileName = ""
        XCTAssertEqual(draft.normalizedOutputFileName(), "Renamed-Display.sgmodule")
        XCTAssertEqual(draft.publishedRelativePath(), "Ads/Renamed-Display.sgmodule")
    }

    func testModuleDraftPublishedPathPreservesLocalFileNameSpacing() {
        var draft = ModuleDraft()
        draft.name = "Renamed Display"
        draft.sourceURL = URL(filePath: "/tmp/Local Source.sgmodule").absoluteString
        draft.outputFileName = "Stable Name.sgmodule"
        draft.outputFolder = "Local Modules"

        XCTAssertEqual(draft.normalizedOutputFileName(), "Stable Name.sgmodule")
        XCTAssertEqual(draft.publishedRelativePath(), "Local Modules/Stable Name.sgmodule")
    }

    func testModuleOutputPathInspectorExplainsNonPublishingAndCollisions() {
        let existingID = UUID()
        let existing = RelayModule(
            id: existingID,
            name: "Existing",
            sourceURL: "https://example.com/existing.sgmodule",
            outputFileName: "Existing",
            outputFolder: "Ads"
        )

        XCTAssertEqual(
            ModuleOutputPathInspector.notice(
                for: "Ads/New.sgmodule",
                publishesStandalone: false,
                modules: [existing],
                editingModuleID: nil,
                combinedFileName: "Surge Relay"
            ),
            ModuleOutputPathNotice(message: "未开启独立发布时，不会写出这个独立模块文件。", isWarning: false)
        )
        XCTAssertEqual(
            ModuleOutputPathInspector.notice(
                for: "Surge-Relay.sgmodule",
                publishesStandalone: true,
                modules: [existing],
                editingModuleID: nil,
                combinedFileName: "Surge Relay"
            ),
            ModuleOutputPathNotice(message: "该路径与总模块文件冲突，保存时会自动加编号避免覆盖。", isWarning: true)
        )
        XCTAssertEqual(
            ModuleOutputPathInspector.notice(
                for: "Ads/Existing.sgmodule",
                publishesStandalone: true,
                modules: [existing],
                editingModuleID: nil,
                combinedFileName: "Surge Relay"
            ),
            ModuleOutputPathNotice(message: "该路径已被“Existing”使用，保存时会自动加编号避免覆盖。", isWarning: true)
        )
        XCTAssertNil(ModuleOutputPathInspector.notice(
            for: "Ads/Existing.sgmodule",
            publishesStandalone: true,
            modules: [existing],
            editingModuleID: existingID,
            combinedFileName: "Surge Relay"
        ))
    }

    func testLocalRootFileSkipsOnlyLocalSelfExport() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let source = root.appending(path: "Ads/YouTube Ads.sgmodule")
        let module = RelayModule(
            name: "YouTube",
            sourceURL: source.absoluteString,
            sourceFormat: .surge,
            outputFileName: "YouTube Ads.sgmodule",
            outputFolder: "Ads",
            publishesStandalone: true
        )

        XCTAssertTrue(module.publishesStandalone)
        XCTAssertTrue(AppModel.shouldSkipStandaloneLocalExport(
            module,
            storageMode: .local,
            localModuleDirectory: root.path
        ))
        XCTAssertFalse(AppModel.shouldSkipStandaloneLocalExport(
            module,
            storageMode: .gitHub,
            localModuleDirectory: root.path
        ))

        let copiedModule = RelayModule(
            name: "YouTube Copy",
            sourceURL: source.absoluteString,
            sourceFormat: .surge,
            outputFileName: "YouTube Copy.sgmodule",
            outputFolder: "Ads",
            publishesStandalone: true
        )
        XCTAssertFalse(AppModel.shouldSkipStandaloneLocalExport(
            copiedModule,
            storageMode: .local,
            localModuleDirectory: root.path
        ))
    }

    func testModuleOutputFolderBuildsRelativePaths() {
        XCTAssertEqual(ModuleOutputFolder.normalized(" /Ads/Video/ "), "Ads/Video")
        XCTAssertEqual(ModuleOutputFolder.normalized("../Ads"), "Ads")
        XCTAssertEqual(ModuleOutputFolder.components(" /Ads/Video/ "), ["Ads", "Video"])
        XCTAssertEqual(ModuleOutputFolder.relativePath(fileName: "YouTube Ads", folder: "Ads"), "Ads/YouTube-Ads.sgmodule")
        XCTAssertEqual(
            ModuleOutputFolder.relativePath(
                fileName: "YouTube Ads.sgmodule",
                folder: "Ads",
                preservesExistingFileName: true
            ),
            "Ads/YouTube Ads.sgmodule"
        )
        XCTAssertEqual(ModuleOutputFolder.displayTitle(for: ""), "根目录")
        XCTAssertEqual(
            ModuleOutputFolder.options(from: ["Video", "Ads/Video"], preserving: "Tools"),
            ["", "Ads/Video", "Tools", "Video"]
        )
    }

    func testModuleSearchIndexIncludesDisplayedMetadata() {
        let module = RelayModule(
            name: "Video Enhancer",
            sourceURL: "https://example.com/video.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Video.sgmodule",
            category: "Streaming",
            outputFolder: "Media",
            publishesStandalone: false,
            iconURL: "https://example.com/source-icon.png",
            customIconURL: "https://example.com/custom-icon.png",
            state: .current
        )

        let text = ModuleSearchIndex.text(for: module, cachedContent: "DOMAIN-SUFFIX,example.com")

        XCTAssertTrue(text.contains("streaming"))
        XCTAssertTrue(text.contains("media"))
        XCTAssertTrue(text.contains("不发布独立模块"))
        XCTAssertTrue(text.contains("source-icon.png"))
        XCTAssertTrue(text.contains("custom-icon.png"))
        XCTAssertTrue(text.contains("domain-suffix"))
        XCTAssertTrue(text.contains("已是最新"))
    }

    func testWebErrorPayloadIncludesUserFacingMessage() throws {
        let response = WebHTTPResponse.error(status: 409, message: "该模块已经添加，不能重复添加。")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: String])

        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(payload["message"], "该模块已经添加，不能重复添加。")
    }

    func testWebIconContentTypeDetectionOnlyAcceptsRecognizedImages() {
        XCTAssertEqual(WebManagementAPI.imageContentType(Data([0x89, 0x50, 0x4E, 0x47, 0x0D])), "image/png")
        XCTAssertEqual(WebManagementAPI.imageContentType(Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(WebManagementAPI.imageContentType(Data("GIF89a".utf8)), "image/gif")
        XCTAssertEqual(
            WebManagementAPI.imageContentType(Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])),
            "image/webp"
        )
        XCTAssertEqual(WebManagementAPI.imageContentType(Data("<?xml version=\"1.0\"?><svg></svg>".utf8)), "image/svg+xml")
        XCTAssertNil(WebManagementAPI.imageContentType(Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45])))
        XCTAssertNil(WebManagementAPI.imageContentType(Data("not an image".utf8)))
    }

    func testWebContentSecurityPolicyMatchesCustomIconValidation() {
        let policy = WebManagementAPI.webContentSecurityPolicy

        XCTAssertTrue(policy.contains("img-src"))
        XCTAssertTrue(policy.contains("http:"))
        XCTAssertTrue(policy.contains("https:"))
        XCTAssertTrue(policy.contains("data:"))
    }

    func testWebServerRuntimeStateHasUserFacingAndDiagnosticValues() {
        XCTAssertEqual(WebServerRuntimeState.running.title, "运行中")
        XCTAssertEqual(WebServerRuntimeState.running.diagnosticValue, "running")
        XCTAssertEqual(WebServerRuntimeState.running.systemImage, "checkmark.circle.fill")

        let failed = WebServerRuntimeState.failed("端口已被占用")
        XCTAssertEqual(failed.title, "启动失败")
        XCTAssertEqual(failed.diagnosticValue, "failed: 端口已被占用")
        XCTAssertEqual(failed.failureMessage, "端口已被占用")
    }

    func testWorkActivityDescribesActiveAndNonBlockingWork() {
        let startedAt = Date(timeIntervalSince1970: 1_800)
        let publishing = WorkActivity(kind: .publishing, startedAt: startedAt)

        XCTAssertTrue(publishing.isActive)
        XCTAssertEqual(publishing.title, "GitHub 发布")
        XCTAssertEqual(publishing.startedAt, startedAt)
        XCTAssertTrue(publishing.blocksUpdates)
        XCTAssertTrue(publishing.canCancel)
        XCTAssertEqual(
            publishing.updateBlockedReason(statusMessage: "正在生成 GitHub 发布预览…"),
            "Surge Relay 正在执行“GitHub 发布”任务：正在生成 GitHub 发布预览…"
        )

        let keychain = WorkActivity(kind: .checkingKeychain)
        XCTAssertTrue(keychain.isActive)
        XCTAssertFalse(keychain.blocksUpdates)
        XCTAssertFalse(keychain.canCancel)
        XCTAssertNil(keychain.updateBlockedReason(statusMessage: "正在写入、读取并清理临时诊断项。"))
        XCTAssertFalse(WorkActivity.idle.isActive)
        XCTAssertFalse(WorkActivity.idle.canCancel)
    }

    func testWorkActivityCanOverrideCancellationAvailability() {
        XCTAssertFalse(WorkActivity(kind: .updatingModules, canCancel: false).canCancel)
        XCTAssertTrue(WorkActivity(kind: .savingPreview, canCancel: true).canCancel)
    }

    func testUpdateAdmissionExplainsBlockedAndAcceptedStates() {
        let busy = UpdateAdmission.allModules(
            isWorking: true,
            updateableModuleCount: 2,
            statusMessage: "正在检查 Demo…"
        )
        XCTAssertFalse(busy.isAccepted)
        XCTAssertEqual(busy.blockedReason, "Surge Relay 正在执行其他任务：正在检查 Demo…")

        let empty = UpdateAdmission.allModules(
            isWorking: false,
            updateableModuleCount: 0,
            statusMessage: "准备就绪"
        )
        XCTAssertFalse(empty.isAccepted)
        XCTAssertEqual(empty.message, "没有可更新的模块。请开启独立发布，或启用总模块并选择包含来源。")

        let disabled = RelayModule(
            name: "Demo",
            sourceURL: "https://example.com/demo.sgmodule",
            outputFileName: "Demo",
            isEnabled: false
        )
        let disabledAdmission = UpdateAdmission.module(
            disabled,
            moduleIsUpdateable: false,
            isWorking: false,
            updateableModuleCount: 0,
            statusMessage: "准备就绪"
        )
        XCTAssertFalse(disabledAdmission.isAccepted)
        XCTAssertEqual(disabledAdmission.message, "“Demo”没有可生成的输出，请开启独立发布，或启用总模块并将其包含后再更新。")

        let enabled = RelayModule(
            name: "Demo",
            sourceURL: "https://example.com/demo.sgmodule",
            outputFileName: "Demo",
            isEnabled: true
        )
        let accepted = UpdateAdmission.module(
            enabled,
            moduleIsUpdateable: true,
            isWorking: false,
            updateableModuleCount: 1,
            statusMessage: "准备就绪"
        )
        XCTAssertTrue(accepted.isAccepted)
        XCTAssertNil(accepted.blockedReason)
    }

    func testUpdateAdmissionUsesStructuredWorkActivity() {
        let busy = UpdateAdmission.allModules(
            activity: WorkActivity(kind: .previewingPublish),
            updateableModuleCount: 2,
            statusMessage: "正在生成 GitHub 发布预览…"
        )
        XCTAssertFalse(busy.isAccepted)
        XCTAssertEqual(
            busy.blockedReason,
            "Surge Relay 正在执行“发布预览”任务：正在生成 GitHub 发布预览…"
        )

        let checkingKeychain = UpdateAdmission.allModules(
            activity: WorkActivity(kind: .checkingKeychain),
            updateableModuleCount: 1,
            statusMessage: "正在写入、读取并清理临时诊断项。"
        )
        XCTAssertTrue(checkingKeychain.isAccepted)
    }

    func testWebManagementDisplayURLOmitsAccessToken() throws {
        let accessURL = try XCTUnwrap(WebManagementURLFactory.url(
            host: "relay.local",
            port: 8787,
            accessToken: "secret-token",
            includingToken: true
        ))
        let displayURL = try XCTUnwrap(WebManagementURLFactory.url(
            host: "relay.local",
            port: 8787,
            accessToken: "secret-token",
            includingToken: false
        ))

        XCTAssertEqual(accessURL.absoluteString, "http://relay.local:8787/?token=secret-token")
        XCTAssertEqual(displayURL.absoluteString, "http://relay.local:8787/")
        XCTAssertFalse(displayURL.absoluteString.contains("secret-token"))
    }

    func testRefreshPolicyDoesNotRefreshAgainBeforeInterval() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(RefreshPolicy.isDue(
            lastUpdatedAt: now.addingTimeInterval(-59 * 60),
            intervalMinutes: 60,
            now: now
        ))
        XCTAssertTrue(RefreshPolicy.isDue(
            lastUpdatedAt: now.addingTimeInterval(-60 * 60),
            intervalMinutes: 60,
            now: now
        ))
        XCTAssertFalse(RefreshPolicy.isDue(lastUpdatedAt: nil, intervalMinutes: 0, now: now))
    }

    func testScriptHubConversionURLPreservesOriginalAddress() async throws {
        let module = RelayModule(
            name: "Test",
            sourceURL: "https://example.com/path/plugin.conf?token=abc",
            sourceFormat: .loon,
            outputFileName: "my module"
        )
        let url = try await ScriptHubClient().conversionURL(module: module, baseURL: "http://script.hub/")
        XCTAssertTrue(url.absoluteString.contains("https://example.com/path/plugin.conf?token=abc/_end_/my-module.sgmodule"))
        XCTAssertTrue(url.absoluteString.contains("type=loon-plugin"))
        XCTAssertTrue(url.absoluteString.contains("target=surge-module"))
    }

    func testScriptHubAdvancedOptionsAreAddedToConversionURL() async throws {
        var options = ScriptHubOptions()
        options.policy = "Proxy Group"
        options.mitmAdd = "one.example.com,two.example.com"
        options.convertAllScripts = true
        options.compatibilityOnly = true
        let module = RelayModule(
            name: "Advanced",
            sourceURL: "https://example.com/plugin.conf",
            sourceFormat: .loon,
            outputFileName: "fallback",
            scriptHubOptions: options
        )

        let url = try await ScriptHubClient().conversionURL(module: module, baseURL: "http://script.hub")
        let value = url.absoluteString
        XCTAssertTrue(value.contains("/_end_/fallback.sgmodule"))
        XCTAssertTrue(value.contains("jsc=."))
        XCTAssertTrue(value.contains("compatibilityOnly=true"))
        XCTAssertTrue(value.contains("policy=Proxy%20Group"))
        XCTAssertTrue(value.contains("hnadd=one.example.com,two.example.com"))
        XCTAssertFalse(value.contains("&n="))
        XCTAssertFalse(value.contains("category="))
        XCTAssertFalse(value.contains("icon="))
    }

    func testScriptHubUpstreamRejectsFloatingRevision() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }

        do {
            _ = try await ScriptHubUpstreamService(session: session).fetchManagedModule(
                from: "https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/main/modules/script-hub.surge.sgmodule",
                previousRevision: nil
            )
            XCTFail("floating Script-Hub revisions must be rejected")
        } catch let error as RelayError {
            XCTAssertTrue(error.localizedDescription.contains("固定 tag 或 commit"))
        }
    }

    func testScriptHubUpstreamPinsReferencedScriptsAndRecordsHashes() async throws {
        let revision = "6b4fb62240629d2fc66b08bc271f8c1f83a5dcd1"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        GitHubMockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/Script-Hub-Org/Script-Hub/\(revision)/modules/script-hub.surge.sgmodule":
                return (200, Data("""
                #!name=Script Hub
                # script.hub
                [Script]
                Script Hub: 重写转换 = type=http-request, pattern=^https?:\\/\\/script\\.hub\\/file\\/_start_\\/, script-path=https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/main/Rewrite-Parser.js, timeout=300
                """.utf8))
            case "/Script-Hub-Org/Script-Hub/\(revision)/Rewrite-Parser.js":
                return (200, Data("function rewriteParser() { return true; }".utf8))
            default:
                return (404, Data())
            }
        }

        let result = try await ScriptHubUpstreamService(session: session).fetchManagedModule(
            from: "https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/\(revision)/modules/script-hub.surge.sgmodule",
            previousRevision: nil
        )

        XCTAssertEqual(result.sourceDescription, "Script-Hub-Org/Script-Hub@\(revision)")
        XCTAssertEqual(result.upstreamRevision, revision)
        XCTAssertEqual(result.scriptHashes.keys.sorted(), ["Rewrite-Parser.js"])
        XCTAssertTrue(GitHubMockURLProtocol.requestedPaths.contains(
            "GET /Script-Hub-Org/Script-Hub/\(revision)/Rewrite-Parser.js"
        ))
    }

    func testScriptHubUpstreamRejectsChangedHashForSamePinnedRevision() async throws {
        let revision = "6b4fb62240629d2fc66b08bc271f8c1f83a5dcd1"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        var scriptBody = "first"
        GitHubMockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/Script-Hub-Org/Script-Hub/\(revision)/modules/script-hub.surge.sgmodule":
                return (200, Data("""
                #!name=Script Hub
                # script.hub
                [Script]
                Script Hub: 重写转换 = type=http-request, pattern=^https?:\\/\\/script\\.hub\\/file\\/_start_\\/, script-path=https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/main/Rewrite-Parser.js, timeout=300
                """.utf8))
            case "/Script-Hub-Org/Script-Hub/\(revision)/Rewrite-Parser.js":
                return (200, Data(scriptBody.utf8))
            default:
                return (404, Data())
            }
        }
        let service = ScriptHubUpstreamService(session: session)
        let first = try await service.fetchManagedModule(
            from: "https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/\(revision)/modules/script-hub.surge.sgmodule",
            previousRevision: nil
        )
        scriptBody = "second"

        do {
            _ = try await service.fetchManagedModule(
                from: "https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/\(revision)/modules/script-hub.surge.sgmodule",
                previousRevision: first.revision,
                previousUpstreamRevision: first.upstreamRevision,
                previousScriptHashes: first.scriptHashes
            )
            XCTFail("changed script hashes for the same pinned revision must be rejected")
        } catch let error as RelayError {
            XCTAssertTrue(error.localizedDescription.contains("脚本 hash 已变化"))
        }
    }

    func testEmbeddedScriptHubEngineBlocksPrivateHTTPBridgeHosts() async throws {
        let script = """
        $httpClient.get("http://127.0.0.1/private", function(error, response, body) {
          $done({body: String(error || "allowed")});
        });
        """

        let output = try await EmbeddedScriptHubEngine().convert(
            script: script,
            requestURL: try XCTUnwrap(URL(string: "https://example.com/demo.conf"))
        )

        XCTAssertTrue(output.contains("127.0.0.1"))
        XCTAssertFalse(output.contains("allowed"))
    }

    func testGitHubRawURL() throws {
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        settings.branch = "main"
        settings.directory = "modules"
        XCTAssertEqual(
            try XCTUnwrap(settings.rawURL(for: "YouTube.sgmodule")).absoluteString,
            "https://raw.githubusercontent.com/someone/relay/main/modules/YouTube.sgmodule"
        )
        XCTAssertEqual(
            try XCTUnwrap(settings.rawURL(for: "Ads/YouTube.sgmodule")).absoluteString,
            "https://raw.githubusercontent.com/someone/relay/main/modules/Ads/YouTube.sgmodule"
        )
    }

    func testGitHubSettingsValidatesOwnerRepositoryAndBranch() {
        var settings = GitHubSettings()
        settings.owner = "-bad"
        XCTAssertFalse(settings.isConfigured)
        XCTAssertNotNil(settings.validationMessage)

        settings.owner = "someone"
        settings.repository = "bad/repo"
        XCTAssertFalse(settings.isConfigured)

        settings.repository = "relay"
        settings.branch = "feature//bad"
        XCTAssertFalse(settings.isConfigured)

        settings.branch = "feature/security-hardening"
        XCTAssertTrue(settings.isConfigured)
        XCTAssertNil(settings.validationMessage)
    }

    func testGitHubClientListsNestedModuleDirectoriesFromTree() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        GitHubMockURLProtocol.handler = { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/repos/someone/relay/git/ref/heads/main"):
                return (200, Data(#"{"object":{"sha":"commit1"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/commits/commit1"):
                return (200, Data(#"{"sha":"commit1","tree":{"sha":"tree1"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/trees/tree1"):
                return (200, Data("""
                {
                  "tree": [
                    {"path": "modules/Ads", "type": "tree", "sha": "tree-ads"},
                    {"path": "modules/Ads/Video", "type": "tree", "sha": "tree-video"},
                    {"path": "modules/Ads/Video/YouTube.sgmodule", "type": "blob", "sha": "blob-video"},
                    {"path": "modules/Root.sgmodule", "type": "blob", "sha": "blob-root"},
                    {"path": "modules/assets/Generated/script.js", "type": "blob", "sha": "blob-asset"},
                    {"path": "other/Ignored", "type": "tree", "sha": "tree-ignored"}
                  ],
                  "truncated": false
                }
                """.utf8))
            default:
                return (404, Data(#"{"message":"not found"}"#.utf8))
            }
        }
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        settings.branch = "main"
        settings.directory = "modules"

        let folders = try await GitHubClient(session: session).listDirectories(settings: settings, token: "token")

        XCTAssertEqual(folders, ["Ads", "Ads/Video"])
        XCTAssertTrue(GitHubMockURLProtocol.requestedPaths.contains("GET /repos/someone/relay/git/trees/tree1?recursive=1"))
    }

    func testPublicRepositoryUsesGitHubRawWithoutCloudflare() throws {
        var settings = GitHubSettings()
        settings.repositoryIsPrivate = false
        settings.publicBaseURL = "https://unused.example.workers.dev"
        XCTAssertEqual(
            try XCTUnwrap(settings.publicURL(for: "Demo.sgmodule")).host,
            "raw.githubusercontent.com"
        )
    }

    func testReleaseUpdateChannelOpensLatestGitHubRelease() throws {
        let url = ReleaseUpdateChannel.latestReleaseURL
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/junchan0412/SurgeRelay-macOS/releases/latest")
    }

    func testReleaseVersionComparisonHandlesMultiDigitComponents() {
        XCTAssertEqual(
            ReleaseUpdateAvailability.compare(current: "1.2.11", latest: "v1.2.12"),
            .newerAvailable
        )
        XCTAssertEqual(
            ReleaseUpdateAvailability.compare(current: "1.2.11", latest: "1.2.11"),
            .upToDate
        )
        XCTAssertEqual(
            ReleaseUpdateAvailability.compare(current: "1.2.11", latest: "1.2.10"),
            .olderThanCurrent
        )
        XCTAssertFalse(ReleaseVersion("1.2.10") < ReleaseVersion("1.2.9"))
    }

    func testGitHubReleaseClientFetchesLatestReleaseAssets() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        GitHubMockURLProtocol.handler = { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/repos/junchan0412/SurgeRelay-macOS/releases/latest"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
                return (200, Data("""
                {
                  "tag_name": "v1.2.12",
                  "name": "Surge Relay 1.2.12",
                  "html_url": "https://github.com/junchan0412/SurgeRelay-macOS/releases/tag/v1.2.12",
                  "published_at": "2026-07-02T10:00:00Z",
                  "body": "Release notes",
                  "assets": [
                    {
                      "name": "Surge-Relay-1.2.12.app.zip",
                      "browser_download_url": "https://example.com/Surge-Relay-1.2.12.app.zip",
                      "size": 7000000,
                      "digest": "sha256:appzipdigest"
                    },
                    {
                      "name": "Surge-Relay-1.2.12.app.zip.sha256",
                      "browser_download_url": "https://example.com/Surge-Relay-1.2.12.app.zip.sha256",
                      "size": 93
                    },
                    {
                      "name": "Surge-Relay-1.2.12.pkg",
                      "browser_download_url": "https://example.com/Surge-Relay-1.2.12.pkg",
                      "size": 7100000,
                      "digest": "sha256:pkgdigest"
                    },
                    {
                      "name": "Surge-Relay-1.2.12.pkg.sha256",
                      "browser_download_url": "https://example.com/Surge-Relay-1.2.12.pkg.sha256",
                      "size": 89
                    }
                  ]
                }
                """.utf8))
            case ("GET", "/Surge-Relay-1.2.12.app.zip.sha256"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/plain")
                return (200, Data("appzipdigest  Surge-Relay-1.2.12.app.zip\n".utf8))
            case ("GET", "/Surge-Relay-1.2.12.pkg.sha256"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/plain")
                return (200, Data("pkgdigest  Surge-Relay-1.2.12.pkg\n".utf8))
            default:
                return (404, Data(#"{"message":"not found"}"#.utf8))
            }
        }

        let release = try await GitHubReleaseClient(session: session).latestRelease()

        XCTAssertEqual(release.version, "1.2.12")
        XCTAssertEqual(release.packageAsset?.name, "Surge-Relay-1.2.12.pkg")
        XCTAssertEqual(release.packageAsset?.digest, "sha256:pkgdigest")
        XCTAssertEqual(
            release.packageAsset.flatMap { release.checksumAsset(for: $0)?.name },
            "Surge-Relay-1.2.12.pkg.sha256"
        )
        XCTAssertEqual(release.packageAsset.map { release.checksumValidation(for: $0).status }, .matched)
        XCTAssertEqual(release.appZipAsset?.name, "Surge-Relay-1.2.12.app.zip")
        XCTAssertEqual(release.appZipAsset?.digestDisplay, "sha256:appzipdigest")
        XCTAssertEqual(
            release.appZipAsset.flatMap { release.checksumAsset(for: $0)?.name },
            "Surge-Relay-1.2.12.app.zip.sha256"
        )
        XCTAssertEqual(release.appZipAsset.map { release.checksumValidation(for: $0).status }, .matched)
        XCTAssertEqual(release.installableAssets.map(\.name), [
            "Surge-Relay-1.2.12.pkg",
            "Surge-Relay-1.2.12.app.zip"
        ])
        XCTAssertEqual(release.notesPreview, "Release notes")
        XCTAssertTrue(GitHubMockURLProtocol.requestedPaths.contains(
            "GET /repos/junchan0412/SurgeRelay-macOS/releases/latest"
        ))
        XCTAssertTrue(GitHubMockURLProtocol.requestedPaths.contains("GET /Surge-Relay-1.2.12.app.zip.sha256"))
        XCTAssertTrue(GitHubMockURLProtocol.requestedPaths.contains("GET /Surge-Relay-1.2.12.pkg.sha256"))
    }

    func testGitHubReleaseClientFlagsChecksumMismatch() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        GitHubMockURLProtocol.handler = { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/repos/junchan0412/SurgeRelay-macOS/releases/latest"):
                return (200, Data("""
                {
                  "tag_name": "v1.2.13",
                  "name": "Surge Relay 1.2.13",
                  "html_url": "https://github.com/junchan0412/SurgeRelay-macOS/releases/tag/v1.2.13",
                  "published_at": "2026-07-02T10:00:00Z",
                  "body": "",
                  "assets": [
                    {
                      "name": "Surge-Relay-1.2.13.app.zip",
                      "browser_download_url": "https://example.com/Surge-Relay-1.2.13.app.zip",
                      "size": 7000000,
                      "digest": "sha256:expectedhash"
                    },
                    {
                      "name": "Surge-Relay-1.2.13.app.zip.sha256",
                      "browser_download_url": "https://example.com/Surge-Relay-1.2.13.app.zip.sha256",
                      "size": 93
                    }
                  ]
                }
                """.utf8))
            case ("GET", "/Surge-Relay-1.2.13.app.zip.sha256"):
                return (200, Data("differenthash  Surge-Relay-1.2.13.app.zip\n".utf8))
            default:
                return (404, Data(#"{"message":"not found"}"#.utf8))
            }
        }

        let release = try await GitHubReleaseClient(session: session).latestRelease()
        let appZip = try XCTUnwrap(release.appZipAsset)
        let validation = release.checksumValidation(for: appZip)

        XCTAssertEqual(validation.status, .mismatched)
        XCTAssertEqual(validation.digestHash, "expectedhash")
        XCTAssertEqual(validation.checksumHash, "differenthash")
    }

    func testGitHubReleaseInstallGuidancePrefersPackageForUpdates() throws {
        let release = GitHubRelease(
            tagName: "v1.2.22",
            name: "Surge Relay 1.2.22",
            htmlURL: try XCTUnwrap(URL(string: "https://github.com/junchan0412/SurgeRelay-macOS/releases/tag/v1.2.22")),
            publishedAt: Date(timeIntervalSince1970: 1_800),
            body: "",
            assets: [
                GitHubReleaseAsset(
                    name: "Surge-Relay-1.2.22.pkg",
                    downloadURL: try XCTUnwrap(URL(string: "https://example.com/Surge-Relay-1.2.22.pkg")),
                    size: 7_100_000,
                    digest: "sha256:pkgdigest"
                ),
                GitHubReleaseAsset(
                    name: "Surge-Relay-1.2.22.app.zip",
                    downloadURL: try XCTUnwrap(URL(string: "https://example.com/Surge-Relay-1.2.22.app.zip")),
                    size: 7_000_000,
                    digest: "sha256:appzipdigest"
                )
            ]
        )

        let guidance = release.installGuidance

        XCTAssertFalse(guidance.updateNeedsAttention)
        XCTAssertEqual(guidance.updateSystemImage, "shippingbox")
        XCTAssertTrue(guidance.updateRecommendation.contains("Sparkle"))
        XCTAssertTrue(guidance.updateRecommendation.contains("pkg"))
        XCTAssertTrue(guidance.firstInstallRecommendation.contains("app.zip"))
        XCTAssertTrue(guidance.trustNotice.contains("固定自签名证书"))
        XCTAssertTrue(guidance.trustNotice.contains("EdDSA"))
    }

    func testGitHubReleaseInstallGuidanceWarnsWhenPackageIsMissing() throws {
        let release = GitHubRelease(
            tagName: "v1.2.22",
            name: "Surge Relay 1.2.22",
            htmlURL: try XCTUnwrap(URL(string: "https://github.com/junchan0412/SurgeRelay-macOS/releases/tag/v1.2.22")),
            publishedAt: Date(timeIntervalSince1970: 1_800),
            body: "",
            assets: [
                GitHubReleaseAsset(
                    name: "Surge-Relay-1.2.22.app.zip",
                    downloadURL: try XCTUnwrap(URL(string: "https://example.com/Surge-Relay-1.2.22.app.zip")),
                    size: 7_000_000,
                    digest: "sha256:appzipdigest"
                )
            ]
        )

        let guidance = release.installGuidance

        XCTAssertTrue(guidance.updateNeedsAttention)
        XCTAssertEqual(guidance.updateSystemImage, "exclamationmark.triangle.fill")
        XCTAssertTrue(guidance.updateRecommendation.contains("缺少 pkg"))
        XCTAssertTrue(guidance.updateRecommendation.contains("Sparkle"))
    }

    func testPrivateRepositoryRequiresCloudflareAndUsesItWhenConfigured() throws {
        var settings = GitHubSettings()
        settings.repositoryIsPrivate = true
        XCTAssertNil(settings.publicURL(for: "Demo.sgmodule"))
        settings.publicBaseURL = "https://surge-relay.example.workers.dev/"
        XCTAssertEqual(
            try XCTUnwrap(settings.publicURL(for: "assets/demo/script.js")).absoluteString,
            "https://surge-relay.example.workers.dev/assets/demo/script.js"
        )
    }

    func testSettingsDecodeWithoutSyncedTokenOrRepositoryVisibility() throws {
        let data = Data(#"{"github":{"owner":"someone","repository":"relay","branch":"main","directory":"modules"}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.githubToken, "")
        XCTAssertNil(settings.github.repositoryIsPrivate)
        XCTAssertNil(settings.localPublishedRootDirectory)
        XCTAssertTrue(settings.localPublishedFilePaths.isEmpty)
        XCTAssertNil(settings.githubPublishedRepositoryKey)
        XCTAssertTrue(settings.githubPublishedFilePaths.isEmpty)
        XCTAssertTrue(settings.customModuleOutputFolders.isEmpty)
    }

    func testSettingsMigratesFloatingScriptHubUpstreamURL() throws {
        for revision in ["main", "master", "HEAD"] {
            let data = Data("""
            {
              "scriptHubModuleURL": "https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/\(revision)/modules/script-hub.surge.sgmodule"
            }
            """.utf8)
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)

            XCTAssertEqual(settings.scriptHubModuleURL, AppSettings.defaultScriptHubModuleURL)
        }
    }

    func testSettingsKeepsPinnedOrCustomScriptHubUpstreamURL() throws {
        let tagURL = "https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/v1.0.0/modules/script-hub.surge.sgmodule"
        let customURL = "https://example.com/script-hub.surge.sgmodule"

        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: Data(#"{"scriptHubModuleURL":"\#(tagURL)"}"#.utf8)).scriptHubModuleURL,
            tagURL
        )
        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: Data(#"{"scriptHubModuleURL":"\#(customURL)"}"#.utf8)).scriptHubModuleURL,
            customURL
        )
    }

    func testSettingsDecodesCustomModuleOutputFolders() throws {
        let data = Data(#"{"customModuleOutputFolders":["Ads","Tools/Nested"]}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.customModuleOutputFolders, ["Ads", "Tools/Nested"])
    }

    func testSettingsStillDecodesLegacyGitHubTokenForMigration() throws {
        let data = Data(#"{"githubToken":"ghp_legacy","github":{"owner":"someone","repository":"relay","branch":"main","directory":"modules"}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.githubToken, "ghp_legacy")
    }

    func testKeychainStoreRoundTripsPasswordWithCustomService() throws {
        let service = "com.allenmiao.SurgeRelayTests.\(UUID().uuidString)"
        let account = "github-token"
        defer { try? KeychainStore.deletePassword(account: account, service: service) }

        do {
            XCTAssertNil(try KeychainStore.readPassword(account: account, service: service))
            try KeychainStore.savePassword("ghp_first", account: account, service: service)
            XCTAssertEqual(try KeychainStore.readPassword(account: account, service: service), "ghp_first")
            try KeychainStore.savePassword("ghp_second", account: account, service: service)
            XCTAssertEqual(try KeychainStore.readPassword(account: account, service: service), "ghp_second")
            try KeychainStore.deletePassword(account: account, service: service)
            XCTAssertNil(try KeychainStore.readPassword(account: account, service: service))
        } catch let error as KeychainStoreError
            where [errSecNotAvailable, errSecInteractionNotAllowed, errSecAuthFailed].contains(error.status) {
            throw XCTSkip("Keychain is unavailable in this test environment: \(error.localizedDescription)")
        }
    }

    func testInstallationDiagnosticsClassifiesAdHocGatekeeperAndQuarantine() {
        let signature = InstallationDiagnosticSnapshot.signatureSummary(from: .init(
            status: 0,
            output: "Signature=adhoc\nTeamIdentifier=not set\n"
        ))
        XCTAssertEqual(signature, "ad-hoc 签名，未使用 Developer ID")

        let selfSigned = InstallationDiagnosticSnapshot.signatureSummary(from: .init(
            status: 0,
            output: "Authority=Surge Relay Self-Signed Code Signing\nTeamIdentifier=not set\n"
        ))
        XCTAssertEqual(selfSigned, "固定证书签名（Surge Relay Self-Signed Code Signing）")

        let gatekeeper = InstallationDiagnosticSnapshot.gatekeeperSummary(from: .init(
            status: 1,
            output: "Surge Relay.app: rejected\n"
        ))
        XCTAssertEqual(gatekeeper, "会被 Gatekeeper 拦截，首次安装可能需要手动信任")

        let quarantine = InstallationDiagnosticSnapshot.quarantineSummary(from: .init(
            status: 0,
            output: "0081;687...;Safari;\n"
        ))
        XCTAssertEqual(quarantine, "存在隔离属性，首次打开可能被拦截")
    }

    func testInstallationDiagnosticsListsRecentCrashReports() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SurgeRelayCrashReports-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recent = root.appending(path: "Surge Relay-2026-07-02-120000.ips")
        let old = root.appending(path: "Surge Relay-2026-06-30-120000.crash")
        let otherApp = root.appending(path: "Other App-2026-07-02-120000.ips")
        try Data("recent".utf8).write(to: recent)
        try Data("old".utf8).write(to: old)
        try Data("other".utf8).write(to: otherApp)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: recent.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 500)],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_100)],
            ofItemAtPath: otherApp.path
        )

        let reports = InstallationDiagnosticSnapshot.recentCrashReports(
            appName: "Surge Relay",
            diagnosticDirectory: root,
            since: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(reports.map(\.fileName), [recent.lastPathComponent])
        XCTAssertEqual(
            InstallationDiagnosticSnapshot.crashReportStatus(from: reports),
            "最近 24 小时发现 1 个崩溃报告"
        )
    }

    func testCredentialDiagnosticsDescribeKeychainAccountsWithoutSecrets() {
        let checkedAt = Date(timeIntervalSince1970: 1_800)
        let diagnostics = CredentialDiagnosticSnapshot.current(
            githubTokenStatus: .keychain,
            webAccessTokenStatus: .memoryOnly,
            keychainAccessProbe: .from(
                result: KeychainAccessProbeResult(isAvailable: true, message: "钥匙串读写正常。"),
                checkedAt: checkedAt
            )
        )
        XCTAssertEqual(diagnostics.keychainService, KeychainStore.defaultService)
        XCTAssertEqual(diagnostics.keychainAccessState, .available)
        XCTAssertEqual(diagnostics.keychainAccessStatus, "可用")
        XCTAssertEqual(diagnostics.keychainAccessMessage, "钥匙串读写正常。")
        XCTAssertNil(diagnostics.keychainAccessStatusCode)
        XCTAssertEqual(diagnostics.keychainAccessRecoverySuggestion, "")
        XCTAssertEqual(diagnostics.keychainAccessCheckedAt, checkedAt)
        XCTAssertEqual(diagnostics.githubTokenAccount, KeychainStore.githubTokenAccount)
        XCTAssertEqual(diagnostics.webAccessTokenAccount, KeychainStore.webAccessTokenAccount)
        XCTAssertFalse(diagnostics.note.contains("ghp_"))
        XCTAssertFalse(diagnostics.note.contains("Bearer"))
    }

    func testCredentialDiagnosticsCanRepresentUncheckedStorage() {
        let diagnostics = CredentialDiagnosticSnapshot.current(
            githubTokenStatus: .notChecked,
            webAccessTokenStatus: .notChecked,
            keychainAccessProbe: .notChecked
        )

        XCTAssertEqual(diagnostics.githubTokenStatus, "尚未检查")
        XCTAssertEqual(diagnostics.webAccessTokenStatus, "尚未检查")
        XCTAssertEqual(diagnostics.keychainAccessStatus, "尚未检查")
    }

    func testKeychainProbeSnapshotDescribesUnavailableAccess() {
        let checkedAt = Date(timeIntervalSince1970: 2_400)
        let snapshot = KeychainAccessProbeSnapshot.from(
            result: KeychainAccessProbeResult(
                isAvailable: false,
                message: "钥匙串保存失败：User interaction is not allowed.",
                statusCode: errSecInteractionNotAllowed,
                recoverySuggestion: "请解锁登录钥匙串。"
            ),
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.state, .unavailable)
        XCTAssertEqual(snapshot.state.title, "不可用")
        XCTAssertEqual(snapshot.message, "钥匙串保存失败：User interaction is not allowed.")
        XCTAssertEqual(snapshot.statusCode, errSecInteractionNotAllowed)
        XCTAssertEqual(snapshot.recoverySuggestion, "请解锁登录钥匙串。")
        XCTAssertEqual(snapshot.checkedAt, checkedAt)
    }

    func testKeychainStoreErrorProvidesActionableRecoverySuggestion() {
        let interactionError = KeychainStoreError(operation: "保存", status: errSecInteractionNotAllowed)
        XCTAssertEqual(Int32(interactionError.status), errSecInteractionNotAllowed)
        XCTAssertTrue(interactionError.localizedDescription.contains("钥匙串保存失败"))
        XCTAssertTrue(interactionError.recoverySuggestion?.contains("登录") == true)
        XCTAssertTrue(interactionError.recoverySuggestion?.contains("允许") == true)

        let entitlementError = KeychainStoreError(operation: "读取", status: errSecMissingEntitlement)
        XCTAssertTrue(entitlementError.recoverySuggestion?.contains("pkg") == true)
        XCTAssertTrue(entitlementError.recoverySuggestion?.contains("重新保存 Token") == true)
    }

    func testStorageModeSelectsOnlyItsOwnCombinedOutput() throws {
        var settings = AppSettings()
        settings.combinedModuleEnabled = true
        settings.combinedModuleFileName = "My Relay"
        settings.localModuleDirectory = "/tmp/Surge Relay"
        settings.github.repositoryIsPrivate = false

        settings.storageMode = .local
        XCTAssertNil(settings.publishedURL(for: "My-Relay.sgmodule"))
        XCTAssertEqual(
            try XCTUnwrap(settings.localCombinedModuleURL).path,
            "/tmp/Surge Relay/My-Relay.sgmodule"
        )

        settings.storageMode = .gitHub
        XCTAssertNil(settings.localCombinedModuleURL)
        XCTAssertEqual(
            try XCTUnwrap(settings.publishedURL(for: "My-Relay.sgmodule")).host,
            "raw.githubusercontent.com"
        )
    }

    func testAppSettingsDefaultDisablesCombinedModule() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.combinedModuleEnabled)
        XCTAssertNil(settings.localCombinedModuleURL)
    }

    func testConfigurationMigrationCopiesOverridesWithoutRemovingDestinationFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Source", directoryHint: .isDirectory)
        let destination = root.appending(path: "Destination", directoryHint: .isDirectory)
        let sourceOverride = source.appending(path: "Overrides/nested/module.cache")
        let existingOverride = destination.appending(path: "Overrides/keep.cache")
        try FileManager.default.createDirectory(
            at: sourceOverride.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: existingOverride.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("edited module".utf8).write(to: sourceOverride)
        try Data("keep me".utf8).write(to: existingOverride)

        try PersistenceStore.migrateOverrides(from: source, to: destination)

        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Overrides/nested/module.cache"), encoding: .utf8),
            "edited module"
        )
        XCTAssertEqual(try String(contentsOf: existingOverride, encoding: .utf8), "keep me")
    }

    func testConfigurationMigrationCopiesRegistryHistoryBackupsAndOverrides() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Source", directoryHint: .isDirectory)
        let destination = root.appending(path: "Destination", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(
            at: source.appending(path: "Backups/modules.json", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: source.appending(path: "Overrides/nested", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination.appending(path: "Backups/settings.json", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination.appending(path: "Overrides", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        try Data("[{\"name\":\"source\"}]".utf8).write(to: source.appending(path: "modules.json"))
        try Data("{\"storageMode\":\"local\"}".utf8).write(to: source.appending(path: "settings.json"))
        try Data("{\"revision\":\"abc\"}".utf8).write(to: source.appending(path: "script-hub-state.json"))
        try Data("[{\"message\":\"history\"}]".utf8).write(to: source.appending(path: "update-history.json"))
        try Data("root backup".utf8).write(to: source.appending(path: "Backups/modules.json/root.backup"))
        try Data("override".utf8).write(to: source.appending(path: "Overrides/nested/module.cache"))
        try Data("old modules".utf8).write(to: destination.appending(path: "modules.json"))
        try Data("keep backup".utf8).write(to: destination.appending(path: "Backups/settings.json/keep.backup"))
        try Data("keep override".utf8).write(to: destination.appending(path: "Overrides/keep.cache"))

        try PersistenceStore.migrateConfigurationFiles(from: source, to: destination)

        XCTAssertEqual(try String(contentsOf: destination.appending(path: "modules.json"), encoding: .utf8), "[{\"name\":\"source\"}]")
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "settings.json"), encoding: .utf8), "{\"storageMode\":\"local\"}")
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "script-hub-state.json"), encoding: .utf8), "{\"revision\":\"abc\"}")
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "update-history.json"), encoding: .utf8), "[{\"message\":\"history\"}]")
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Backups/modules.json/root.backup"), encoding: .utf8),
            "root backup"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Backups/settings.json/keep.backup"), encoding: .utf8),
            "keep backup"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Overrides/nested/module.cache"), encoding: .utf8),
            "override"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Overrides/keep.cache"), encoding: .utf8),
            "keep override"
        )
        let overwrittenBackups = try FileManager.default.subpathsOfDirectory(
            atPath: destination.appending(path: "Backups/configuration-migration/modules.json").path
        )
        XCTAssertEqual(overwrittenBackups.count, 1)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appending(path: "Backups/configuration-migration/modules.json/\(overwrittenBackups[0])"),
                encoding: .utf8
            ),
            "old modules"
        )
    }

    func testConfigurationMigrationCleanupRemovesOnlySurgeRelayConfigurationFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Source", directoryHint: .isDirectory)
        let destination = source.appending(path: "Surge Relay", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: source.appending(path: "Backups/modules.json", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: source.appending(path: "Sgmodule", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("modules".utf8).write(to: source.appending(path: "modules.json"))
        try Data("settings".utf8).write(to: source.appending(path: "settings.json"))
        try Data("history".utf8).write(to: source.appending(path: "update-history.json"))
        try Data("state".utf8).write(to: source.appending(path: "script-hub-state.json"))
        try Data("backup".utf8).write(to: source.appending(path: "Backups/modules.json/root.backup"))
        try Data("module".utf8).write(to: source.appending(path: "Sgmodule/Original.sgmodule"))
        try Data("surge".utf8).write(to: source.appending(path: "Surge.conf"))

        try PersistenceStore.migrateConfigurationFiles(from: source, to: destination)
        try PersistenceStore.removeMigratedConfigurationFiles(from: source, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "modules.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "settings.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "script-hub-state.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "update-history.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "Backups").path))
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "modules.json"), encoding: .utf8), "modules")
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Backups/modules.json/root.backup"), encoding: .utf8),
            "backup"
        )
        XCTAssertEqual(try String(contentsOf: source.appending(path: "Sgmodule/Original.sgmodule"), encoding: .utf8), "module")
        XCTAssertEqual(try String(contentsOf: source.appending(path: "Surge.conf"), encoding: .utf8), "surge")
    }

    func testLocalPublishedExportRemovesManifestStaleFilesOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore()
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

        let store = ModuleFileStore()
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

    func testLocalPublishedExportMigratesKnownLegacyManagedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appending(path: "Legacy.sgmodule")
        try Data("#!name=Legacy\n[Rule]\nFINAL,DIRECT\n".utf8).write(to: destination)

        let store = ModuleFileStore()
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

        let store = ModuleFileStore()
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

        let store = ModuleFileStore()
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
        let store = ModuleFileStore()
        try FileManager.default.createDirectory(
            at: root.appending(path: "assets/custom", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("combined".utf8).write(to: root.appending(path: "Surge-Relay.sgmodule"))
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

    func testLegacyOutputCleanupDirectoriesSkipActiveLocalModuleRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let localRoot = root.appending(path: "SurgeRoot", directoryHint: .isDirectory)
        let configuration = localRoot.appending(path: "Surge Relay", directoryHint: .isDirectory)

        let directories = AppModel.legacyOutputCleanupDirectories(
            outputDirectory: localRoot.path,
            configurationDirectory: configuration.path,
            localModuleDirectory: localRoot.path
        )

        XCTAssertEqual(directories, [configuration.standardizedFileURL.path])
    }

    func testGeneratedAssetFilesCanBeFilteredByModuleID() async throws {
        let includedID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let excludedID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let store = ModuleFileStore()
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

    func testRelayModuleDecodesRegistryWithoutAdvancedOptions() throws {
        let original = RelayModule(
            name: "Legacy",
            sourceURL: "https://example.com/legacy.sgmodule",
            sourceFormat: .surge,
            outputFileName: "legacy"
        )
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "scriptHubOptions")
        object.removeValue(forKey: "argumentOverrides")
        object.removeValue(forKey: "iconURL")
        object.removeValue(forKey: "customIconURL")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RelayModule.self, from: legacyData)

        XCTAssertEqual(decoded.name, "Legacy")
        XCTAssertFalse(decoded.isEnabled)
        XCTAssertEqual(decoded.scriptHubOptions, ScriptHubOptions())
        XCTAssertTrue(decoded.argumentOverrides.isEmpty)
        XCTAssertNil(decoded.iconURL)
        XCTAssertNil(decoded.customIconURL)
        XCTAssertEqual(decoded.category, "")
        XCTAssertEqual(decoded.outputFolder, "")
        XCTAssertTrue(decoded.publishesStandalone)
        XCTAssertNil(decoded.sourceETag)
        XCTAssertNil(decoded.sourceContentHash)
        XCTAssertFalse(decoded.hasOverrideConflict)
    }

    func testUpdateHistoryRoundTrip() throws {
        let entry = UpdateHistoryEntry(
            moduleName: "Demo",
            outcome: .cachedAfterFailure,
            duration: 1.25,
            message: "Timeout",
            usedCache: true
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(UpdateHistoryEntry.self, from: data)
        XCTAssertEqual(decoded.moduleName, "Demo")
        XCTAssertEqual(decoded.outcome, .cachedAfterFailure)
        XCTAssertTrue(decoded.usedCache)
    }

    func testUpdateHistoryDecodesLegacyEntryWithoutPublishDetails() throws {
        let data = Data(#"{"moduleName":"GitHub","outcome":"published","duration":0,"message":"legacy publish"}"#.utf8)

        let entry = try JSONDecoder().decode(UpdateHistoryEntry.self, from: data)

        XCTAssertEqual(entry.moduleName, "GitHub")
        XCTAssertEqual(entry.outcome, .published)
        XCTAssertEqual(entry.message, "legacy publish")
        XCTAssertTrue(entry.publishedFiles.isEmpty)
        XCTAssertTrue(entry.deletedFiles.isEmpty)
        XCTAssertNil(entry.commitSHA)
    }

    func testGitHubPublishSnapshotBuildsCommitURLAndFileSummary() throws {
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        let commit = "abcdef1234567890"
        let entry = UpdateHistoryEntry(
            date: Date(timeIntervalSince1970: 3_600),
            moduleName: "GitHub",
            outcome: .published,
            duration: 0,
            message: "原子提交 abcdef12：上传/更新 2 个，删除 1 个",
            publishedFiles: ["Demo.sgmodule", "Folder/Tool.sgmodule"],
            deletedFiles: ["Old.sgmodule"],
            commitSHA: commit
        )

        let snapshot = try XCTUnwrap(GitHubPublishSnapshot.latest(in: [entry], settings: settings))

        XCTAssertEqual(snapshot.commitSHA, commit)
        XCTAssertEqual(snapshot.commitDisplay, "abcdef12")
        XCTAssertEqual(snapshot.commitURL, "https://github.com/someone/relay/commit/\(commit)")
        XCTAssertEqual(snapshot.changedFileCount, 3)
        XCTAssertEqual(snapshot.fileSummary, "2 个上传/更新 · 1 个删除")
        XCTAssertEqual(snapshot.publishedFiles, ["Demo.sgmodule", "Folder/Tool.sgmodule"])
        XCTAssertEqual(snapshot.deletedFiles, ["Old.sgmodule"])
    }

    func testSourceRevisionServiceRecognizesUnchangedContent() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SourceRevisionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        SourceRevisionURLProtocol.response = (200, ["ETag": "demo-v1"], Data("same".utf8))
        let module = RelayModule(
            name: "Demo",
            sourceURL: "https://example.com/demo.sgmodule",
            outputFileName: "Demo",
            sourceContentHash: Data("same".utf8).sha256String
        )
        let result = try await SourceRevisionService(session: session).check(module)
        guard case let .unchanged(snapshot) = result else {
            return XCTFail("Expected unchanged source")
        }
        XCTAssertEqual(snapshot.etag, "demo-v1")
    }

    func testModuleMetadataParserFindsIconWithoutScrapingCatalog() throws {
        let content = """
        #!name=Demo
        #!icon = 'https://raw.githubusercontent.com/example/icons/main/demo.png'
        [General]
        """

        XCTAssertEqual(
            try XCTUnwrap(ModuleMetadataParser.iconURL(in: content)).absoluteString,
            "https://raw.githubusercontent.com/example/icons/main/demo.png"
        )
        XCTAssertNil(ModuleMetadataParser.iconURL(in: "#!name=No Icon\n[General]"))
        XCTAssertTrue(ModuleMetadataParser.applyingDisplayName("GUI Name", to: content).hasPrefix("#!name=GUI Name\n"))
    }

    func testModuleMetadataParserAppliesCategory() {
        let content = """
        #!name=Demo
        #!category=Old
        [General]
        """
        let result = ModuleMetadataParser.applyingCategory("Ads", to: content)
        XCTAssertTrue(result.contains("#!category=Ads"))
        XCTAssertFalse(result.contains("#!category=Old"))
        XCTAssertEqual(ModuleMetadataParser.applyingCategory("", to: content), content)
    }

    func testModuleMetadataParserReadsCategory() {
        XCTAssertEqual(ModuleMetadataParser.category(in: "#!category = 'Ads'\n[General]"), "Ads")
        XCTAssertNil(ModuleMetadataParser.category(in: "#!name=Demo\n[General]"))
    }

    func testModuleMetadataParserRemovesIconWhenApplyingSurgeMetadata() {
        let content = """
        #!name=Demo
        #!icon=https://example.com/source.png
        [General]
        loglevel = notify
        """
        let result = ModuleMetadataParser.applyingModuleMetadata(name: "Managed", category: "Ads", to: content)

        XCTAssertTrue(result.contains("#!name=Managed"))
        XCTAssertTrue(result.contains("#!category=Ads"))
        XCTAssertFalse(result.localizedCaseInsensitiveContains("#!icon"))
        XCTAssertFalse(result.contains("https://example.com/source.png"))
    }

    func testLocalModuleScannerDiscoversExistingModules() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Ads", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("""
        #!name=YouTube
        #!category=Video
        [General]
        """.utf8).write(to: root.appending(path: "Ads/YouTube Ads.sgmodule"))
        try Data("#!name=Combined\n[General]\n".utf8).write(to: root.appending(path: "Surge-Relay.sgmodule"))

        let candidates = try LocalModuleScanner.candidates(
            in: root.path,
            combinedFileName: "Surge Relay",
            existingModules: [],
            publishedFilePaths: []
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].relativePath, "Ads/YouTube Ads.sgmodule")
        XCTAssertEqual(candidates[0].id, "Ads/YouTube Ads.sgmodule")
        XCTAssertEqual(candidates[0].name, "YouTube")
        XCTAssertEqual(candidates[0].category, "Video")
        XCTAssertEqual(candidates[0].outputFolder, "Ads")
        XCTAssertEqual(candidates[0].outputFileName, "YouTube Ads.sgmodule")
    }

    func testLocalModuleScannerReportsSkippedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!name=Combined\n[General]\n".utf8).write(to: root.appending(path: "Surge-Relay.sgmodule"))
        try Data().write(to: root.appending(path: "Empty.sgmodule"))
        try Data("#!name=Managed\n[General]\n".utf8).write(to: root.appending(path: "Managed.sgmodule"))

        let report = try LocalModuleScanner.report(
            in: root.path,
            combinedFileName: "Surge Relay",
            existingModules: [],
            publishedFilePaths: ["Managed.sgmodule"]
        )

        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: report.skippedFiles.map { ($0.relativePath, $0.reason) }),
            [
                "Empty.sgmodule": "文件为空",
                "Managed.sgmodule": "发布路径已纳入管理",
                "Surge-Relay.sgmodule": "这是当前总模块文件"
            ]
        )
    }

    func testLocalModuleFolderScannerFindsNestedFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Ads/Video", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appending(path: "Tools", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(
            try LocalModuleFolderScanner.folders(in: root.path),
            ["Ads", "Ads/Video", "Tools"]
        )
    }

    func testLocalModuleRootDiagnosticsReportsWritableDirectoryContents() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Ads/Video", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("#!name=Demo\n[General]\n".utf8).write(to: root.appending(path: "Ads/Video/Demo.sgmodule"))
        try Data("ignore".utf8).write(to: root.appending(path: "notes.txt"))

        let diagnostics = LocalModuleRootDiagnosticSnapshot.current(path: root.path)

        XCTAssertTrue(diagnostics.exists)
        XCTAssertTrue(diagnostics.isDirectory)
        XCTAssertTrue(diagnostics.isWritable)
        XCTAssertEqual(diagnostics.folderCount, 2)
        XCTAssertEqual(diagnostics.moduleFileCount, 1)
        XCTAssertEqual(diagnostics.status, "目录可用")
        XCTAssertNil(diagnostics.error)
    }

    func testScriptHubClientConvertsLocalSurgeModule() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "Local.sgmodule")
        try Data("""
        #!name=Original
        [General]
        loglevel = notify
        """.utf8).write(to: file)
        let module = RelayModule(
            name: "Managed",
            sourceURL: file.absoluteString,
            sourceFormat: .surge,
            outputFileName: "Local",
            category: "Imported"
        )

        let result = try await ScriptHubClient().convert(module: module)

        XCTAssertEqual(result.requestURL, file)
        XCTAssertTrue(result.content.contains("#!name=Managed"))
        XCTAssertTrue(result.content.contains("#!category=Imported"))
        XCTAssertTrue(result.content.contains("loglevel = notify"))
    }

    func testScriptHubClientDoesNotWriteIconMetadataToNativeSurgeOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "Icon.sgmodule")
        try Data("""
        #!name=Original
        #!icon=https://example.com/source-icon.png
        [General]
        loglevel = notify
        """.utf8).write(to: file)
        let module = RelayModule(
            name: "Managed",
            sourceURL: file.absoluteString,
            sourceFormat: .surge,
            outputFileName: "Icon",
            category: "Imported",
            customIconURL: "https://example.com/custom-icon.png"
        )

        let result = try await ScriptHubClient().convert(module: module)

        XCTAssertTrue(result.content.contains("#!name=Managed"))
        XCTAssertTrue(result.content.contains("#!category=Imported"))
        XCTAssertFalse(result.content.localizedCaseInsensitiveContains("#!icon"))
        XCTAssertFalse(result.content.contains("https://example.com/source-icon.png"))
        XCTAssertFalse(result.content.contains("https://example.com/custom-icon.png"))
    }

    func testGitBlobHashMatchesGitHubContentSHA() {
        XCTAssertEqual(Data("hello\n".utf8).gitBlobSHA1, "ce013625030ba8dba906f756967f9e9ca394464a")
    }

    func testGitHubPublishDiffsAgainstRecursiveTree() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        let sameSHA = Data("same".utf8).gitBlobSHA1
        let oldSHA = Data("old".utf8).gitBlobSHA1
        GitHubMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/repos/someone/relay/git/ref/heads/main"):
                return (200, Data(#"{"object":{"sha":"commit1"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/commits/commit1"):
                return (200, Data(#"{"sha":"commit1","tree":{"sha":"tree1"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/trees/tree1"):
                return (200, Data("""
                {
                  "tree": [
                    {"path": "modules/Same.sgmodule", "type": "blob", "sha": "\(sameSHA)"},
                    {"path": "modules/Changed.sgmodule", "type": "blob", "sha": "\(oldSHA)"},
                    {"path": "modules/Stale.sgmodule", "type": "blob", "sha": "\(oldSHA)"}
                  ],
                  "truncated": false
                }
                """.utf8))
            case ("POST", "/repos/someone/relay/git/blobs"):
                return (200, Data(#"{"sha":"new-blob"}"#.utf8))
            case ("POST", "/repos/someone/relay/git/trees"):
                return (200, Data(#"{"sha":"tree2"}"#.utf8))
            case ("POST", "/repos/someone/relay/git/commits"):
                return (200, Data(#"{"sha":"commit2","tree":{"sha":"tree2"}}"#.utf8))
            case ("PATCH", "/repos/someone/relay/git/refs/heads/main"):
                return (200, Data(#"{"object":{"sha":"commit2"}}"#.utf8))
            default:
                return (404, Data(#"{"message":"not found"}"#.utf8))
            }
        }
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        settings.branch = "main"
        settings.directory = "modules"

        let report = try await GitHubClient(session: session).publish(
            files: [
                PublishFile(name: "Same.sgmodule", data: Data("same".utf8)),
                PublishFile(name: "Changed.sgmodule", data: Data("new".utf8))
            ],
            deleting: ["Stale.sgmodule"],
            settings: settings,
            token: "token"
        )

        XCTAssertEqual(report.publishedFiles, ["Changed.sgmodule"])
        XCTAssertEqual(report.deletedFiles, ["Stale.sgmodule"])
        XCTAssertEqual(report.commitSHA, "commit2")
        XCTAssertFalse(GitHubMockURLProtocol.requestedPaths.contains { $0.contains("/contents/") })
        XCTAssertEqual(
            GitHubMockURLProtocol.requestedPaths.filter { $0 == "POST /repos/someone/relay/git/blobs" }.count,
            1
        )
    }

    func testGitHubPreviewPublishDiffsWithoutWriting() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        let sameSHA = Data("same".utf8).gitBlobSHA1
        let oldSHA = Data("old".utf8).gitBlobSHA1
        GitHubMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/repos/someone/relay/git/ref/heads/main"):
                return (200, Data(#"{"object":{"sha":"commit1"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/commits/commit1"):
                return (200, Data(#"{"sha":"commit1","tree":{"sha":"tree1"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/trees/tree1"):
                return (200, Data("""
                {
                  "tree": [
                    {"path": "modules/Same.sgmodule", "type": "blob", "sha": "\(sameSHA)"},
                    {"path": "modules/Changed.sgmodule", "type": "blob", "sha": "\(oldSHA)"},
                    {"path": "modules/Stale.sgmodule", "type": "blob", "sha": "\(oldSHA)"}
                  ],
                  "truncated": false
                }
                """.utf8))
            default:
                return (404, Data(#"{"message":"not found"}"#.utf8))
            }
        }
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        settings.branch = "main"
        settings.directory = "modules"

        let report = try await GitHubClient(session: session).previewPublish(
            files: [
                PublishFile(name: "Same.sgmodule", data: Data("same".utf8)),
                PublishFile(name: "Changed.sgmodule", data: Data("new".utf8))
            ],
            deleting: ["Stale.sgmodule"],
            settings: settings,
            token: "token"
        )

        XCTAssertEqual(report.publishedFiles, ["Changed.sgmodule"])
        XCTAssertEqual(report.deletedFiles, ["Stale.sgmodule"])
        XCTAssertFalse(GitHubMockURLProtocol.requestedPaths.contains { $0.hasPrefix("POST ") || $0.hasPrefix("PATCH ") })
    }

    func testGitHubPublishRejectsDuplicateRepositoryPathsBeforeNetworkWrite() async throws {
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        settings.branch = "main"
        settings.directory = "modules"

        do {
            _ = try await GitHubClient().previewPublish(
                files: [
                    PublishFile(name: "Folder/Demo.sgmodule", data: Data("one".utf8)),
                    PublishFile(name: "Folder/Demo.sgmodule", data: Data("two".utf8))
                ],
                settings: settings,
                token: "token"
            )
            XCTFail("不应允许重复 GitHub 发布路径")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("重复路径"))
        }
    }

    func testGitHubPublishRetriesOnceWhenReferenceMoves() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        var referenceReads = 0
        var patchAttempts = 0
        GitHubMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/repos/someone/relay/git/ref/heads/main"):
                referenceReads += 1
                let commit = referenceReads == 1 ? "commit1" : "commit2"
                return (200, Data(#"{"object":{"sha":"\#(commit)"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/commits/commit1"):
                return (200, Data(#"{"sha":"commit1","tree":{"sha":"tree1"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/commits/commit2"):
                return (200, Data(#"{"sha":"commit2","tree":{"sha":"tree2"}}"#.utf8))
            case ("GET", "/repos/someone/relay/git/trees/tree1"),
                 ("GET", "/repos/someone/relay/git/trees/tree2"):
                return (200, Data(#"{"tree":[],"truncated":false}"#.utf8))
            case ("POST", "/repos/someone/relay/git/blobs"):
                return (200, Data(#"{"sha":"new-blob"}"#.utf8))
            case ("POST", "/repos/someone/relay/git/trees"):
                return (200, Data(#"{"sha":"new-tree"}"#.utf8))
            case ("POST", "/repos/someone/relay/git/commits"):
                let commit = patchAttempts == 0 ? "new-commit1" : "new-commit2"
                return (200, Data(#"{"sha":"\#(commit)","tree":{"sha":"new-tree"}}"#.utf8))
            case ("PATCH", "/repos/someone/relay/git/refs/heads/main"):
                patchAttempts += 1
                if patchAttempts == 1 {
                    return (422, Data(#"{"message":"Reference update failed"}"#.utf8))
                }
                return (200, Data(#"{"object":{"sha":"new-commit2"}}"#.utf8))
            default:
                return (404, Data(#"{"message":"not found"}"#.utf8))
            }
        }
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        settings.branch = "main"
        settings.directory = "modules"

        let report = try await GitHubClient(session: session).publish(
            files: [PublishFile(name: "Changed.sgmodule", data: Data("new".utf8))],
            settings: settings,
            token: "token"
        )

        XCTAssertTrue(report.retriedAfterConflict)
        XCTAssertEqual(report.publishedFiles, ["Changed.sgmodule"])
        XCTAssertEqual(report.commitSHA, "new-commit2")
        XCTAssertEqual(patchAttempts, 2)
        XCTAssertEqual(
            GitHubMockURLProtocol.requestedPaths.filter { $0 == "GET /repos/someone/relay/git/ref/heads/main" }.count,
            2
        )
    }

    func testModuleArgumentsAreMaterializedAndMetadataIsRemoved() {
        let content = """
        #!name=Demo
        #!arguments=feature:true,mode:auto
        #!arguments-desc=feature toggle\\nmode selector
        [Script]
        %feature%disabled = type=cron, cronexp="0 0 * * *", script-path=https://example.com/a.js
        mode = %mode%
        // source note
        """
        let info = ModuleArgumentProcessor.info(in: content)
        XCTAssertEqual(info.definitions.map(\.key), ["feature", "mode"])
        XCTAssertEqual(info.helpText, "feature toggle\nmode selector")

        let result = ModuleArgumentProcessor.materialize(content, overrides: ["feature": "#", "mode": "show"])
        XCTAssertFalse(result.contains("#!arguments="))
        XCTAssertFalse(result.contains("disabled ="))
        XCTAssertFalse(result.contains("source note"))
        XCTAssertTrue(result.contains("mode = show"))
    }

    func testLegacyArgumentsWithSpacingAndQuotedDefaultsAreMaterialized() {
        let content = """
        #!name=Maps
        #!arguments = CountryCode:"CN",Dispatcher:"AutoNavi"
        #!arguments-desc = CountryCode help
        [Script]
        maps = type=http-request,argument=CountryCode="{{{CountryCode}}}"&Dispatcher="{{{Dispatcher}}}",script-path=https://example.com/maps.js
        """

        let info = ModuleArgumentProcessor.info(in: content)
        XCTAssertEqual(info.definitions.map(\.key), ["CountryCode", "Dispatcher"])
        XCTAssertEqual(info.definitions.map(\.defaultValue), ["CN", "AutoNavi"])
        let result = ModuleArgumentProcessor.materialize(content, overrides: [:])
        XCTAssertFalse(result.contains("#!arguments"))
        XCTAssertFalse(result.contains("{{{"))
        XCTAssertTrue(result.contains("CountryCode=\"CN\"&Dispatcher=\"AutoNavi\""))
    }

    func testAdvancedOptionsSummaryOnlyAppearsWhenConfigured() {
        XCTAssertNil(ScriptHubOptions().configuredSummary)
        var options = ScriptHubOptions()
        options.policy = "Proxy"
        options.convertAllScripts = true
        XCTAssertEqual(options.configuredSummary, "脚本转换：全部 · 策略：Proxy")
    }

    func testSurgeModuleSanitizerRemovesEmptyJQAndConvertsMisplacedLoonScript() {
        let content = """
        #!name=Demo
        [Body Rewrite]
        http-response-jq ^https:\\/\\/example\\.com\\/empty\\? ''
        http-response-jq ^https:\\/\\/example\\.com\\/valid\\? '.data=[]'
        [Map Local]
        ^https:\\/\\/example\\.com\\/api url script-response-header https://example.com/scripts/clean.js
        ^https:\\/\\/example\\.com\\/blank data-type=text data="{}" status-code=200
        """

        let sanitized = SurgeModuleSanitizer.sanitize(content)

        XCTAssertFalse(sanitized.contains("example\\.com\\/empty"))
        XCTAssertTrue(sanitized.contains("http-response-jq ^https:\\/\\/example\\.com\\/valid\\? '.data=[]'"))
        XCTAssertTrue(sanitized.contains("^https:\\/\\/example\\.com\\/blank data-type=text"))
        XCTAssertTrue(sanitized.contains("[Script]"))
        XCTAssertTrue(sanitized.contains(
            "clean = type=http-response, pattern=^https:\\/\\/example\\.com\\/api, requires-body=0, script-path=https://example.com/scripts/clean.js"
        ))
        XCTAssertFalse(sanitized.contains("url script-response-header"))
        XCTAssertEqual(SurgeModuleSanitizer.sanitize(sanitized), sanitized)
    }

    func testModuleOrderingMovesItemsInListOrder() {
        XCTAssertEqual(
            ModuleOrdering.moving(["A", "B", "C"], fromOffsets: IndexSet(integer: 2), toOffset: 0),
            ["C", "A", "B"]
        )
        XCTAssertEqual(
            ModuleOrdering.moving(["A", "B", "C"], fromOffsets: IndexSet(integer: 0), toOffset: 3),
            ["B", "C", "A"]
        )
    }

    func testWebRequestParserReadsJSONBodyAndQuery() throws {
        let body = #"{"enabled":true}"#
        let request = """
        POST /api/modules/demo/enabled?source=web HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """
        let parsed = try XCTUnwrap(WebManagementServer.parseRequest(Data(request.utf8), isLoopback: true))
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/api/modules/demo/enabled")
        XCTAssertEqual(parsed.query["source"], "web")
        XCTAssertEqual(String(data: parsed.body, encoding: .utf8), body)
        XCTAssertTrue(parsed.isLoopback)
    }

    func testWebRequestParserRejectsInvalidContentLength() {
        let negative = "POST /api/update-all HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: -1\r\n\r\n"
        let huge = "POST /api/update-all HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 999999999\r\n\r\n"

        guard case .invalid = WebManagementServer.parseRequestResult(Data(negative.utf8), isLoopback: true) else {
            return XCTFail("negative Content-Length must be invalid")
        }
        guard case .invalid = WebManagementServer.parseRequestResult(Data(huge.utf8), isLoopback: true) else {
            return XCTFail("oversized Content-Length must be invalid")
        }
    }

    func testWebRequestParserDistinguishesIncompleteBodyFromInvalidLength() {
        let request = """
        POST /api/update-all HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Length: 12\r
        \r
        short
        """

        guard case .incomplete = WebManagementServer.parseRequestResult(Data(request.utf8), isLoopback: true) else {
            return XCTFail("valid Content-Length with partial body should remain incomplete")
        }
    }

    func testWebRequestSecurityAllowsSessionBootstrapWithValidToken() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: false, accessToken: "secret")
        let request = WebHTTPRequest(
            method: "POST",
            path: "/api/session",
            query: [:],
            headers: [
                "authorization": "Bearer secret",
                "host": "127.0.0.1:8787",
                "origin": "http://127.0.0.1:8787"
            ],
            body: Data(),
            isLoopback: true
        )

        XCTAssertNil(WebRequestSecurity.rejection(for: request, configuration: configuration))
    }

    func testWebRequestSecurityRejectsMissingOrWrongSessionBootstrapToken() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let missing = WebHTTPRequest(
            method: "POST",
            path: "/api/session",
            query: [:],
            headers: ["host": "127.0.0.1:8787", "origin": "http://127.0.0.1:8787"],
            body: Data(),
            isLoopback: true
        )
        let wrong = WebHTTPRequest(
            method: "POST",
            path: "/api/session",
            query: ["token": "wrong"],
            headers: ["host": "127.0.0.1:8787", "origin": "http://127.0.0.1:8787"],
            body: Data(),
            isLoopback: true
        )

        XCTAssertEqual(WebRequestSecurity.rejection(for: missing, configuration: configuration)?.status, 401)
        XCTAssertEqual(WebRequestSecurity.rejection(for: wrong, configuration: configuration)?.status, 401)
    }

    func testWebRequestSecurityRejectsRawTokenForRegularAPI() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/state",
            query: ["token": "secret"],
            headers: [:],
            body: Data(),
            isLoopback: true
        )

        XCTAssertEqual(WebRequestSecurity.rejection(for: request, configuration: configuration)?.status, 401)
    }

    func testWebRequestSecurityAllowsBearerTokenForNonBrowserAPI() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let request = WebHTTPRequest(
            method: "POST",
            path: "/api/update-all",
            query: [:],
            headers: ["authorization": "Bearer secret"],
            body: Data(),
            isLoopback: false
        )

        XCTAssertNil(WebRequestSecurity.rejection(for: request, configuration: configuration))
    }

    func testWebRequestSecurityAllowsSessionCookieWithoutQueryToken() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let session = WebRequestSecurity.sessionCookieValue(for: "secret")
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/events",
            query: [:],
            headers: ["cookie": "other=value; \(WebRequestSecurity.sessionCookieName)=\(session)"],
            body: Data(),
            isLoopback: true
        )

        XCTAssertNil(WebRequestSecurity.rejection(for: request, configuration: configuration))
    }

    func testWebRequestSecurityRejectsWrongSessionCookie() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/events",
            query: [:],
            headers: ["cookie": "\(WebRequestSecurity.sessionCookieName)=wrong"],
            body: Data(),
            isLoopback: true
        )

        XCTAssertEqual(WebRequestSecurity.rejection(for: request, configuration: configuration)?.status, 401)
    }

    func testWebSessionCookieHeaderDoesNotExposeRawToken() {
        let header = WebRequestSecurity.sessionCookieHeader(accessToken: "secret-token")

        XCTAssertFalse(header.contains("secret-token"))
        XCTAssertTrue(header.contains("\(WebRequestSecurity.sessionCookieName)="))
        XCTAssertTrue(header.contains("HttpOnly"))
        XCTAssertTrue(header.contains("SameSite=Strict"))
        XCTAssertTrue(header.contains("Path=/api"))
    }

    func testWebResponseSecurityAddsNoStoreAndBrowserHardeningHeadersToAPIResponses() {
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/state",
            query: [:],
            headers: [:],
            body: Data(),
            isLoopback: true
        )
        let headers = WebResponseSecurity.hardenedHeaders(
            for: request,
            responseHeaders: ["Content-Type": "application/json; charset=utf-8"]
        )

        XCTAssertEqual(headers["Cache-Control"], WebResponseSecurity.apiCacheControl)
        XCTAssertEqual(headers["Pragma"], "no-cache")
        XCTAssertEqual(headers["Expires"], "0")
        XCTAssertEqual(headers["X-Frame-Options"], "DENY")
        XCTAssertEqual(headers["X-Content-Type-Options"], "nosniff")
        XCTAssertEqual(headers["Referrer-Policy"], "no-referrer")
        XCTAssertEqual(headers["Permissions-Policy"], "camera=(), microphone=(), geolocation=()")
        XCTAssertEqual(headers["Cross-Origin-Opener-Policy"], "same-origin")
    }

    func testWebResponseSecurityPreservesExplicitCacheControl() {
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/modules/11111111-1111-1111-1111-111111111111/icon",
            query: [:],
            headers: [:],
            body: Data(),
            isLoopback: true
        )
        let headers = WebResponseSecurity.hardenedHeaders(
            for: request,
            responseHeaders: ["cache-control": "private, max-age=3600"]
        )

        XCTAssertEqual(headers["cache-control"], "private, max-age=3600")
        XCTAssertNil(headers["Cache-Control"])
        XCTAssertNil(headers["Pragma"])
        XCTAssertNil(headers["Expires"])
        XCTAssertEqual(headers["X-Frame-Options"], "DENY")
    }

    func testWebResponseSecurityHardensEventStreamHeaders() {
        let headers = WebResponseSecurity.eventStreamHeaders()

        XCTAssertEqual(headers["Content-Type"], "text/event-stream; charset=utf-8")
        XCTAssertEqual(headers["Cache-Control"], WebResponseSecurity.eventStreamCacheControl)
        XCTAssertEqual(headers["Pragma"], "no-cache")
        XCTAssertEqual(headers["Expires"], "0")
        XCTAssertEqual(headers["Connection"], "keep-alive")
        XCTAssertEqual(headers["X-Frame-Options"], "DENY")
        XCTAssertEqual(headers["X-Content-Type-Options"], "nosniff")
        XCTAssertEqual(headers["Referrer-Policy"], "no-referrer")
    }

    func testWebRequestSecurityRejectsCrossOriginUnsafeRequests() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let session = WebRequestSecurity.sessionCookieValue(for: "secret")
        let request = WebHTTPRequest(
            method: "POST",
            path: "/api/update-all",
            query: [:],
            headers: [
                "cookie": "\(WebRequestSecurity.sessionCookieName)=\(session)",
                "host": "127.0.0.1:8787",
                "origin": "http://evil.example"
            ],
            body: Data(),
            isLoopback: true
        )

        XCTAssertEqual(WebRequestSecurity.rejection(for: request, configuration: configuration)?.status, 403)
    }

    func testWebRequestSecurityAllowsSameOriginUnsafeRequestsWithSessionCookie() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let session = WebRequestSecurity.sessionCookieValue(for: "secret")
        let request = WebHTTPRequest(
            method: "POST",
            path: "/api/update-all",
            query: [:],
            headers: [
                "cookie": "\(WebRequestSecurity.sessionCookieName)=\(session)",
                "host": "127.0.0.1:8787",
                "origin": "http://127.0.0.1:8787"
            ],
            body: Data(),
            isLoopback: true
        )

        XCTAssertNil(WebRequestSecurity.rejection(for: request, configuration: configuration))
    }

    func testWebRequestSecurityAllowsSameOriginRefererWhenOriginIsMissing() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let session = WebRequestSecurity.sessionCookieValue(for: "secret")
        let request = WebHTTPRequest(
            method: "POST",
            path: "/api/update-all",
            query: [:],
            headers: [
                "cookie": "\(WebRequestSecurity.sessionCookieName)=\(session)",
                "host": "127.0.0.1:8787",
                "referer": "http://127.0.0.1:8787/"
            ],
            body: Data(),
            isLoopback: true
        )

        XCTAssertNil(WebRequestSecurity.rejection(for: request, configuration: configuration))
    }

    func testWebRequestSecurityRejectsUnsafeSessionCookieWithoutOriginRefererOrBearer() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let session = WebRequestSecurity.sessionCookieValue(for: "secret")
        let request = WebHTTPRequest(
            method: "POST",
            path: "/api/update-all",
            query: [:],
            headers: [
                "cookie": "\(WebRequestSecurity.sessionCookieName)=\(session)",
                "host": "127.0.0.1:8787"
            ],
            body: Data(),
            isLoopback: true
        )

        XCTAssertEqual(WebRequestSecurity.rejection(for: request, configuration: configuration)?.status, 403)
    }

    func testWebAuthenticationThrottleLimitsRepeatedFailuresAndClearsOnSuccess() {
        let throttle = WebAuthenticationThrottle(maxFailures: 2, window: 60)
        let now = Date(timeIntervalSince1970: 1_000)
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/state",
            query: [:],
            headers: [:],
            body: Data(),
            isLoopback: false,
            clientIdentifier: "192.0.2.10"
        )

        XCTAssertNil(throttle.rejection(for: request, now: now))
        throttle.recordFailure(for: request, now: now)
        XCTAssertNil(throttle.rejection(for: request, now: now.addingTimeInterval(1)))
        throttle.recordFailure(for: request, now: now.addingTimeInterval(2))
        XCTAssertEqual(throttle.rejection(for: request, now: now.addingTimeInterval(3))?.status, 429)
        throttle.recordSuccess(for: request)
        XCTAssertNil(throttle.rejection(for: request, now: now.addingTimeInterval(4)))
    }

    func testWebRequestSecurityRejectsRemoteWhenDisabled() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: false, accessToken: "secret")
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/state",
            query: ["token": "secret"],
            headers: [:],
            body: Data(),
            isLoopback: false
        )

        XCTAssertEqual(WebRequestSecurity.rejection(for: request, configuration: configuration)?.status, 403)
    }

    func testWebRequestSecurityAllowsRemoteWhenEnabledAndSessionCookieMatches() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let session = WebRequestSecurity.sessionCookieValue(for: "secret")
        let request = WebHTTPRequest(
            method: "POST",
            path: "/api/update-all",
            query: [:],
            headers: [
                "cookie": "\(WebRequestSecurity.sessionCookieName)=\(session)",
                "host": "relay.local:8787",
                "origin": "http://relay.local:8787"
            ],
            body: Data(),
            isLoopback: false
        )

        XCTAssertNil(WebRequestSecurity.rejection(for: request, configuration: configuration))
    }

    func testAppSettingsDecodesWebManagementDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.combinedModuleEnabled)
        XCTAssertFalse(settings.webServerEnabled)
        XCTAssertEqual(settings.webServerPort, 8787)
        XCTAssertFalse(settings.webServerAllowRemoteAccess)
    }

    func testMergerAddsSourceTogglesAndRemovesDeviceRestrictions() throws {
        let first = RelayModule(
            id: try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            name: "First",
            sourceURL: "https://example.com/first.sgmodule",
            sourceFormat: .surge,
            outputFileName: "first"
        )
        let second = RelayModule(
            id: try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            name: "Second",
            sourceURL: "https://example.com/second.sgmodule",
            sourceFormat: .surge,
            outputFileName: "second"
        )
        let firstContent = """
        #!name=First
        #!system=iOS
        #!requirement=CORE_VERSION>=20 && SYSTEM = 'iOS'
        [General]
        test-setting = first
        [MITM]
        hostname = %INSERT% one.example.com
        [Script]
        # source comment
        ## source heading
        // another source comment
        ; legacy source comment
        first = type=cron, cronexp="0 0 * * *", script-path=https://example.com/one.js
        """
        let secondContent = """
        #!name=Second
        #!system=mac
        [General]
        test-setting = second
        [MITM]
        hostname = %APPEND% two.example.com
        [Script]
        second = type=cron, cronexp="0 1 * * *", script-path=https://example.com/two.js
        """
        let merged = try ModuleMerger.merge([(first, firstContent), (second, secondContent)], engineRevision: "abcdef")
        XCTAssertTrue(merged.contains("#!desc=由 Surge Relay 整合 2 个模块"))
        XCTAssertFalse(merged.contains("Script-Hub abcdef"))
        XCTAssertFalse(merged.contains("#!system="))
        XCTAssertTrue(merged.contains("#!requirement=(CORE_VERSION>=20)"))
        XCTAssertFalse(merged.contains("Relay_First"))
        XCTAssertTrue(merged.contains("first = type=cron"))
        XCTAssertFalse(merged.contains("source comment"))
        XCTAssertFalse(merged.contains("source heading"))
        XCTAssertFalse(merged.contains("# --- [Relay_"))
        XCTAssertFalse(merged.contains("# 此文件由"))
        XCTAssertTrue(merged.contains("hostname = %INSERT% one.example.com, two.example.com"))
        let mitm = try XCTUnwrap(merged.range(of: "[MITM]")?.upperBound)
        let script = try XCTUnwrap(merged.range(of: "[Script]")?.lowerBound)
        XCTAssertFalse(merged[mitm..<script].contains("# --- [Relay_"))
        XCTAssertTrue(merged.contains("test-setting = first"))
        XCTAssertFalse(merged.contains("test-setting = second"))
        XCTAssertLessThan(
            try XCTUnwrap(merged.range(of: "first = type=cron")?.lowerBound),
            try XCTUnwrap(merged.range(of: "second = type=cron")?.lowerBound)
        )
    }
}

private final class SourceRevisionURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (status: Int, headers: [String: String], data: Data) = (200, [:], Data())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let responseValue = Self.response
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: responseValue.status,
            httpVersion: "HTTP/1.1",
            headerFields: responseValue.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseValue.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class GitHubMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (status: Int, data: Data))?
    nonisolated(unsafe) static var requestedPaths: [String] = []

    static func reset() {
        handler = nil
        requestedPaths = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let url = request.url!
        let query = url.query.map { "?\($0)" } ?? ""
        Self.requestedPaths.append("\(method) \(url.path)\(query)")
        let responseValue = Self.handler?(request) ?? (500, Data(#"{"message":"unhandled request"}"#.utf8))
        let response = HTTPURLResponse(
            url: url,
            statusCode: responseValue.0,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseValue.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

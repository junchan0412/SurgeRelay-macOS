import Foundation
import XCTest
@testable import SurgeRelay

final class ModuleDraftPlannerTests: XCTestCase {
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

    func testModuleDraftPlannerBuildsLocalAddPlanWithoutLosingOriginalPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let source = root.appending(path: "Ads/My Module.sgmodule").absoluteString
        var draft = ModuleDraft()
        draft.name = "  My Local Module  "
        draft.sourceURL = source
        draft.sourceFormat = .automatic
        draft.outputFileName = "Converted Copy.sgmodule"
        draft.outputFolder = " Converted "
        draft.category = " #工具 "
        draft.storageLocation = .local
        draft.publishesStandalone = true
        draft.iconURL = " https://example.com/icon.png "

        let plan = try ModuleDraftPlanner.addPlan(
            from: draft,
            modules: [],
            combinedModuleFileName: "Surge Relay",
            localModuleDirectory: root.path
        )

        XCTAssertEqual(plan.module.name, "My Local Module")
        XCTAssertEqual(plan.module.sourceURL, source)
        XCTAssertEqual(plan.module.category, "#工具")
        XCTAssertEqual(plan.module.outputFolder, "Converted")
        XCTAssertEqual(plan.module.outputFileName, "Converted Copy.sgmodule")
        XCTAssertEqual(plan.module.localStorageRelativePath, "Ads/My Module.sgmodule")
        XCTAssertTrue(plan.module.preservesOutputFileName)
        XCTAssertEqual(plan.module.storageLocation, .local)
        XCTAssertEqual(plan.module.detectedSourceFormat, .surge)
        XCTAssertEqual(plan.customIconURL, "https://example.com/icon.png")
        XCTAssertEqual(plan.module.iconURL, "https://example.com/icon.png")
    }

    func testModuleDraftPlannerRejectsDuplicateEffectiveSource() throws {
        let existing = RelayModule(
            name: "Existing",
            sourceURL: "HTTPS://Example.com:443/modules/demo.sgmodule#fragment",
            outputFileName: "Existing"
        )
        var draft = ModuleDraft()
        draft.name = "Duplicate"
        draft.sourceURL = "https://example.com/modules/demo.sgmodule"

        XCTAssertThrowsError(try ModuleDraftPlanner.addPlan(
            from: draft,
            modules: [existing],
            combinedModuleFileName: "Surge Relay",
            localModuleDirectory: ""
        )) { error in
            XCTAssertEqual(error.localizedDescription, RelayError.duplicateSourceURL.localizedDescription)
        }
    }

    func testModuleDraftPlannerReturnsNoChangeUpdatePlan() throws {
        let module = RelayModule(
            name: "Stable",
            sourceURL: "https://example.com/stable.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Stable",
            category: "#工具",
            outputFolder: "Tools",
            publishesStandalone: true,
            isEnabled: false,
            customIconURL: "https://example.com/icon.png"
        )
        let plan = try XCTUnwrap(ModuleDraftPlanner.updatePlan(
            id: module.id,
            from: ModuleDraft(module: module),
            modules: [module],
            combinedModuleFileName: "Surge Relay",
            localModuleDirectory: ""
        ))

        XCTAssertFalse(plan.hasChanges)
        XCTAssertFalse(plan.sourceChanged)
        XCTAssertFalse(plan.customIconChanged)
        XCTAssertEqual(plan.module, module)
    }

    func testModuleDraftPlannerClearsSourceStateWhenSourceChanges() throws {
        let module = RelayModule(
            name: "Wrapped",
            sourceURL: "https://example.com/old.conf",
            sourceFormat: .quantumultX,
            outputFileName: "Wrapped",
            iconURL: "https://example.com/detected.png",
            customIconURL: "https://example.com/custom.png",
            scriptHubSubscription: ScriptHubSubscriptionInfo(
                subscriptionURL: "http://script.hub/file/_start_/https://example.com/old.conf/_end_/Wrapped.sgmodule",
                originalURL: "https://example.com/old.conf",
                outputName: "Wrapped.sgmodule",
                sourceType: "qx-rewrite",
                target: "surge-module",
                category: nil,
                options: ScriptHubOptions()
            ),
            lastUpdatedAt: Date(timeIntervalSince1970: 1_000),
            contentHash: "converted-hash",
            sourceETag: "etag",
            sourceLastModified: "date",
            sourceContentHash: "source-hash",
            sourceCheckedAt: Date(timeIntervalSince1970: 1_100),
            conversionEngineRevision: "revision",
            state: .current,
            lastError: "old error"
        )
        var draft = ModuleDraft(module: module)
        draft.sourceURL = "https://example.com/new.conf"
        draft.iconURL = ""

        let plan = try XCTUnwrap(ModuleDraftPlanner.updatePlan(
            id: module.id,
            from: draft,
            modules: [module],
            combinedModuleFileName: "Surge Relay",
            localModuleDirectory: ""
        ))

        XCTAssertTrue(plan.hasChanges)
        XCTAssertTrue(plan.sourceChanged)
        XCTAssertTrue(plan.customIconChanged)
        XCTAssertEqual(plan.module.sourceURL, "https://example.com/new.conf")
        XCTAssertNil(plan.module.iconURL)
        XCTAssertNil(plan.module.customIconURL)
        XCTAssertEqual(plan.module.state, .never)
        XCTAssertNil(plan.module.lastError)
        XCTAssertNil(plan.module.sourceETag)
        XCTAssertNil(plan.module.sourceLastModified)
        XCTAssertNil(plan.module.sourceContentHash)
        XCTAssertNil(plan.module.sourceCheckedAt)
        XCTAssertNil(plan.module.conversionEngineRevision)
        XCTAssertNil(plan.module.scriptHubSubscription)
        XCTAssertEqual(plan.module.lastUpdatedAt, module.lastUpdatedAt)
        XCTAssertEqual(plan.module.contentHash, module.contentHash)
    }
}

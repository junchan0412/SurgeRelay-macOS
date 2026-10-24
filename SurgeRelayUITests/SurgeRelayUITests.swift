import AppKit
import XCTest

final class SurgeRelayUITests: XCTestCase {
    @MainActor
    func testSettingsEditorAndDetailWorkflow() throws {
        continueAfterFailure = false
        let qaDirectory = try makeQADirectory()
        defer { try? FileManager.default.removeItem(at: qaDirectory) }

        let app = try launchBuiltApplication(in: qaDirectory)
        defer { app.terminate() }

        XCTAssertTrue(app.windows["Surge Relay"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["workspace.overview"].waitForExistence(timeout: 5))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["workspace.activity"].waitForExistence(timeout: 5))
        let activitySearch = app.textFields["activity.search"]
        XCTAssertTrue(activitySearch.waitForExistence(timeout: 3))
        enterText("missing-activity", in: activitySearch, app: app)
        XCTAssertTrue(app.staticTexts["没有匹配的活动"].waitForExistence(timeout: 3))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["还没有活动记录"].waitForExistence(timeout: 3))
        app.typeKey("1", modifierFlags: .command)
        app.buttons["workspace.metric.attention"].click()
        let resetFilters = app.buttons["modules.reset-filters"]
        XCTAssertTrue(resetFilters.waitForExistence(timeout: 3))
        resetFilters.click()

        let settingsButton = app.buttons["settings.open"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 5))

        selectSettingsPage("publishing", title: "发布", in: app)
        XCTAssertTrue(app.staticTexts["存储位置"].waitForExistence(timeout: 3))
        selectSettingsPage("credentials", title: "凭据", in: app)
        XCTAssertTrue(app.staticTexts["GitHub Token"].waitForExistence(timeout: 3))
        selectSettingsPage("webManagement", title: "Web 管理", in: app)
        XCTAssertTrue(app.staticTexts["Web 管理"].waitForExistence(timeout: 3))
        app.buttons["settings.done"].click()

        let addButton = app.buttons["modules.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()
        XCTAssertTrue(app.descendants(matching: .any)["module-editor.root"].waitForExistence(timeout: 5))

        let nameField = app.textFields["module-editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        enterText("UI QA Module", in: nameField, app: app)

        let sourceField = app.textFields["module-editor.source-url"]
        XCTAssertTrue(sourceField.waitForExistence(timeout: 3))
        enterText("https://8.8.8.8/ui-qa.sgmodule", in: sourceField, app: app)
        app.buttons["module-editor.save"].click()

        XCTAssertTrue(app.descendants(matching: .any)["module-detail.root"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["UI QA Module"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["管理关系"].waitForExistence(timeout: 3))

        app.buttons["module-detail.edit"].click()
        XCTAssertTrue(app.descendants(matching: .any)["module-editor.root"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["module-editor.name"].value as? String, "UI QA Module")
    }

    @MainActor
    func testActivityFileSearchAndClearScope() throws {
        continueAfterFailure = false
        let qaDirectory = try makeQADirectory()
        defer { try? FileManager.default.removeItem(at: qaDirectory) }
        let configuration = qaDirectory.appending(path: "Configuration", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
        let history: [[String: Any]] = [
            ["moduleName": "GitHub 发布", "outcome": "published", "duration": 1.25,
             "message": "已发布模块与资源", "publishedFiles": ["Rules/Proxy.sgmodule"],
             "deletedFiles": ["Legacy/Old.sgmodule"], "commitSHA": "1234567890abcdef"],
            ["moduleName": "订阅更新", "outcome": "failed", "duration": 0.75,
             "message": "来源返回 HTTP 404"]
        ]
        try JSONSerialization.data(withJSONObject: history)
            .write(to: configuration.appending(path: "update-history.json"), options: .atomic)

        let app = try launchBuiltApplication(in: qaDirectory)
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Surge Relay"].waitForExistence(timeout: 10))
        app.typeKey("2", modifierFlags: .command)

        let search = app.textFields["activity.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        enterText("proxy.sgmodule", in: search, app: app)
        XCTAssertTrue(app.staticTexts["1 条匹配 · 共 2 条记录"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["GitHub 发布"].exists)
        XCTAssertFalse(app.staticTexts["来源返回 HTTP 404"].exists)

        app.buttons["activity.clear"].click()
        XCTAssertTrue(app.staticTexts["清空全部 2 条活动记录？"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
            "清空范围包含搜索中未显示的记录", "清空范围包含搜索中未显示的记录")).firstMatch.exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["1 条匹配 · 共 2 条记录"].waitForExistence(timeout: 3))

        enterText("no-matching-published-file", in: search, app: app)
        XCTAssertTrue(app.staticTexts["没有匹配的活动"].waitForExistence(timeout: 3))
        app.buttons["activity.clear-search"].click()
        XCTAssertTrue(app.staticTexts["2 条记录"].waitForExistence(timeout: 3))

        app.buttons["activity.clear"].click()
        let confirmClear = app.sheets.buttons["清空记录"]
        XCTAssertTrue(confirmClear.waitForExistence(timeout: 3))
        confirmClear.click()
        XCTAssertTrue(app.staticTexts["还没有活动记录"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testWindowLayoutSearchBatchSelectionAndScrolling() throws {
        continueAfterFailure = false
        let qaDirectory = try makeQADirectory()
        defer { try? FileManager.default.removeItem(at: qaDirectory) }
        let moduleName = try writeLayoutFixture(in: qaDirectory)

        let app = try launchBuiltApplication(in: qaDirectory)
        defer { app.terminate() }

        let window = app.windows["Surge Relay"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        prepareResizableWindow(in: app, window: window)
        captureLayoutEvidence(in: app, window: window, name: "Initial layout")
        let search = app.textFields["modules.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let reset = app.buttons["modules.reset-filters"]
        if reset.exists { reset.click() }
        assertSidebarLayout(in: app, window: window)

        enterText("no-matching-layout-module", in: search, app: app)
        XCTAssertTrue(app.staticTexts["没有搜索结果"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertEqual(search.value as? String, "")
        let moduleRow = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", moduleName, moduleName)).firstMatch
        let localSection = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "展开本地模块", "收起本地模块")).firstMatch
        XCTAssertTrue(localSection.waitForExistence(timeout: 5))
        let expandLocal = app.buttons["展开本地模块"]
        if expandLocal.exists { expandLocal.click() }
        XCTAssertTrue(moduleRow.waitForExistence(timeout: 5))
        moduleRow.click()

        let detail = app.descendants(matching: .any)["module-detail.root"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["管理关系"].waitForExistence(timeout: 3))
        assertSidebarLayout(in: app, window: window)
        assertDetailBelowToolbar(detail, window: window)

        app.descendants(matching: .any)["modules.more-actions"].click()
        let selectMenuItem = app.descendants(matching: .any)["modules.toggle-batch-selection"]
        XCTAssertTrue(selectMenuItem.waitForExistence(timeout: 3))
        selectMenuItem.click()
        XCTAssertTrue(app.staticTexts["modules.selected-count"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["modules.publish-selected"].exists)
        assertSidebarLayout(in: app, window: window)

        app.descendants(matching: .any)["modules.more-actions"].click()
        let selectAll = app.descendants(matching: .any)["modules.select-all"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3))
        selectAll.click()
        XCTAssertTrue(app.staticTexts["已选 1 个"].waitForExistence(timeout: 3))
        app.descendants(matching: .any)["modules.more-actions"].click()
        app.descendants(matching: .any)["modules.toggle-batch-selection"].click()
        XCTAssertTrue(app.staticTexts["modules.selected-count"].waitForNonExistence(timeout: 3))

        let originalSize = window.frame.size
        resize(window, to: CGSize(width: 920, height: 600))
        captureLayoutEvidence(in: app, window: window, name: "Compact layout")
        XCTAssertGreaterThanOrEqual(window.frame.width, 918)
        XCTAssertGreaterThanOrEqual(window.frame.height, 598)
        if originalSize.width > 960 {
            XCTAssertLessThan(window.frame.width, originalSize.width - 20)
        }
        assertSidebarLayout(in: app, window: window)
        assertDetailBelowToolbar(detail, window: window)

        let title = detail.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", moduleName, moduleName)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        let titleY = title.frame.minY
        detail.scroll(byDeltaX: 0, deltaY: -650)
        let didScroll = NSPredicate { _, _ in
            !title.exists || title.frame.minY < titleY - 20
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: didScroll, object: nil)], timeout: 3), .completed)
        assertDetailBelowToolbar(detail, window: window)
        captureLayoutEvidence(in: app, window: window, name: "Scrolled detail layout")
        XCTAssertTrue(app.buttons["settings.open"].isHittable)
        let parameters = detail.staticTexts["模块参数"]
        XCTAssertTrue(parameters.exists)

        let sidebarToggle = window.toolbars.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "sidebar", "边栏"
        )).firstMatch
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 3))
        sidebarToggle.click()
        let sidebarHidden = NSPredicate { _, _ in !search.exists || !search.isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: sidebarHidden, object: nil)], timeout: 3), .completed)
        assertDetailBelowToolbar(detail, window: window)
        captureLayoutEvidence(in: app, window: window, name: "Scrolled detail with sidebar hidden")
        app.buttons["settings.open"].click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 3))
        app.buttons["settings.done"].click()
        sidebarToggle.click()
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        assertSidebarLayout(in: app, window: window)

        resize(window, to: originalSize)
        assertSidebarLayout(in: app, window: window)
        assertDetailBelowToolbar(detail, window: window)
        captureLayoutEvidence(in: app, window: window, name: "Restored layout after resize and scroll")
    }

    @MainActor
    func testAttentionAndLongErrorRemainUsableInCompactWindow() throws {
        continueAfterFailure = false
        let qaDirectory = try makeQADirectory()
        defer { try? FileManager.default.removeItem(at: qaDirectory) }
        let moduleName = try writeLayoutFixture(in: qaDirectory, failing: true)
        let app = try launchBuiltApplication(in: qaDirectory)
        defer { app.terminate() }
        let window = app.windows["Surge Relay"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        prepareResizableWindow(in: app, window: window)
        resize(window, to: CGSize(width: 920, height: 600))
        let reset = app.buttons["modules.reset-filters"]
        if reset.exists { reset.click() }
        XCTAssertTrue(app.buttons["workspace.metric.attention"].waitForExistence(timeout: 5))
        captureLayoutEvidence(in: app, window: window, name: "Compact attention overview")
        app.buttons["workspace.metric.attention"].click()
        let detail = app.descendants(matching: .any)["module-detail.root"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let error = app.descendants(matching: .any)["module-detail.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(error.frame.height, 222)
        assertDetailBelowToolbar(detail, window: window)
        captureLayoutEvidence(in: app, window: window, name: "Compact long module error")

        app.buttons["modules.update-all"].click()
        let errorDetails = app.buttons["work.error-details"]
        XCTAssertTrue(errorDetails.waitForExistence(timeout: 15))
        app.descendants(matching: .any)["modules.more-actions"].click()
        let selectMenuItem = app.descendants(matching: .any)["modules.toggle-batch-selection"]
        XCTAssertTrue(selectMenuItem.waitForExistence(timeout: 3))
        selectMenuItem.click()
        enterText(moduleName, in: app.textFields["modules.search"], app: app)
        XCTAssertTrue(app.staticTexts["modules.selected-count"].waitForExistence(timeout: 3))
        assertSidebarLayout(in: app, window: window)
        let list = app.descendants(matching: .any)["modules.list"]
        let status = app.descendants(matching: .any)["work.status"]
        let listContentFrame = list.frame.insetBy(dx: 1, dy: 1)
        XCTAssertTrue(window.frame.contains(listContentFrame))
        XCTAssertTrue(window.frame.contains(status.frame))
        XCTAssertFalse(listContentFrame.intersects(status.frame))
        XCTAssertGreaterThanOrEqual(list.frame.height, 99)
        XCTAssertLessThanOrEqual(status.frame.height, 192)
        captureLayoutEvidence(in: app, window: window, name: "Compact filtered batch selection with error")
        errorDetails.click()
        let fullError = app.descendants(matching: .any)["work.error-detail-content"]
        XCTAssertTrue(fullError.waitForExistence(timeout: 3))
        let closeError = app.buttons["work.close-error-details"]
        XCTAssertTrue(closeError.waitForExistence(timeout: 3))
        XCTAssertTrue(closeError.isHittable)
        closeError.click()
        XCTAssertTrue(fullError.waitForNonExistence(timeout: 3))
        app.buttons["work.dismiss-error"].click()
        XCTAssertTrue(errorDetails.waitForNonExistence(timeout: 3))
        assertSidebarLayout(in: app, window: window)
    }

    private func makeQADirectory() throws -> URL {
        let directory = URL(filePath: "/private/tmp/SurgeRelayUIQA", directoryHint: .isDirectory)
            .appending(path: "SurgeRelayUIQA-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func launchBuiltApplication(in qaDirectory: URL) throws -> XCUIApplication {
        let products = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let appURL = products.appending(path: "Surge Relay.app", directoryHint: .isDirectory).standardizedFileURL
        let bundle = try XCTUnwrap(Bundle(url: appURL), "UI 测试必须使用 runner 同目录下的新构建产物")
        let identifier = try XCTUnwrap(bundle.bundleIdentifier)
        let app = XCUIApplication(url: appURL)
        app.launchEnvironment["SURGE_RELAY_UI_QA"] = "1"
        app.launchEnvironment["SURGE_RELAY_UI_QA_ROOT"] = qaDirectory.path
        app.launchArguments = ["--surge-relay-ui-qa", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains {
            $0.bundleURL?.standardizedFileURL == appURL
        }, "实际运行的应用必须来自本次测试的构建目录")
        if !app.windows["Surge Relay"].waitForExistence(timeout: 2) {
            let windowMenu = app.menuBars.menuBarItems.matching(NSPredicate(
                format: "label IN %@ OR title IN %@", ["窗口", "Window"], ["窗口", "Window"]
            )).firstMatch
            windowMenu.click()
            app.menuItems["Surge Relay"].click()
        }
        let evidence = XCTAttachment(string: "app=\(appURL.path)\nqaRoot=\(qaDirectory.path)")
        evidence.name = "构建产物与隔离目录"
        evidence.lifetime = .keepAlways
        add(evidence)
        return app
    }

    @MainActor
    private func enterText(_ text: String, in field: XCUIElement, app: XCUIApplication) {
        let pasteboard = NSPasteboard.general
        let previous: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        defer { pasteboard.clearContents(); pasteboard.writeObjects(previous) }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(field.value as? String, text)
    }

    private func writeLayoutFixture(in root: URL, failing: Bool = false) throws -> String {
        let configuration = root.appending(path: "Configuration", directoryHint: .isDirectory)
        let cache = root.appending(path: "Cache", directoryHint: .isDirectory)
        let components = cache.appending(path: "Components", directoryHint: .isDirectory)
        let modules = root.appending(path: "Modules", directoryHint: .isDirectory)
        let output = root.appending(path: "Output", directoryHint: .isDirectory)
        let sourceFolder = modules.appending(path: String(repeating: "Long-Source-Folder-", count: 6), directoryHint: .isDirectory)
        for directory in [configuration, components, sourceFolder, output] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let moduleID = UUID().uuidString
        let name = "QA Layout " + String(repeating: "Very Long Module Title ", count: 7).trimmingCharacters(in: .whitespaces)
        let fileName = "Long-Layout-Module.sgmodule"
        let source = sourceFolder.appending(path: fileName)
        let arguments = (1...24).map { "Parameter\($0):DefaultValue\($0)" }.joined(separator: ",")
        let content = "#!name=\(name)\n#!desc=Isolated layout regression fixture\n#!arguments=\(arguments)\n\n[Rule]\nDOMAIN,layout-fixture.invalid,DIRECT\n"
        if !failing {
            try Data(content.utf8).write(to: source)
            try Data(content.utf8).write(to: components.appending(path: "\(moduleID).cache"))
        }
        let relativePath = sourceFolder.lastPathComponent + "/" + fileName
        try writeJSON([[
            "id": moduleID, "name": name, "sourceURL": source.absoluteString, "sourceFormat": "surge",
            "outputFileName": fileName, "category": "Native Layout QA", "outputFolder": sourceFolder.lastPathComponent,
            "storageLocation": "local", "storageTargets": ["local"], "localStorageRelativePath": relativePath,
            "preservesOutputFileName": true,
            "createdAt": "2026-10-02T00:00:00Z", "lastUpdatedAt": "2026-10-02T00:00:00Z",
            "contentHash": "layout-fixture", "refreshIntervalMinutes": 0, "state": failing ? "failed" : "current",
            "lastError": failing ? String(repeating: "无法读取来源：" + source.absoluteString + "\n", count: 30) as Any : NSNull()
        ]], to: configuration.appending(path: "modules.json"))
        try writeJSON([
            "outputDirectory": output.path, "localModuleDirectory": modules.path,
            "refreshIntervalMinutes": 0,
            "automaticallyUpdateOnLaunch": false, "automaticallyUpdateScriptHub": false,
            "automaticallyPublish": false, "watchesLocalModuleChanges": false, "launchAtLogin": false,
            "publishToLocal": false, "publishToGitHub": false, "webServerEnabled": false,
            "github": ["owner": "", "repository": "", "branch": "main", "directory": "modules"], "githubToken": ""
        ], to: configuration.appending(path: "settings.json"))
        try writeJSON([Any](), to: configuration.appending(path: "update-history.json"))
        let workspaceID = "00000000-0000-0000-0000-000000000101"
        try writeJSON(["activeID": workspaceID, "workspaces": [[
            "id": workspaceID, "name": "Native Layout QA", "configurationDirectory": configuration.absoluteString,
            "cacheDirectory": cache.absoluteString, "isLegacyDefault": true
        ]]], to: root.appending(path: "workspaces.json"))
        return name
    }

    private func writeJSON(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    @MainActor
    private func assertSidebarLayout(in app: XCUIApplication, window: XCUIElement,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let search = app.textFields["modules.search"]
        let actions = app.descendants(matching: .any)["modules.actions"]
        let toolbar = window.toolbars.firstMatch
        XCTAssertTrue(search.exists, file: file, line: line)
        XCTAssertTrue(actions.exists, file: file, line: line)
        XCTAssertTrue(toolbar.exists, file: file, line: line)
        XCTAssertGreaterThanOrEqual(search.frame.minY, toolbar.frame.maxY - 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(actions.frame.minY, search.frame.maxY - 1, file: file, line: line)
        XCTAssertFalse(search.frame.intersects(actions.frame), file: file, line: line)
        for buttonID in ["modules.add", "modules.update-all", "modules.publish-all", "modules.more-actions"] {
            let button = app.descendants(matching: .any)[buttonID]
            XCTAssertTrue(button.exists, file: file, line: line)
            XCTAssertTrue(window.frame.contains(button.frame), file: file, line: line)
            XCTAssertTrue(actions.frame.insetBy(dx: -1, dy: -1).contains(button.frame), file: file, line: line)
            XCTAssertFalse(button.frame.intersects(toolbar.frame), file: file, line: line)
            XCTAssertFalse(button.frame.intersects(search.frame), file: file, line: line)
        }
    }

    @MainActor
    private func assertDetailBelowToolbar(_ detail: XCUIElement, window: XCUIElement,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let toolbar = window.toolbars.firstMatch
        XCTAssertTrue(detail.exists, file: file, line: line)
        XCTAssertTrue(toolbar.exists, file: file, line: line)
        XCTAssertGreaterThanOrEqual(detail.frame.minY, toolbar.frame.maxY - 1, file: file, line: line)
        XCTAssertFalse(detail.frame.intersects(toolbar.frame), file: file, line: line)
        XCTAssertTrue(toolbar.buttons["settings.open"].isHittable, file: file, line: line)
    }

    @MainActor
    private func prepareResizableWindow(in app: XCUIApplication, window: XCUIElement) {
        app.activate()
        let windowMenu = app.menuBars.menuBarItems.matching(NSPredicate(
            format: "label IN %@ OR title IN %@", ["窗口", "Window"], ["窗口", "Window"]
        )).firstMatch
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 3))
        windowMenu.click()
        let exitFullScreen = app.menuItems.matching(NSPredicate(
            format: "label BEGINSWITH[c] %@ OR label BEGINSWITH %@ OR title BEGINSWITH[c] %@ OR title BEGINSWITH %@",
            "Exit Full Screen", "退出全屏", "Exit Full Screen", "退出全屏"
        )).firstMatch
        if exitFullScreen.exists {
            exitFullScreen.click()
        } else {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
        app.activate()
        captureLayoutEvidence(in: app, window: window, name: "Activated window before layout assertions")
        let ready = NSPredicate { _, _ in
            let search = app.textFields["modules.search"]
            let toolbar = window.toolbars.firstMatch
            return search.exists && search.isHittable && toolbar.exists &&
                window.frame.contains(search.frame) && search.frame.minY >= toolbar.frame.maxY - 1
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5), .completed)
    }

    @MainActor
    private func captureLayoutEvidence(in app: XCUIApplication, window: XCUIElement, name: String) {
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    @MainActor
    private func resize(_ window: XCUIElement, to size: CGSize) {
        let initialFrame = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        let destination = corner.withOffset(CGVector(dx: size.width - initialFrame.width,
                                                    dy: size.height - initialFrame.height))
        corner.click(forDuration: 0.2, thenDragTo: destination)
    }

    @MainActor
    private func selectSettingsPage(_ page: String, title: String, in app: XCUIApplication) {
        let item = app.descendants(matching: .any)["settings.tab.\(page)"]
        if item.exists { item.click(); return }
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.click()
    }
}

import Foundation
import XCTest

final class SurgeRelayUITests: XCTestCase {
    @MainActor
    func testSettingsEditorAndDetailWorkflow() {
        continueAfterFailure = false
        let qaDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SurgeRelayUIQA", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: qaDirectory)

        let app = XCUIApplication()
        app.launchEnvironment["SURGE_RELAY_UI_QA"] = "1"
        app.launchArguments.append("--surge-relay-ui-qa")
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.windows["Surge Relay"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["workspace.overview"].waitForExistence(timeout: 5))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["workspace.activity"].waitForExistence(timeout: 5))
        let activitySearch = app.textFields["activity.search"]
        XCTAssertTrue(activitySearch.waitForExistence(timeout: 3))
        activitySearch.click()
        activitySearch.typeText("missing-activity")
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
        XCTAssertTrue(app.otherElements["settings.root"].waitForExistence(timeout: 5))

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
        XCTAssertTrue(app.otherElements["module-editor.root"].waitForExistence(timeout: 5))

        let nameField = app.textFields["module-editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.click()
        nameField.typeText("UI QA Module")

        let sourceField = app.textFields["module-editor.source-url"]
        XCTAssertTrue(sourceField.waitForExistence(timeout: 3))
        sourceField.click()
        sourceField.typeText("https://8.8.8.8/ui-qa.sgmodule")
        app.buttons["module-editor.save"].click()

        XCTAssertTrue(app.descendants(matching: .any)["module-detail.root"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["UI QA Module"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["管理关系"].waitForExistence(timeout: 3))

        app.buttons["module-detail.edit"].click()
        XCTAssertTrue(app.otherElements["module-editor.root"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["module-editor.name"].value as? String, "UI QA Module")
    }

    @MainActor
    func testActivityFileSearchAndClearScope() throws {
        continueAfterFailure = false
        let qaDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SurgeRelayUIQA", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: qaDirectory)
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

        let app = XCUIApplication()
        app.launchEnvironment["SURGE_RELAY_UI_QA"] = "1"
        app.launchArguments.append("--surge-relay-ui-qa")
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Surge Relay"].waitForExistence(timeout: 10))
        app.typeKey("2", modifierFlags: .command)

        let search = app.textFields["activity.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("proxy.sgmodule")
        XCTAssertTrue(app.staticTexts["1 条匹配 · 共 2 条记录"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["GitHub 发布"].exists)
        XCTAssertFalse(app.staticTexts["来源返回 HTTP 404"].exists)

        app.buttons["activity.clear"].click()
        XCTAssertTrue(app.staticTexts["清空全部 2 条活动记录？"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "清空范围包含搜索中未显示的记录")).firstMatch.exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["1 条匹配 · 共 2 条记录"].waitForExistence(timeout: 3))

        search.click()
        app.typeKey("a", modifierFlags: .command)
        search.typeText("no-matching-published-file")
        XCTAssertTrue(app.staticTexts["没有匹配的活动"].waitForExistence(timeout: 3))
        app.buttons["activity.clear-search"].click()
        XCTAssertTrue(app.staticTexts["2 条记录"].waitForExistence(timeout: 3))

        app.buttons["activity.clear"].click()
        let confirmClear = app.buttons["清空记录"]
        XCTAssertTrue(confirmClear.waitForExistence(timeout: 3))
        confirmClear.click()
        XCTAssertTrue(app.staticTexts["还没有活动记录"].waitForExistence(timeout: 3))
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

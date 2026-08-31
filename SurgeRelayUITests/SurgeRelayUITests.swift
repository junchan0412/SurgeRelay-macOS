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

        let settingsButton = app.buttons["settings.open"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.click()
        XCTAssertTrue(app.otherElements["settings.root"].waitForExistence(timeout: 5))

        app.buttons["settings.tab.publishing"].click()
        XCTAssertTrue(app.staticTexts["存储位置"].waitForExistence(timeout: 3))
        app.buttons["settings.tab.credentials"].click()
        XCTAssertTrue(app.staticTexts["GitHub Token"].waitForExistence(timeout: 3))
        app.buttons["settings.tab.webManagement"].click()
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

        XCTAssertTrue(app.otherElements["module-detail.root"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["UI QA Module"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["管理关系"].waitForExistence(timeout: 3))

        app.buttons["module-detail.edit"].click()
        XCTAssertTrue(app.otherElements["module-editor.root"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["module-editor.name"].value as? String, "UI QA Module")
    }
}

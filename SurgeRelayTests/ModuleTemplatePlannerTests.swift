import Foundation
import XCTest
@testable import SurgeRelay

final class ModuleTemplatePlannerTests: XCTestCase {
    func testTemplateCopiesPresetsWithoutSourceHeadersArgumentsOrScriptCredentials() throws {
        var options = ScriptHubOptions()
        options.convertAllScripts = true
        options.policy = "Proxy"
        options.requestHeaders = "Authorization: Bearer HEADER_SECRET"
        options.argumentValues = "ARGUMENT_SECRET"
        options.prependScript = "const token = 'SCRIPT_SECRET';"
        options.evalOriginalURL = "https://test.invalid/?token=EVAL_SECRET"
        let module = RelayModule(name: "Original", sourceURL: "https://test.invalid/?token=SOURCE_SECRET", sourceFormat: .loon,
                                 outputFileName: "Original", category: "Privacy", outputFolder: "Rules",
                                 storageTargets: [.local, .gitHub], scriptHubOptions: options,
                                 argumentOverrides: ["key": "OVERRIDE_SECRET"], customIconURL: "https://test.invalid/?key=ICON_SECRET")
        let template = try ModuleTemplatePlanner.template(from: module, name: "Privacy preset")
        let json = String(decoding: try JSONEncoder().encode(template), as: UTF8.self)
        for secret in ["HEADER_SECRET", "ARGUMENT_SECRET", "SCRIPT_SECRET", "EVAL_SECRET", "SOURCE_SECRET", "OVERRIDE_SECRET", "ICON_SECRET"] {
            XCTAssertFalse(json.contains(secret))
        }
        XCTAssertTrue(template.scriptHubOptions.convertAllScripts)
        XCTAssertEqual(template.scriptHubOptions.policy, "Proxy")
        XCTAssertEqual(template.storageTargets, [.local, .gitHub])
        XCTAssertNotEqual(template.id, module.id)
        let draft = ModuleTemplatePlanner.draft(from: template)
        XCTAssertEqual(draft.name, "Privacy preset")
        XCTAssertEqual(draft.category, "Privacy")
        XCTAssertEqual(draft.sourceFormat, .loon)
        XCTAssertTrue(draft.sourceURL.isEmpty)
        XCTAssertTrue(draft.outputFileName.isEmpty)
        XCTAssertTrue(draft.iconURL.isEmpty)
        XCTAssertNotNil(draft.validationMessage, "Creating from a template must still require a new source")
    }

    func testTemplateNameCannotBeEmptyAndCodableRoundTripPreservesWhitelist() throws {
        let module = RelayModule(name: "Demo", sourceURL: "https://test.invalid/demo.sgmodule", outputFileName: "Demo")
        XCTAssertThrowsError(try ModuleTemplatePlanner.template(from: module, name: "  "))
        let template = try ModuleTemplatePlanner.template(from: module, name: "Demo preset")
        XCTAssertEqual(try JSONDecoder().decode(ModuleTemplate.self, from: JSONEncoder().encode(template)), template)
    }
}

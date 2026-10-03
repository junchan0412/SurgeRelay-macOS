import Foundation
import XCTest
@testable import SurgeRelay

final class ModuleLintPlannerTests: XCTestCase {
    func testValidModuleDoesNotParseJavaScriptAssetsAsModules() throws {
        let files = [
            module("#!name=Demo\n[Rule]\nDOMAIN,example.org,DIRECT\n[MITM]\nhostname = example.org"),
            PublishFile(name: "assets/code.js", data: Data([0xff, 0x00]))
        ]
        let issues = ModuleLintPlanner.check(files: files)
        XCTAssertTrue(issues.isEmpty)
        XCTAssertNoThrow(try ModuleLintPlanner.throwIfBlocking(issues))
    }

    func testMissingSectionMalformedHeaderAndNULAreBlocking() {
        let empty = ModuleLintPlanner.check(files: [module("DOMAIN,example.org,DIRECT")])
        XCTAssertTrue(empty.contains { $0.code == "missing-section" && $0.severity == .error })
        XCTAssertThrowsError(try ModuleLintPlanner.throwIfBlocking(empty))
        let malformed = ModuleLintPlanner.check(files: [module("#!name=Demo\n[Rule\nFINAL,DIRECT")])
        XCTAssertTrue(malformed.contains { $0.code == "malformed-section" && $0.line == 2 && $0.severity == .error })
        let nul = ModuleLintPlanner.check(files: [module("[Rule]\nDOMAIN,example\0.org,DIRECT")])
        XCTAssertTrue(nul.contains { $0.code == "nul-character" && $0.line == 2 && $0.severity == .error })
        let invalid = ModuleLintPlanner.check(files: [PublishFile(name: "Demo.sgmodule", data: Data([0xff]))])
        XCTAssertEqual(invalid.first?.code, "invalid-utf8")
    }

    func testMetadataOnlyModuleWarnsWithoutBlockingCompatibility() {
        let issues = ModuleLintPlanner.check(files: [module("#!name=Only Metadata\n# comment")])
        XCTAssertEqual(issues.first?.severity, .warning)
        XCTAssertNoThrow(try ModuleLintPlanner.throwIfBlocking(issues))
    }

    func testDuplicateAndUnknownSectionAreWarningsWithRelatedLines() throws {
        let issues = ModuleLintPlanner.check(files: [module("[Rule]\nDOMAIN,example.org,DIRECT\nDOMAIN,example.org,DIRECT\n[Future Section]\nvalue = allowed\n[General]\nloglevel = info\nloglevel = warning")])
        XCTAssertTrue(issues.contains { $0.code == "duplicate-entry" && $0.line == 3 && $0.relatedLine == 2 })
        XCTAssertTrue(issues.contains { $0.code == "unknown-section" && $0.line == 4 })
        XCTAssertTrue(issues.contains { $0.code == "duplicate-key" && $0.line == 8 && $0.relatedLine == 7 })
        XCTAssertTrue(issues.allSatisfy { $0.severity == .warning })
        XCTAssertNoThrow(try ModuleLintPlanner.throwIfBlocking(issues))
    }

    func testOwnedGeneratedAssetMustBeIncludedEvenWhenReferencedThroughHTTP() {
        let id = UUID()
        let asset = "assets/\(id.uuidString.lowercased())/helper.js"
        let text = "[Script]\nDemo = type=http-response,script-path=https://example.org/modules/\(asset)"
        let missing = ModuleLintPlanner.check(files: [module(text)], ownedModuleIDs: [id])
        XCTAssertTrue(missing.contains { $0.code == "missing-owned-asset" && $0.line == 2 && $0.severity == .error })
        let present = ModuleLintPlanner.check(files: [module(text), PublishFile(name: asset, data: Data("// script".utf8))], ownedModuleIDs: [id])
        XCTAssertTrue(present.isEmpty)
        XCTAssertTrue(ModuleLintPlanner.check(files: [module(text)], ownedModuleIDs: [UUID()]).isEmpty)
    }

    func testPercentEscapedAssetAndModuleRelativePathsResolveWithoutNetwork() {
        let id = UUID()
        let asset = "assets/\(id.uuidString.lowercased())/helper file.js"
        let text = "[Script]\nDemo = type=http-response,script-path=https://example.org/\(asset.replacingOccurrences(of: " ", with: "%20"))"
        let files = [module(text), PublishFile(name: asset, data: Data())]
        XCTAssertTrue(ModuleLintPlanner.check(files: files, ownedModuleIDs: [id]).isEmpty)
        let relative = [module("[Script]\nDemo = type=http-response,script-path=helper.js", path: "Ads/Demo.sgmodule"), PublishFile(name: "Ads/helper.js", data: Data())]
        XCTAssertTrue(ModuleLintPlanner.check(files: relative).isEmpty)
    }

    func testUnverifiedRelativeScriptAndInvalidRemoteURLWarnWithoutBlocking() throws {
        let text = "[Script]\nOne = type=http-response,script-path=outside.js\nTwo = type=http-request,script-path=https://"
        let issues = ModuleLintPlanner.check(files: [module(text)])
        XCTAssertTrue(issues.contains { $0.code == "unverified-relative-script" })
        XCTAssertTrue(issues.contains { $0.code == "invalid-script-url" })
        XCTAssertNoThrow(try ModuleLintPlanner.throwIfBlocking(issues))
    }

    func testRulePatternContainingScriptPathIsNotTreatedAsAssetReference() {
        let id = UUID()
        let text = "[Rule]\nURL-REGEX,^script-path=assets/\(id.uuidString.lowercased())/absent.js,REJECT"
        XCTAssertTrue(ModuleLintPlanner.check(files: [module(text)], ownedModuleIDs: [id]).isEmpty)
    }

    func testIssueLimitCannotHideALateBlockingError() {
        let text = "[Rule]\n" + String(repeating: "FINAL,DIRECT\n", count: ModuleLintPlanner.maximumIssues + 20) + "[Broken"
        let issues = ModuleLintPlanner.check(files: [module(text)])
        XCTAssertEqual(issues.count, ModuleLintPlanner.maximumIssues)
        XCTAssertEqual(issues.last?.code, "issue-limit")
        XCTAssertEqual(issues.last?.severity, .error)
        XCTAssertThrowsError(try ModuleLintPlanner.throwIfBlocking(issues))
        XCTAssertEqual(issues, ModuleLintPlanner.check(files: [module(text)]))
    }

    private func module(_ text: String, path: String = "Demo.sgmodule") -> PublishFile {
        PublishFile(name: path, data: Data(text.utf8))
    }
}

import Foundation
import XCTest
@testable import SurgeRelay

final class ModulePreviewContentProviderTests: XCTestCase {
    @MainActor
    func testModulePreviewContentProviderRecoversLocalSurgeSourceWithoutCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Local Source.sgmodule")
        let sourceContent = """
        #!name=Original
        #!arguments=Mode:默认策略

        [Rule]
        FINAL,{{{Mode}}}
        """
        try Data(sourceContent.utf8).write(to: source)

        let moduleID = UUID()
        var cachedComponent: String?
        let provider = ModulePreviewContentProvider(
            hasComponent: { _ in false },
            readComponent: { _ in throw RelayError.invalidOutput("missing component") },
            readConvertedComponent: { _ in throw RelayError.invalidOutput("missing converted") },
            writeComponent: { content, id in
                XCTAssertEqual(id, moduleID)
                cachedComponent = content
            },
            readCombined: { Data() },
            materialize: { content, overrides in
                ModuleArgumentProcessor.materialize(content, overrides: overrides)
            },
            argumentInfo: { content in
                ModuleArgumentProcessor.info(in: content)
            },
            applyingModuleMetadata: { name, category, iconURL, content in
                ModuleMetadataParser.applyingModuleMetadata(
                    name: name,
                    category: category,
                    iconURL: iconURL,
                    to: content
                )
            }
        )
        let module = RelayModule(
            id: moduleID,
            name: "Previewed",
            sourceURL: source.absoluteString,
            sourceFormat: .surge,
            outputFileName: "Local Source.sgmodule",
            category: "#工具",
            argumentOverrides: ["Mode": "DIRECT"]
        )

        let preview = try await provider.previewContent(for: module)

        XCTAssertEqual(cachedComponent, SurgeModuleSanitizer.sanitize(sourceContent))
        XCTAssertTrue(preview.contains("#!name=Previewed"))
        XCTAssertTrue(preview.contains("#!category=#工具"))
        XCTAssertFalse(preview.contains("#!arguments="))
        XCTAssertTrue(preview.contains("FINAL,DIRECT"))
    }

    @MainActor
    func testModulePreviewContentProviderRejectsRemoteSourceWithoutCache() async {
        let provider = ModulePreviewContentProvider(
            hasComponent: { _ in false },
            readComponent: { _ in throw RelayError.invalidOutput("missing component") },
            readConvertedComponent: { _ in throw RelayError.invalidOutput("missing converted") },
            writeComponent: { _, _ in },
            readCombined: { Data() },
            materialize: { content, _ in content },
            argumentInfo: { _ in ModuleArgumentInfo() },
            applyingModuleMetadata: { _, _, _, content in content }
        )
        let module = RelayModule(
            name: "Remote",
            sourceURL: "https://example.com/remote.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Remote.sgmodule"
        )

        do {
            _ = try await provider.previewContent(for: module)
            XCTFail("Remote modules without cache should ask the user to update first")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("模块尚无转换缓存"))
        }
    }

    @MainActor
    func testModulePreviewContentProviderFallsBackFromEmptyOverrideToConvertedCache() async throws {
        let moduleID = UUID()
        var readConvertedCount = 0
        let provider = ModulePreviewContentProvider(
            hasComponent: { _ in true },
            readComponent: { _ in "\n  \t" },
            readConvertedComponent: { id in
                XCTAssertEqual(id, moduleID)
                readConvertedCount += 1
                return "#!name=Converted\n[Rule]\nFINAL,DIRECT\n"
            },
            writeComponent: { _, _ in },
            readCombined: { Data() },
            materialize: { content, _ in content },
            argumentInfo: { _ in ModuleArgumentInfo() },
            applyingModuleMetadata: { _, _, _, content in content }
        )
        let module = RelayModule(
            id: moduleID,
            name: "Converted",
            sourceURL: "https://example.com/module.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Converted.sgmodule"
        )

        let preview = try await provider.previewContent(for: module)

        XCTAssertTrue(preview.contains("FINAL,DIRECT"))
        XCTAssertEqual(readConvertedCount, 1)
    }

    @MainActor
    func testModulePreviewContentProviderRejectsEmptyRemoteCache() async {
        let provider = ModulePreviewContentProvider(
            hasComponent: { _ in true },
            readComponent: { _ in "" },
            readConvertedComponent: { _ in "\n" },
            writeComponent: { _, _ in },
            readCombined: { Data() },
            materialize: { content, _ in content },
            argumentInfo: { _ in ModuleArgumentInfo() },
            applyingModuleMetadata: { _, _, _, content in content }
        )
        let module = RelayModule(
            name: "Empty",
            sourceURL: "https://example.com/empty.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Empty.sgmodule"
        )

        do {
            _ = try await provider.previewContent(for: module)
            XCTFail("Empty remote caches should not be treated as successful previews")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("模块缓存为空"))
        }
    }
}

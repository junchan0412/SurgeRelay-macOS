import Foundation
import XCTest
@testable import SurgeRelay

final class PublishFileAssemblerTests: XCTestCase {
    func testPublishFileAssemblerBuildsCombinedStandaloneAndAssets() async throws {
        let standaloneID = UUID()
        let combinedID = UUID()
        let standalone = RelayModule(
            id: standaloneID,
            name: "Standalone",
            sourceURL: "https://example.com/standalone.sgmodule",
            outputFileName: "Standalone",
            category: "Rules",
            outputFolder: "Folder",
            publishesStandalone: true,
            argumentOverrides: ["mode": "strict"]
        )
        let combinedOnly = RelayModule(
            id: combinedID,
            name: "Combined",
            sourceURL: "https://example.com/combined.sgmodule",
            outputFileName: "Combined",
            publishesStandalone: false,
            isEnabled: true
        )
        var requestedAssetIDs = Set<UUID>()

        let files = try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(
                plan: PublishPlan(
                    standaloneModules: [standalone],
                    combinedModuleIDs: [combinedOnly.id]
                ),
                combinedData: Data("combined".utf8),
                combinedFileName: "Combined",
                includeAssets: true,
                destination: .gitHub,
                localModuleDirectory: "/Users/example/Surge"
            ),
            readComponent: { id in
                id == standaloneID ? "source" : nil
            },
            generatedAssetFiles: { ids in
                requestedAssetIDs = ids
                return [PublishFile(name: "assets/icon.png", data: Data("asset".utf8))]
            },
            materialize: { content, overrides in
                "\(content):\(overrides["mode"] ?? "")"
            },
            applyingModuleMetadata: { name, category, iconURL, content in
                "\(name)|\(category)|\(iconURL ?? "nil")|\(content)"
            },
            cancellationCheckpoint: {}
        )

        XCTAssertEqual(files.map(\.name), ["Combined.sgmodule", "Folder/Standalone.sgmodule", "assets/icon.png"])
        XCTAssertEqual(String(data: files[0].data, encoding: .utf8), "combined")
        // The standalone export now carries the reconstructed Script-Hub
        // `#SUBSCRIBED` marker, matching the in-app preview transformation.
        let expectedStandalone = ModuleMetadataParser.applyingScriptHubSubscription(
            ModuleMetadataParser.scriptHubSubscription(for: standalone),
            to: "Standalone|Rules|nil|source:strict"
        )
        XCTAssertEqual(String(data: files[1].data, encoding: .utf8), expectedStandalone)
        XCTAssertTrue(expectedStandalone.hasPrefix("#SUBSCRIBED "))
        XCTAssertTrue(expectedStandalone.contains("https://example.com/standalone.sgmodule"))
        XCTAssertEqual(String(data: files[2].data, encoding: .utf8), "asset")
        XCTAssertEqual(requestedAssetIDs, [standaloneID, combinedID])
    }

    func testPublishFileAssemblerWritesSubscribedMarkerBelowHeaderForRemoteSource() async throws {
        let module = RelayModule(
            id: UUID(),
            name: "Reven",
            sourceURL: "https://gist.githubusercontent.com/example/raw/Reven.sgmodule",
            sourceFormat: .surge,
            outputFileName: "reven.sgmodule",
            category: "#8会员模块",
            publishesStandalone: true
        )
        let source = "#!name=Reven\n#!category=#8会员模块\n\n[MITM]\nhostname = %APPEND% api.example.com\n"

        let files = try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(
                plan: PublishPlan(standaloneModules: [module], combinedModuleIDs: []),
                combinedData: nil,
                combinedFileName: "Combined",
                includeAssets: false,
                destination: .local,
                localModuleDirectory: "/Users/example/Surge"
            ),
            readComponent: { _ in source },
            generatedAssetFiles: { _ in [] },
            materialize: { content, _ in content },
            applyingModuleMetadata: { _, _, _, content in content },
            cancellationCheckpoint: {}
        )

        let written = try XCTUnwrap(String(data: try XCTUnwrap(files.first?.data), encoding: .utf8))
        let lines = written.components(separatedBy: "\n")
        let subscribedLines = lines.filter { $0.hasPrefix("#SUBSCRIBED ") }
        XCTAssertEqual(subscribedLines.count, 1, "exactly one #SUBSCRIBED marker should be written")
        let marker = try XCTUnwrap(subscribedLines.first)
        XCTAssertTrue(marker.contains("script.hub/file/_start_/"))
        XCTAssertTrue(marker.contains("https://gist.githubusercontent.com/example/raw/Reven.sgmodule"))
        XCTAssertTrue(marker.contains("target=surge-module"))
        // The marker sits inside the `#!` header block, not above `#!name`.
        let subscribedIndex = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("#SUBSCRIBED ") })
        let nameIndex = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("#!name=") })
        XCTAssertGreaterThan(subscribedIndex, nameIndex)
    }

    func testPublishFileAssemblerOmitsSubscribedMarkerForSelfAuthoredSource() async throws {
        let module = RelayModule(
            id: UUID(),
            name: "SelfAuthored",
            sourceURL: "file:///Users/example/Surge/SelfAuthored.sgmodule",
            sourceFormat: .surge,
            outputFileName: "SelfAuthored.sgmodule",
            publishesStandalone: true
        )
        let source = "#!name=SelfAuthored\n[MITM]\nhostname = %APPEND% a.example.com\n"

        let files = try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(
                plan: PublishPlan(standaloneModules: [module], combinedModuleIDs: []),
                combinedData: nil,
                combinedFileName: "Combined",
                includeAssets: false,
                destination: .gitHub,
                localModuleDirectory: "/Users/example/Surge"
            ),
            readComponent: { _ in source },
            generatedAssetFiles: { _ in [] },
            materialize: { content, _ in content },
            applyingModuleMetadata: { _, _, _, content in content },
            cancellationCheckpoint: {}
        )

        let written = try XCTUnwrap(String(data: try XCTUnwrap(files.first?.data), encoding: .utf8))
        XCTAssertFalse(written.contains("#SUBSCRIBED"), "self-authored modules must not gain a subscription marker")
        XCTAssertEqual(written, source)
    }

    func testPublishFileAssemblerSkipsLocalSelfExportOnlyForLocalDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let source = root.appending(path: "Ads/Original.sgmodule")
        let module = RelayModule(
            id: UUID(),
            name: "Original",
            sourceURL: source.absoluteString,
            sourceFormat: .surge,
            outputFileName: "Original.sgmodule",
            outputFolder: "Ads",
            publishesStandalone: true
        )
        let plan = PublishPlan(standaloneModules: [module], combinedModuleIDs: [])

        let localFiles = try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(
                plan: plan,
                combinedData: nil,
                combinedFileName: "Combined",
                includeAssets: false,
                destination: .local,
                localModuleDirectory: root.path
            ),
            readComponent: { _ in "source" },
            generatedAssetFiles: { _ in [] },
            materialize: { content, _ in content },
            applyingModuleMetadata: { _, _, _, content in content },
            cancellationCheckpoint: {}
        )
        let gitHubFiles = try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(
                plan: plan,
                combinedData: nil,
                combinedFileName: "Combined",
                includeAssets: false,
                destination: .gitHub,
                localModuleDirectory: root.path
            ),
            readComponent: { _ in "source" },
            generatedAssetFiles: { _ in [] },
            materialize: { content, _ in content },
            applyingModuleMetadata: { _, _, _, content in content },
            cancellationCheckpoint: {}
        )

        XCTAssertTrue(localFiles.isEmpty)
        XCTAssertEqual(gitHubFiles.map(\.name), ["Ads/Original.sgmodule"])
        XCTAssertEqual(String(data: try XCTUnwrap(gitHubFiles.first?.data), encoding: .utf8), "source")
    }
}

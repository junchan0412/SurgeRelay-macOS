import Foundation
import XCTest
@testable import SurgeRelay

final class PublishFileAssemblerTests: XCTestCase {
    func testChangedClientCannotPublishPreviousClientCacheUnderANewExtension() async throws {
        var module = RelayModule(name: "Changed", sourceURL: "https://example.org/Demo.plugin", outputFormat: .stash, outputFileName: "Changed")
        module.lastConvertedOutputFormat = .surge
        do {
            _ = try await PublishFileAssembler.files(
                request: PublishFileAssemblyRequest(plan: PublishPlan(standaloneModules: [module]), includeAssets: false,
                    destination: .gitHub, localModuleDirectory: "/tmp/Modules"),
                readComponent: { _ in XCTFail("The previous-client cache must not be read for publication"); return "[Script]\n" },
                generatedAssetFiles: { _ in [] }, materialize: { text, _ in text },
                applyingModuleMetadata: { _, _, _, _, text in text }, cancellationCheckpoint: {}
            )
            XCTFail("Changing the output client requires a new conversion")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("先更新模块生成 Stash 输出"))
        }
    }

    func testStashPublishingPreservesYAMLBodyAndOwnsTheCorrectExtension() async throws {
        let body = "http:\n  mitm:\n    - example.org\nscript-providers:\n  Demo:\n    script: |\n      console.log('first');\n\n\n      console.log('second');\n"
        let module = RelayModule(name: "Managed", sourceURL: "https://example.org/Demo.plugin", sourceFormat: .loon,
            outputFormat: .stash, outputFileName: "Managed", category: "Network")
        let files = try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(plan: PublishPlan(standaloneModules: [module]), includeAssets: false,
                destination: .local, localModuleDirectory: "/tmp/Modules"),
            readComponent: { _ in "name: Old\n" + body }, generatedAssetFiles: { _ in [] },
            materialize: { _, _ in XCTFail("Stash must preserve scalar whitespace"); return "" },
            applyingModuleMetadata: { _, _, _, _, _ in XCTFail("Stash must use YAML metadata"); return "" },
            cancellationCheckpoint: {}
        )
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.name, "Managed.stoverride")
        let text = try XCTUnwrap(String(data: file.data, encoding: .utf8))
        XCTAssertTrue(text.contains("name: \"Managed\""))
        XCTAssertTrue(text.hasSuffix(body))
        XCTAssertTrue(text.contains("target=stash-stoverride"))
        let wrapped = ManagedPublishedFile.dataWrapping(file.data, relativePath: file.name)
        XCTAssertTrue(ManagedPublishedFile.isManaged(wrapped, relativePath: "Managed.stoverride"))
        XCTAssertTrue(String(decoding: wrapped, as: UTF8.self).hasSuffix(body))
    }

    func testMissingStandaloneCacheStopsAssemblyBeforeProducingCleanupCandidates() async throws {
        let ready = RelayModule(name: "Ready", sourceURL: "https://example.com/ready.sgmodule", outputFileName: "Ready")
        let missing = RelayModule(name: "Missing", sourceURL: "https://example.com/missing.sgmodule", outputFileName: "Missing")
        var requestedAssets = false
        do {
            _ = try await PublishFileAssembler.files(
                request: PublishFileAssemblyRequest(plan: PublishPlan(standaloneModules: [ready, missing]),
                    includeAssets: true, destination: .local,
                    localModuleDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path),
                readComponent: { id in id == ready.id ? "[Rule]\nFINAL,DIRECT" : nil },
                generatedAssetFiles: { _ in requestedAssets = true; return [] },
                materialize: { content, _ in content },
                applyingModuleMetadata: { _, _, _, _, content in content },
                cancellationCheckpoint: {}
            )
            XCTFail("Missing current content must not silently drop an enabled standalone output")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Missing"))
            XCTAssertTrue(error.localizedDescription.contains("缺少转换缓存"))
        }
        XCTAssertFalse(requestedAssets)
    }


    func testPublishFileAssemblerWritesSubscribedMarkerBelowHeaderForRemoteSource() async throws {
        let module = RelayModule(
            id: UUID(),
            name: "Reven",
            sourceURL: "https://gist.githubusercontent.com/example/raw/Reven.sgmodule",
            sourceFormat: .surge,
            outputFileName: "reven.sgmodule",
            category: "#8会员模块"
        )
        let source = "#!name=Reven\n#!category=#8会员模块\n\n[MITM]\nhostname = %APPEND% api.example.com\n"

        let files = try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(
                plan: PublishPlan(standaloneModules: [module]),
                includeAssets: false,
                destination: .local,
                localModuleDirectory: "/Users/example/Surge"
            ),
            readComponent: { _ in source },
            generatedAssetFiles: { _ in [] },
            materialize: { content, _ in content },
            applyingModuleMetadata: { _, _, _, _, content in content },
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
            outputFileName: "SelfAuthored.sgmodule"
        )
        let source = "#!name=SelfAuthored\n[MITM]\nhostname = %APPEND% a.example.com\n"

        let files = try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(
                plan: PublishPlan(standaloneModules: [module]),
                includeAssets: false,
                destination: .gitHub,
                localModuleDirectory: "/Users/example/Surge"
            ),
            readComponent: { _ in source },
            generatedAssetFiles: { _ in [] },
            materialize: { content, _ in content },
            applyingModuleMetadata: { _, _, _, _, content in content },
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
            outputFolder: "Ads"
        )
        let plan = PublishPlan(standaloneModules: [module])

        let localFiles = try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(
                plan: plan,
                includeAssets: false,
                destination: .local,
                localModuleDirectory: root.path
            ),
            readComponent: { _ in "source" },
            generatedAssetFiles: { _ in [] },
            materialize: { content, _ in content },
            applyingModuleMetadata: { _, _, _, _, content in content },
            cancellationCheckpoint: {}
        )
        let gitHubFiles = try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(
                plan: plan,
                includeAssets: false,
                destination: .gitHub,
                localModuleDirectory: root.path
            ),
            readComponent: { _ in "source" },
            generatedAssetFiles: { _ in [] },
            materialize: { content, _ in content },
            applyingModuleMetadata: { _, _, _, _, content in content },
            cancellationCheckpoint: {}
        )

        XCTAssertTrue(localFiles.isEmpty)
        XCTAssertEqual(gitHubFiles.map(\.name), ["Ads/Original.sgmodule"])
        XCTAssertEqual(String(data: try XCTUnwrap(gitHubFiles.first?.data), encoding: .utf8), "source")
    }
}

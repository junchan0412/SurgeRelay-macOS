import Foundation
import XCTest
@testable import SurgeRelay

final class ManagedPublishedFileTests: XCTestCase {
    func testManagedPublishedFileAddsMarkerAfterSurgeMetadataHeader() throws {
        let original = Data("""
        #!name=Demo
        #!desc=Description
        [Rule]
        DOMAIN,example.com,DIRECT
        """.utf8)

        let wrapped = ManagedPublishedFile.dataWrapping(original, relativePath: "Ads/Demo.sgmodule")
        let content = try XCTUnwrap(String(data: wrapped, encoding: .utf8))
        let lines = content.components(separatedBy: "\n")

        XCTAssertEqual(lines[0], "#!name=Demo")
        XCTAssertEqual(lines[1], "#!desc=Description")
        XCTAssertEqual(lines[2], "# Surge Relay managed output")
        XCTAssertEqual(lines[3], "# surge-relay-relative-path: Ads/Demo.sgmodule")
        XCTAssertTrue(ManagedPublishedFile.isManaged(wrapped))
    }

    func testManagedPublishedFileDoesNotWrapTwice() {
        let original = Data("[General]\n".utf8)
        let wrapped = ManagedPublishedFile.dataWrapping(original, relativePath: "Demo.sgmodule")
        let wrappedAgain = ManagedPublishedFile.dataWrapping(wrapped, relativePath: "Demo.sgmodule")

        XCTAssertEqual(wrappedAgain, wrapped)
        XCTAssertTrue(ManagedPublishedFile.isManaged(wrappedAgain))
    }

    func testManagedPublishedFileTreatsPlainContentAsUnmanaged() {
        XCTAssertFalse(ManagedPublishedFile.isManaged(Data("[General]\n".utf8)))
    }
    func testResourcesKeepExactJavaScriptAndBinaryBytes() {
        let script = Data("\"use strict\";\r\nfunction main() { return 42; }\r\n".utf8)
        let binary = Data([0x00, 0xff, 0x89, 0x00, 0xfe])
        XCTAssertEqual(ManagedPublishedFile.dataWrapping(script, relativePath: "assets/main.js"), script)
        XCTAssertEqual(ManagedPublishedFile.dataWrapping(binary, relativePath: "assets/payload.bin"), binary)
        XCTAssertFalse(ManagedPublishedFile.requiresInlineMarker("assets/main.js"))
        XCTAssertTrue(ManagedPublishedFile.requiresInlineMarker("Demo.MODULE"))
    }

    func testLegacyResourceOwnershipRequiresMarkerAndMatchingPathIncludingBinary() {
        let path = "assets/old.bin"
        var wrapped = Data("# Surge Relay managed output\n# surge-relay-relative-path: \(path)\n".utf8)
        wrapped.append(contentsOf: [0xff, 0x00, 0xfe])
        XCTAssertTrue(ManagedPublishedFile.isManaged(wrapped, relativePath: path))
        XCTAssertFalse(ManagedPublishedFile.isManaged(wrapped, relativePath: "assets/other.bin"))
        let incidental = Data("# Surge Relay managed output\nconst value = 1;".utf8)
        XCTAssertFalse(ManagedPublishedFile.isManaged(incidental, relativePath: "assets/user.js"))
    }

}

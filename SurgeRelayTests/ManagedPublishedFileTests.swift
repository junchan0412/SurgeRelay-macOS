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
}

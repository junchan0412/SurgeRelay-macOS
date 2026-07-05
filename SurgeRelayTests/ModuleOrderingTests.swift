import Foundation
import XCTest
@testable import SurgeRelay

final class ModuleOrderingTests: XCTestCase {
    private struct Item: Identifiable, Equatable {
        var id: String
        var title: String
    }

    func testModuleOrderingMovesItemsInListOrder() {
        XCTAssertEqual(
            ModuleOrdering.moving(["A", "B", "C"], fromOffsets: IndexSet(integer: 2), toOffset: 0),
            ["C", "A", "B"]
        )
        XCTAssertEqual(
            ModuleOrdering.moving(["A", "B", "C"], fromOffsets: IndexSet(integer: 0), toOffset: 3),
            ["B", "C", "A"]
        )
        XCTAssertEqual(
            ModuleOrdering.moving(["A", "B", "C"], fromOffsets: IndexSet(integer: 42), toOffset: 1),
            ["A", "B", "C"]
        )
    }

    func testModuleOrderingReordersIdentifiableValuesByID() {
        let first = Item(id: "a", title: "A")
        let second = Item(id: "b", title: "B")
        let third = Item(id: "c", title: "C")

        XCTAssertEqual(
            ModuleOrdering.reordering([first, second, third], matching: ["c", "a", "b"]),
            [third, first, second]
        )
        XCTAssertNil(ModuleOrdering.reordering([first, second, third], matching: ["a", "b"]))
        XCTAssertNil(ModuleOrdering.reordering([first, second, third], matching: ["a", "b", "x"]))
        XCTAssertNil(ModuleOrdering.reordering([first, second, third], matching: ["a", "a", "b"]))
        XCTAssertNil(ModuleOrdering.reordering([first, Item(id: "a", title: "Duplicate")], matching: ["a", "a"]))
    }
}

import Testing
@testable import BoskCore

/// Users arrange tabs by dragging. An off-by-one here puts the tab one place away
/// from where the user dropped it.
struct TabOrderingTests {
    @Test("Dropping a tab below its old place puts it exactly where the drop line was")
    func dropBelow() {
        // Tabs A B C D; drag A to the line above D (row 3).
        let destination = TabOrdering.moveDestination(from: 0, proposedRow: 3)
        #expect(TabOrdering.moved(["A", "B", "C", "D"], from: 0, to: destination) == ["B", "C", "A", "D"])
    }

    @Test("Dropping a tab above its old place puts it exactly where the drop line was")
    func dropAbove() {
        let destination = TabOrdering.moveDestination(from: 3, proposedRow: 1)
        #expect(TabOrdering.moved(["A", "B", "C", "D"], from: 3, to: destination) == ["A", "D", "B", "C"])
    }

    @Test("Dropping a tab at the end of the list moves it to the end")
    func dropAtEnd() {
        let destination = TabOrdering.moveDestination(from: 1, proposedRow: 4)
        #expect(TabOrdering.moved(["A", "B", "C", "D"], from: 1, to: destination) == ["A", "C", "D", "B"])
    }

    @Test("In the grid, the left half of a tile inserts before it and the right half after it")
    func gridHalves() {
        // 3 columns of 60 x 50 tiles, 8 pt apart, 5 tiles.
        func index(_ x: Double, _ y: Double) -> Int {
            TabOrdering.gridInsertionIndex(x: x, y: y, columns: 3, tileWidth: 60, tileHeight: 50, spacing: 8, count: 5)
        }
        #expect(index(10, 10) == 0)   // left half of tile 0
        #expect(index(50, 10) == 1)   // right half of tile 0
        #expect(index(80, 10) == 1)   // left half of tile 1
        #expect(index(10, 70) == 3)   // second row, left half of tile 3
    }

    @Test("A drop below the last tile appends, and never goes past the end")
    func gridClamps() {
        let index = TabOrdering.gridInsertionIndex(x: 150, y: 300, columns: 3, tileWidth: 60,
                                                   tileHeight: 50, spacing: 8, count: 5)
        #expect(index == 5)
    }
}

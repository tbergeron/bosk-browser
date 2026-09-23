import Foundation

/// Index math for drag and drop in the tab list and the pinned grid.
public enum TabOrdering {
    /// A list drop "above row N" gives the index the item has after the move.
    /// The dragged item leaves its old place first, so a drop below it moves up by one.
    public static func moveDestination(from source: Int, proposedRow: Int) -> Int {
        source < proposedRow ? proposedRow - 1 : proposedRow
    }

    /// The array after moving one item, the same way the list and grid move tabs.
    public static func moved<Element>(_ items: [Element], from source: Int, to destination: Int) -> [Element] {
        var items = items
        let item = items.remove(at: source)
        items.insert(item, at: min(max(0, destination), items.count))
        return items
    }

    /// Where a drop at `point` (top-left origin) goes in a grid of `count` tiles.
    /// A drop on the right half of a tile goes after it.
    public static func gridInsertionIndex(x: Double, y: Double, columns: Int, tileWidth: Double,
                                          tileHeight: Double, spacing: Double, count: Int) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        let column = min(columns - 1, max(0, Int(x / (tileWidth + spacing))))
        let row = max(0, Int(y / (tileHeight + spacing)))
        let xInTile = x - Double(column) * (tileWidth + spacing)
        let index = row * columns + column + (xInTile > tileWidth / 2 ? 1 : 0)
        return min(index, count)
    }
}

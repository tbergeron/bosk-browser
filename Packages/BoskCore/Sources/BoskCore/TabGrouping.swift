import Foundation

/// The colors a tab group can have, in the order of the color dots.
public enum TabGroupColor: String, Codable, CaseIterable, Sendable {
    case grey, blue, red, yellow, green, pink, purple, cyan, orange

    /// The first color no group uses, so two new groups do not look the same.
    /// When all colors are in use, it starts again at the first color.
    public static func firstUnused(in used: [TabGroupColor]) -> TabGroupColor {
        allCases.first { !used.contains($0) } ?? allCases[used.count % allCases.count]
    }
}

/// A named, colored group of normal tabs in one window.
public struct TabGroup: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var color: TabGroupColor
    public var isFolded: Bool

    public init(id: UUID = UUID(), title: String = "", color: TabGroupColor, isFolded: Bool = false) {
        self.id = id
        self.title = title
        self.color = color
        self.isFolded = isFolded
    }
}

/// One row of the tab list.
public enum SidebarItem: Equatable, Sendable {
    case group(UUID)
    /// An index in the window's normal tabs.
    case tab(Int)
    case newTab
}

/// Rows and drop math for tab groups. The tabs stay one flat list; the tabs of a group
/// are always next to each other, and each function here keeps it that way.
public enum TabGrouping {
    /// A header before the first tab of each group. A folded group shows only the
    /// selected tab, so the user always sees where they are. "New Tab" is last.
    public static func items(groupIDs: [UUID?], folded: Set<UUID>, selectedIndex: Int?) -> [SidebarItem] {
        var items: [SidebarItem] = []
        for (index, group) in groupIDs.enumerated() {
            if let group, index == 0 || groupIDs[index - 1] != group { items.append(.group(group)) }
            if let group, folded.contains(group), index != selectedIndex { continue }
            items.append(.tab(index))
        }
        items.append(.newTab)
        return items
    }

    /// Where a tab dropped in the list goes: an insertion index in the tabs (before the
    /// dragged tab leaves its old place) and the group it joins.
    /// - Parameters:
    ///   - row: The row of the drop.
    ///   - on: The drop is on the row (only for a group header), not above it.
    public static func dropTarget(items: [SidebarItem], groupIDs: [UUID?], row: Int,
                                  on: Bool) -> (index: Int, groupID: UUID?) {
        let item = items.indices.contains(row) ? items[row] : .newTab
        switch item {
        case .group(let group) where on:
            // On a header: the end of that group.
            let last = groupIDs.lastIndex(of: group) ?? groupIDs.count - 1
            return (last + 1, group)
        case .group(let group):
            // Above a header: outside every group, just before this one.
            return (groupIDs.firstIndex(of: group) ?? groupIDs.count, nil)
        case .tab(let index):
            // A tab row of a group always has its header or a tab of the same group above it,
            // so a drop above it is inside that group.
            return (index, groupIDs[index])
        case .newTab:
            return (groupIDs.count, nil)
        }
    }

    /// The group of a tab put in at `index`. Between two tabs of one group, the tab joins
    /// that group, so a group never splits in two. Next to a tab of `preferred`, it joins
    /// `preferred` (a reopened tab goes back to its group, a link stays in its opener's group).
    public static func groupForInsertion(at index: Int, groupIDs: [UUID?], preferred: UUID? = nil) -> UUID? {
        let above = index > 0 && index - 1 < groupIDs.count ? groupIDs[index - 1] : nil
        let below = index < groupIDs.count ? groupIDs[index] : nil
        if let above, above == below { return above }
        if let preferred, preferred == above || preferred == below { return preferred }
        return nil
    }
}

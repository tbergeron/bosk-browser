import Foundation
import Testing
@testable import BoskCore

/// Tab groups are drawn from a flat tab list. If a rule here is wrong, a group splits in two,
/// a tab lands in the wrong group, or the user loses sight of the current tab.
struct TabGroupingTests {
    let g = UUID()
    let h = UUID()

    @Test("Each group gets one header, just before its first tab; ungrouped tabs have no header")
    func headers() {
        let items = TabGrouping.items(groupIDs: [nil, g, g, nil, h], folded: [], selectedIndex: nil)
        #expect(items == [.tab(0), .group(g), .tab(1), .tab(2), .tab(3), .group(h), .tab(4), .newTab])
    }

    @Test("A folded group hides its tabs but keeps the current tab, so the user sees where they are")
    func foldedKeepsSelected() {
        let hidden = TabGrouping.items(groupIDs: [g, g, g, nil], folded: [g], selectedIndex: 3)
        #expect(hidden == [.group(g), .tab(3), .newTab])
        let current = TabGrouping.items(groupIDs: [g, g, g, nil], folded: [g], selectedIndex: 1)
        #expect(current == [.group(g), .tab(1), .tab(3), .newTab])
    }

    @Test("A drop between tabs of a group, or just below its header, joins that group")
    func dropInside() {
        let ids: [UUID?] = [nil, g, g, nil]
        let items = TabGrouping.items(groupIDs: ids, folded: [], selectedIndex: nil)
        // Rows: tab0, header g, tab1, tab2, tab3, new tab.
        #expect(TabGrouping.dropTarget(items: items, groupIDs: ids, row: 2, on: false) == (1, g))
        #expect(TabGrouping.dropTarget(items: items, groupIDs: ids, row: 3, on: false) == (2, g))
    }

    @Test("A drop above a header or below the last tab of a group stays outside the group")
    func dropOutside() {
        let ids: [UUID?] = [nil, g, g, nil]
        let items = TabGrouping.items(groupIDs: ids, folded: [], selectedIndex: nil)
        #expect(TabGrouping.dropTarget(items: items, groupIDs: ids, row: 1, on: false) == (1, nil))
        #expect(TabGrouping.dropTarget(items: items, groupIDs: ids, row: 4, on: false) == (3, nil))
        #expect(TabGrouping.dropTarget(items: items, groupIDs: ids, row: 5, on: false) == (4, nil))
    }

    @Test("A drop on a folded header adds the tab after the hidden tabs, at the end of the group")
    func dropOnFoldedHeader() {
        let ids: [UUID?] = [g, g, g, nil]
        let items = TabGrouping.items(groupIDs: ids, folded: [g], selectedIndex: 3)
        #expect(TabGrouping.dropTarget(items: items, groupIDs: ids, row: 0, on: true) == (3, g))
        // Below a folded header, the next row is outside the group, after all its hidden tabs.
        #expect(TabGrouping.dropTarget(items: items, groupIDs: ids, row: 1, on: false) == (3, nil))
    }

    @Test("A tab put between two tabs of one group joins it, so the group never splits")
    func insertionJoinsSurroundingGroup() {
        #expect(TabGrouping.groupForInsertion(at: 1, groupIDs: [g, g]) == g)
        #expect(TabGrouping.groupForInsertion(at: 1, groupIDs: [g, h]) == nil)
        #expect(TabGrouping.groupForInsertion(at: 0, groupIDs: [g, g]) == nil)
        #expect(TabGrouping.groupForInsertion(at: 2, groupIDs: [g, g]) == nil)
    }

    @Test("A tab next to its own group goes back into it (reopened tab, link from a grouped tab)")
    func insertionPrefersOwnGroup() {
        #expect(TabGrouping.groupForInsertion(at: 2, groupIDs: [g, g, nil], preferred: g) == g)
        #expect(TabGrouping.groupForInsertion(at: 0, groupIDs: [g, g], preferred: g) == g)
        // Not next to its group: it must not join, or the group would split.
        #expect(TabGrouping.groupForInsertion(at: 3, groupIDs: [g, g, nil], preferred: g) == nil)
    }

    @Test("A dragged group goes exactly where it was dropped, between groups or loose tabs")
    func groupMoves() {
        // Tabs: a, g, g, b, h, h. Group g is at 1...2.
        let ids: [UUID?] = [nil, g, g, nil, h, h]
        #expect(TabGrouping.groupDestination(of: 1...2, proposed: 0, groupIDs: ids) == 0)
        #expect(TabGrouping.groupDestination(of: 1...2, proposed: 4, groupIDs: ids) == 2)   // above h
        #expect(TabGrouping.groupDestination(of: 1...2, proposed: 6, groupIDs: ids) == 4)   // the end
    }

    @Test("A group dropped inside another group goes below it, so the other group does not split")
    func groupDropInsideOtherGroup() {
        let ids: [UUID?] = [nil, g, g, nil, h, h]
        // Between the two tabs of h: after h, the end of the list without g.
        #expect(TabGrouping.groupDestination(of: 1...2, proposed: 5, groupIDs: ids) == 4)
    }

    @Test("A group dropped on its own tabs stays where it is")
    func groupDropOnItself() {
        let ids: [UUID?] = [nil, g, g, nil]
        #expect(TabGrouping.groupDestination(of: 1...2, proposed: 1, groupIDs: ids) == 1)
        #expect(TabGrouping.groupDestination(of: 1...2, proposed: 2, groupIDs: ids) == 1)
        #expect(TabGrouping.groupDestination(of: 1...2, proposed: 3, groupIDs: ids) == 1)
    }

    @Test("New group tabs taken from inside a group go below that group, so it does not split")
    func blockInsideGroup() {
        #expect(TabGrouping.blockInsertionIndex(at: 1, groupIDs: [g, g, nil]) == 2)
        #expect(TabGrouping.blockInsertionIndex(at: 0, groupIDs: [g, g, nil]) == 0)
        #expect(TabGrouping.blockInsertionIndex(at: 2, groupIDs: [g, g, nil]) == 2)
    }

    @Test("A new group gets a color no other group has, so groups look different")
    func unusedColor() {
        #expect(TabGroupColor.firstUnused(in: []) == .grey)
        #expect(TabGroupColor.firstUnused(in: [.grey, .red]) == .blue)
        #expect(TabGroupColor.firstUnused(in: TabGroupColor.allCases) == .grey)
    }
}

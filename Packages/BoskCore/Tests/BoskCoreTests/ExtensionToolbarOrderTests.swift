import Testing
@testable import BoskCore

/// Users choose which extension buttons show and drag them into their order.
/// A wrong order or a lost pin moves buttons that the user put in place.
struct ExtensionToolbarOrderTests {
    @Test("A new install shows at the end of the bar, so the user can find it")
    func newInstallIsPinnedAtEnd() {
        let visible = ExtensionToolbarOrder.visible(ids: ["new", "A", "B"], order: ["B", "A"], unpinned: [])
        #expect(visible == ["B", "A", "new"])
    }

    @Test("An unpinned extension does not show in the bar")
    func unpinnedIsHidden() {
        let visible = ExtensionToolbarOrder.visible(ids: ["A", "B", "C"], order: ["A", "B", "C"], unpinned: ["B"])
        #expect(visible == ["A", "C"])
    }

    @Test("A removed extension in the saved order does not show")
    func removedIsIgnored() {
        let visible = ExtensionToolbarOrder.visible(ids: ["A", "C"], order: ["C", "gone", "A"], unpinned: [])
        #expect(visible == ["C", "A"])
    }

    @Test("After a drag, the bar keeps the dragged order, also with hidden extensions in the saved order")
    func dragKeepsOrder() {
        let order = ExtensionToolbarOrder.saved(visible: ["C", "A"], order: ["A", "hidden", "C"])
        #expect(order == ["C", "A", "hidden"])
        let visible = ExtensionToolbarOrder.visible(ids: ["A", "hidden", "C"], order: order, unpinned: ["hidden"])
        #expect(visible == ["C", "A"])
    }

    @Test("A pinned extension goes at the end of the bar, not back to its old place")
    func pinGoesToEnd() {
        let order = ExtensionToolbarOrder.pinned("hidden", visible: ["A", "C"], order: ["hidden", "A", "C"])
        let visible = ExtensionToolbarOrder.visible(ids: ["A", "hidden", "C"], order: order, unpinned: [])
        #expect(visible == ["A", "C", "hidden"])
    }
}

import Foundation

/// Which extension buttons show in the top bar, and in which order.
/// The user's order holds extension IDs. An extension that is not in it yet (a new install)
/// goes at the end, pinned, so the user sees it.
public enum ExtensionToolbarOrder {
    /// The pinned extensions in the user's order. `ids` is the load order of the extensions.
    public static func visible(ids: [String], order: [String], unpinned: Set<String>) -> [String] {
        let known = ids.filter(order.contains).sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }
        return (known + ids.filter { !order.contains($0) }).filter { !unpinned.contains($0) }
    }

    /// The order to save after the user dragged the pinned buttons into `visible`.
    /// Unpinned extensions keep their places relative to each other, after the pinned ones.
    public static func saved(visible: [String], order: [String]) -> [String] {
        visible + order.filter { !visible.contains($0) }
    }

    /// The order to save after the user pinned `id`: the button goes at the end of the bar.
    public static func pinned(_ id: String, visible: [String], order: [String]) -> [String] {
        saved(visible: visible.filter { $0 != id } + [id], order: order)
    }
}

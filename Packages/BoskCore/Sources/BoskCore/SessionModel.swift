import Foundation

/// Everything Bosk saves between launches: windows, tabs and pinned entries.
/// New fields must be optional, so a session saved by an older version still loads.
public struct Session: Codable, Equatable, Sendable {
    public var windows: [WindowState]
    public var pinned: [PinnedEntry]

    public init(windows: [WindowState] = [], pinned: [PinnedEntry] = []) {
        self.windows = windows
        self.pinned = pinned
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Session {
        try JSONDecoder().decode(Session.self, from: data)
    }
}

public struct WindowState: Codable, Equatable, Sendable {
    /// x, y, width, height in screen points.
    public var frame: [Double]?
    /// Pinned tabs of this window. Each one points to a `PinnedEntry` by `pinnedEntryID`.
    public var pinnedTabs: [TabState]
    public var tabs: [TabState]
    public var selectedTabID: UUID?
    public var sidebarFolded: Bool?

    public init(frame: [Double]? = nil, pinnedTabs: [TabState] = [], tabs: [TabState] = [],
                selectedTabID: UUID? = nil, sidebarFolded: Bool? = nil) {
        self.frame = frame
        self.pinnedTabs = pinnedTabs
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.sidebarFolded = sidebarFolded
    }
}

public struct TabState: Codable, Equatable, Sendable {
    public var id: UUID
    public var url: URL?
    public var title: String
    /// WebKit's opaque `interactionState` (back/forward list, scroll position).
    public var sessionState: Data?
    public var pinnedEntryID: UUID?

    public init(id: UUID, url: URL?, title: String, sessionState: Data? = nil, pinnedEntryID: UUID? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.sessionState = sessionState
        self.pinnedEntryID = pinnedEntryID
    }
}

/// A pinned site. It is the same in every window.
public struct PinnedEntry: Codable, Equatable, Sendable {
    public var id: UUID
    /// The page the pinned tab goes back to.
    public var url: URL
    public var title: String

    public init(id: UUID = UUID(), url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }
}

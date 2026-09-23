import Foundation

/// Decides which tabs go to sleep. A sleeping tab has no web process, so it uses almost
/// no memory, but it reloads when the user comes back to it.
public enum SleepPolicy {
    public struct TabInfo: Sendable {
        public var id: UUID
        public var lastActive: Date
        /// The tab on screen in its window.
        public var isSelected: Bool
        public var isAsleep: Bool
        public var isPlayingMedia: Bool
        /// Camera or microphone in use (a call).
        public var isCapturing: Bool
        /// Text typed in a form and not sent yet.
        public var hasUnsentInput: Bool

        public init(id: UUID, lastActive: Date, isSelected: Bool = false, isAsleep: Bool = false,
                    isPlayingMedia: Bool = false, isCapturing: Bool = false, hasUnsentInput: Bool = false) {
            self.id = id
            self.lastActive = lastActive
            self.isSelected = isSelected
            self.isAsleep = isAsleep
            self.isPlayingMedia = isPlayingMedia
            self.isCapturing = isCapturing
            self.hasUnsentInput = hasUnsentInput
        }
    }

    public enum MemoryPressure: Sendable {
        case normal, warning, critical
    }

    /// - Parameters:
    ///   - idleLimit: Normal sleep time (60 minutes in Bosk).
    ///   - pressureIdleLimit: Sleep time when macOS reports memory pressure.
    /// - Returns: Tab IDs to sleep, oldest first.
    public static func tabsToSleep(_ tabs: [TabInfo], now: Date, idleLimit: TimeInterval,
                                   pressureIdleLimit: TimeInterval, pressure: MemoryPressure) -> [UUID] {
        let limit: TimeInterval = switch pressure {
        case .normal: idleLimit
        case .warning: pressureIdleLimit
        case .critical: 0
        }
        return tabs
            .filter { canSleep($0) && now.timeIntervalSince($0.lastActive) >= limit }
            .sorted { $0.lastActive < $1.lastActive }
            .map(\.id)
    }

    /// Tabs that must stay awake, whatever the memory pressure:
    /// sleep would reload the page and lose what the user is doing.
    static func canSleep(_ tab: TabInfo) -> Bool {
        !tab.isAsleep && !tab.isSelected && !tab.isPlayingMedia && !tab.isCapturing && !tab.hasUnsentInput
    }
}

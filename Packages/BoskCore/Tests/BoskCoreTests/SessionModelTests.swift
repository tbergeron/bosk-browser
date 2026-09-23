import Foundation
import Testing
@testable import BoskCore

/// The session file holds all of the user's open tabs. If it does not load,
/// the user loses every tab, so these tests guard the file format.
struct SessionModelTests {
    @Test("A saved session loads back the same, so no tab is lost on relaunch")
    func roundTrip() throws {
        let pin = PinnedEntry(url: URL(string: "https://mail.google.com")!, title: "Gmail")
        let session = Session(
            windows: [WindowState(
                frame: [10, 20, 1280, 820],
                pinnedTabs: [TabState(id: UUID(), url: pin.url, title: "Inbox", pinnedEntryID: pin.id)],
                tabs: [TabState(id: UUID(), url: URL(string: "https://x.com")!, title: "X",
                                sessionState: Data([1, 2, 3]))],
                selectedTabID: nil,
                sidebarFolded: true
            )],
            pinned: [pin]
        )
        #expect(try Session.decode(session.encoded()) == session)
    }

    @Test("A file from an older version without the newer optional fields still loads")
    func olderFileLoads() throws {
        let id = UUID()
        let json = """
        {"pinned":[],"windows":[{"pinnedTabs":[],"tabs":[{"id":"\(id.uuidString)","title":"A","url":"https://a.com"}]}]}
        """
        let session = try Session.decode(Data(json.utf8))
        #expect(session.windows.first?.tabs.first?.id == id)
        #expect(session.windows.first?.sidebarFolded == nil)
        #expect(session.windows.first?.frame == nil)
    }
}

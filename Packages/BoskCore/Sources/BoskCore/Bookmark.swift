import Foundation

/// A saved page. Bookmarks are one flat list, in the order the user added them.
public struct Bookmark: Codable, Equatable, Sendable {
    public var id: UUID
    public var url: URL
    public var title: String

    public init(id: UUID = UUID(), url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }
}

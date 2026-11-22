import Darwin
import Foundation

/// The messages between Bosk and a saved web app (a small helper app made by Save as App).
/// The page lives in Bosk; the helper owns the window, Dock icon, menu bar and notifications,
/// shows Bosk's drawing of the page, and sends the user's input back.
public enum WebAppMessage: Codable, Equatable, Sendable {
    // Helper to Bosk
    /// The first message. `frame` is the window's content area on screen, in points (AppKit, bottom-left origin).
    case hello(url: String, appID: String, frame: WebAppRect)
    case frame(WebAppRect)
    /// The helper app became the active app (true) or stopped being it (false).
    case active(Bool)
    case mouse(WebAppMouse)
    case scroll(WebAppScroll)
    case key(WebAppKey)
    /// Text from the Mac text input system (accents, other alphabets). `insert` false is marked
    /// (not finished) text, with its selection.
    case text(insert: Bool, text: String, selection: Int, length: Int)
    /// A menu command: copy, cut, paste, selectAll, undo, redo, reload, back, forward, zoomIn, zoomOut, actualSize.
    case command(String)
    case dialogReply(WebAppDialogReply)
    case notificationClicked(String)

    // Bosk to helper
    /// The CoreAnimation context with the page's drawing.
    case context(UInt32)
    case title(String)
    /// An NSCursor name: arrow, iBeam, pointingHand, and others.
    case cursor(String)
    case dialog(WebAppDialog)
    case notify(identifier: String, title: String, subtitle: String, body: String)
    case removeNotification(String)
    /// The page closed itself (window.close()).
    case close
    /// The page opened a tab in a Bosk window: bring Bosk to the front. Only the active app
    /// (the helper) can make another app active.
    case showBosk
}

public struct WebAppRect: Codable, Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Positions are in the content area, in points, with the origin at the bottom left (AppKit).
public struct WebAppMouse: Codable, Equatable, Sendable {
    public var type: UInt, x: Double, y: Double, flags: UInt, clicks: Int
    public init(type: UInt, x: Double, y: Double, flags: UInt, clicks: Int) {
        self.type = type; self.x = x; self.y = y; self.flags = flags; self.clicks = clicks
    }
}

/// `phase` and `momentum` are NSEvent.Phase raw values.
public struct WebAppScroll: Codable, Equatable, Sendable {
    public var x: Double, y: Double, dx: Double, dy: Double, precise: Bool, phase: UInt, momentum: UInt, flags: UInt
    public init(x: Double, y: Double, dx: Double, dy: Double, precise: Bool, phase: UInt, momentum: UInt, flags: UInt) {
        self.x = x; self.y = y; self.dx = dx; self.dy = dy; self.precise = precise
        self.phase = phase; self.momentum = momentum; self.flags = flags
    }
}

public struct WebAppKey: Codable, Equatable, Sendable {
    public var type: UInt, characters: String, charactersIgnoringModifiers: String, keyCode: UInt16, flags: UInt, isRepeat: Bool
    public init(type: UInt, characters: String, charactersIgnoringModifiers: String, keyCode: UInt16, flags: UInt,
                isRepeat: Bool) {
        self.type = type; self.characters = characters; self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.keyCode = keyCode; self.flags = flags; self.isRepeat = isRepeat
    }
}

/// A page dialog, shown by the helper as a sheet on its window.
public struct WebAppDialog: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case alert, confirm, prompt, signIn, openFiles }
    public var id: Int, kind: Kind, message: String, host: String?, defaultText: String?
    public var confirmTitle: String?, cancelTitle: String?
    public var allowsMultiple: Bool, allowsDirectories: Bool
    public init(id: Int, kind: Kind, message: String, host: String? = nil, defaultText: String? = nil,
                confirmTitle: String? = nil, cancelTitle: String? = nil, allowsMultiple: Bool = false,
                allowsDirectories: Bool = false) {
        self.id = id; self.kind = kind; self.message = message; self.host = host; self.defaultText = defaultText
        self.confirmTitle = confirmTitle; self.cancelTitle = cancelTitle
        self.allowsMultiple = allowsMultiple; self.allowsDirectories = allowsDirectories
    }
}

public struct WebAppDialogReply: Codable, Equatable, Sendable {
    public var id: Int, ok: Bool, text: String?, password: String?, paths: [String]?
    public init(id: Int, ok: Bool, text: String? = nil, password: String? = nil, paths: [String]? = nil) {
        self.id = id; self.ok = ok; self.text = text; self.password = password; self.paths = paths
    }
}

/// One JSON message on each line. A socket read can end in the middle of a message,
/// so the bytes after the last newline wait for the next read.
public struct WebAppFraming {
    private var buffer = Data()
    public init() {}

    public static func encode(_ message: WebAppMessage) -> Data {
        // JSON never has a raw newline in it: newlines in strings are escaped.
        ((try? JSONEncoder().encode(message)) ?? Data()) + Data([0x0A])
    }

    /// The complete messages in the bytes so far. A line that does not decode is skipped.
    public mutating func append(_ data: Data) -> [WebAppMessage] {
        buffer.append(data)
        var messages: [WebAppMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let message = try? JSONDecoder().decode(WebAppMessage.self, from: line) { messages.append(message) }
        }
        return messages
    }
}

/// A Unix socket connection that sends and receives `WebAppMessage`s.
/// Messages and the close arrive on the main queue.
public final class WebAppConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "Bosk.WebAppConnection")
    private var source: DispatchSourceRead?
    private var framing = WebAppFraming()
    private var isClosed = false
    public var onMessage: (@MainActor (WebAppMessage) -> Void)?
    public var onClose: (@MainActor () -> Void)?

    init(fd: Int32) {
        self.fd = fd
        // A write to a closed socket must fail, not stop the app with SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Nil when no app listens at `path`.
    public static func connect(path: String) -> WebAppConnection? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = socketAddress(path) else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return WebAppConnection(fd: fd)
    }

    public func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.read() }
        self.source = source
        source.resume()
    }

    private func read() {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0 else { return close() }
        let messages = framing.append(Data(bytes[0..<count]))
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                for message in messages { self?.onMessage?(message) }
            }
        }
    }

    /// Small messages: a blocking write is short.
    public func send(_ message: WebAppMessage) {
        let data = WebAppFraming.encode(message)
        queue.async { [fd] in
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 { return }
                    offset += written
                }
            }
        }
    }

    public func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            source?.cancel()
            Darwin.close(fd)
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onClose?() } }
        }
    }

    static func socketAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}

/// Bosk's end: accepts the helpers' connections. Only the user can connect (the socket file is 0600).
public final class WebAppListener: @unchecked Sendable {
    private let fd: Int32
    private let source: DispatchSourceRead
    public var onConnection: (@MainActor (WebAppConnection) -> Void)?

    /// Nil when the socket cannot be made (for example, the path is too long).
    public init?(path: String) {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = WebAppConnection.socketAddress(path) else { return nil }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let client = accept(self.fd, nil, nil)
            guard client >= 0 else { return }
            let connection = WebAppConnection(fd: client)
            MainActor.assumeIsolated { self.onConnection?(connection) }
        }
        source.resume()
    }
}

import Foundation
import Testing
@testable import BoskCore

/// A saved web app shows a page that lives in Bosk, so every click, key and dialog answer
/// goes over this link. A lost or broken message is a lost click or a lost typed letter.
struct WebAppLinkTests {
    @Test("A message cut across two socket reads still arrives, once")
    func messageAcrossReads() {
        let message = WebAppMessage.key(WebAppKey(type: 10, characters: "é", charactersIgnoringModifiers: "e",
                                                  keyCode: 14, flags: 0, isRepeat: false))
        let data = WebAppFraming.encode(message)
        var framing = WebAppFraming()
        let cut = data.count / 2
        #expect(framing.append(data.prefix(cut)).isEmpty)
        #expect(framing.append(data.suffix(from: cut)) == [message])
    }

    @Test("Many messages in one read arrive in order: a click before the typed text")
    func manyMessagesInOrder() {
        let messages: [WebAppMessage] = [
            .mouse(WebAppMouse(type: 1, x: 10, y: 20, flags: 0, clicks: 1)),
            .text(insert: true, text: "line one\nline two", selection: 0, length: 0),
            .command("paste"),
        ]
        var framing = WebAppFraming()
        #expect(framing.append(messages.map(WebAppFraming.encode).reduce(Data(), +)) == messages)
    }

    @Test("A broken line is skipped and the next message still arrives")
    func brokenLineIsSkipped() {
        var framing = WebAppFraming()
        let data = Data("not json\n".utf8) + WebAppFraming.encode(.title("Inbox"))
        #expect(framing.append(data) == [.title("Inbox")])
    }

    @Test("Bosk and a helper exchange messages over the socket, in both directions")
    func roundTripOverSocket() async throws {
        let path = "/tmp/bosk-webapp-test-\(getpid()).sock"
        defer { unlink(path) }
        let listener = try #require(WebAppListener(path: path))
        let received = await withCheckedContinuation { (done: CheckedContinuation<[WebAppMessage], Never>) in
            Task { @MainActor in
                var server: WebAppConnection?
                var log: [WebAppMessage] = []
                listener.onConnection = { connection in
                    server = connection
                    connection.onMessage = { message in
                        log.append(message)
                        connection.send(.context(42))
                    }
                    connection.start()
                }
                guard let client = WebAppConnection.connect(path: path) else { return done.resume(returning: []) }
                // The closure keeps both ends alive until the reply comes.
                client.onMessage = { message in
                    log.append(message)
                    _ = (server, client)
                    done.resume(returning: log)
                }
                client.start()
                client.send(.hello(url: "https://example.com", appID: "a1",
                                   frame: WebAppRect(x: 0, y: 0, width: 800, height: 600)))
            }
        }
        #expect(received == [.hello(url: "https://example.com", appID: "a1",
                                    frame: WebAppRect(x: 0, y: 0, width: 800, height: 600)), .context(42)])
    }
}

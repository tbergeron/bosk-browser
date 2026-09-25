# Chrome extension compatibility

Bosk runs Chrome extensions with WebKit's `WKWebExtension` (macOS 15.4+). WebKit implements
most of the WebExtensions API, but not all of Chrome's. This file records what was tested.

Tested on 2026-09-23, macOS 27.0, Debug build. Installs came from the Chrome Web Store
through "Add to Bosk" (the Debug option `-BoskInstallWebStoreIDs` does the same without clicks).

## Results

| Extension | Version | Installs | Works | Notes |
|---|---|---|---|---|
| uBlock Origin Lite | 2026.920.1710 | Yes | **Yes** | Blocks `adsbygoogle.js` on `/ads` (scripts/test-pages.py). Popup opens. Blocking starts after WebKit compiles the rules: about 20 s after install, and again in the background at each launch. |
| Dark Reader | 4.9.132 | Yes | **Partly** | Pages turn dark (tested on Wikipedia). Sometimes its background stops answering (seen 2026-09-24, cause not known). Then the popup stays at "Loading, please wait", and each page keeps the early dark style from `inject/fallback.js`, also on sites where Dark Reader is off. Turning it off and on in Settings, then reloading the pages, fixes it for now. |
| Return YouTube Dislike | 4.0.5 | Yes | Loads without errors | Not tested on YouTube. |
| Vimium | 2.4.2 | Yes | **Partly** | Background script fails: WebKit has no `chrome.webNavigation.onHistoryStateUpdated`. Commands that need the background do not work. Key handling in the page: not tested (needs a person). |
| Bitwarden (Chrome Web Store) | 2026.8.0 | Yes | **Yes** | Log in with 2FA, vault list and "Sync now" work (2026-09-25, tested by the user in the Debug build). Autofill: not tested. Its worker often ends about 4 s after a logged-in start (cause not known); Bosk sees it on the worker's port and loads the extension again within 25 s, so the popup can show a spinner in the first half minute. |
| Bitwarden (Safari build, loaded unpacked) | 2026.8.0 | Yes | **Partly** | Load `/Applications/Bitwarden.app/Contents/PlugIns/safari.appex/Contents/Resources` (needs the Bitwarden Mac app). It runs as a background page, so its WebSocket works. Popup opens to the start screen (Debug build, 2026-09-24). With a Chrome user agent its popup was blank, so extension pages use the Safari user agent. Copy from the popup and Touch ID unlock need native messaging: not tested. Log in and autofill: not tested by Claude (they need an account). |
| 1Password | 8.12.37.1 | Yes | **No** | Background fails: WebKit has no `chrome.notifications`. As expected: 1Password also needs native messaging to its app. |
| Bosk Test Extension (scripts/test-extension) | 1.0 | Yes | **Yes** | Content script on all pages (also in a tab woken from sleep), background worker, badge, popup with `chrome.tabs.query`. |

## Memory cost

Each extension has a background page or worker in its own WebKit process, and some of its
data is in the Bosk app process. Measured with one extension enabled at a time, 15 s after launch,
one sleeping tab (the "none" row is the baseline):

| Enabled | Bosk app process | App + all WebKit processes |
|---|---|---|
| None | 27 MB | 53 MB |
| Bosk Test Extension | 32 MB | 103 MB |
| uBlock Origin Lite | 47 MB | 116 MB |
| Dark Reader | 34 MB | 146 MB |
| Vimium | 32 MB | 73 MB |
| Bitwarden | 33 MB | 119 MB |
| 1Password | 34 MB | 101 MB |
| Return YouTube Dislike | 108 MB | 149 MB |

With all seven enabled at the same time, the app process was 577 MB. That is much more than
the sum of the rows above, and the cause is not known yet. **To keep Bosk light, install few
extensions.** A per-extension memory display in Settings would help users choose.

## Known WebKit gaps (from the SDK and WebKit source)

- `webRequest` can observe but not block. Blocking extensions must use `declarativeNetRequest`
  (uBlock Origin Lite does).
- `sidePanel` and `bookmarks` are compiled out of WebKit.
- `notifications` is not available in this build (1Password fails on it).
- `webNavigation.onHistoryStateUpdated` is missing (Vimium fails on it).
- Native messaging goes through the app's delegate. Bosk runs the Chrome native messaging hosts
  that apps register in Chrome's `NativeMessagingHosts` folders, for the extension IDs that each
  host allows. Other messages fail, slowly after a dozen tries in a second (Bitwarden's
  message loop spins on a quick error).
- Extension web views get the tabs' Safari user agent. When a page loads with another user agent,
  WebKit stops the extension workers and does not start them again, so Bosk never changes it
  (the Web Store's Chrome user agent is set by a page script). The shim tells extension pages
  and workers that they run in Chrome, in `navigator.userAgent`.
- A WebSocket opened in an extension service worker deadlocks its process. WebKit runs the worker
  on the process's main thread, and `new WebSocket` waits for the main thread
  (`WorkerThreadableWebSocketChannel`, found with a CPU sample). A background page does not have
  this problem. The shim works around it (see below).
- WebKit unloads a non-persistent worker 30 s after the last event it sent to it, and an open
  popup does not count (`WebExtensionContext::scheduleBackgroundContentToUnload`). A worker
  that WebKit starts again can run in a different process than the extension's open pages, and
  then they cannot reach each other (WebKit fixed this on main in
  `SWServer::replaceContextConnectionIfNotInServiceWorkerPageProcess`; macOS 27.2 does not have
  it). Bosk keeps every worker loaded instead (see below).
- A worker can stop while WebKit still counts it as loaded. Then WebKit sends each event to a
  worker that is not there: a popup's port is disconnected at once, and
  `loadBackgroundContent` says it is done. Seen after an extension is unloaded and loaded again
  at the same origin (a reinstall with `-BoskInstallWebStoreIDs`, or `ExtensionManager.revive`):
  about 3.5 s after the new worker started, WebKit cleared its registration
  (`SWServerRegistration::clear` in the network process) and ended it. The cause is not known.
  **Test worker lifetimes in a launch without a reinstall.** The shim's restart (below) is the
  only way out of this state.
- `persistent: true` is refused in manifest version 3 (`WebExtension.cpp`), so a background
  page cannot be made persistent for a Chrome extension.

## The shim (ported from Search)

Bosk adds `bosk-shim.js` to each extension, at install and at each load: first in the
background, in each content script and in each HTML page (`ExtensionShim.swift` in BoskCore).
It is ported from [Search](https://github.com/driceroland/Search) by Office Commun (MIT
License). The script defines the Chrome APIs that WebKit does not have (bookmarks, history,
downloads, offscreen, notifications, fontSettings, idle, privacy and more). It sends each call as
a native message to "bosk", and `ExtensionShimAnswers.swift` answers from Bosk's own data.
It also:

- Makes a service worker's WebSocket in the app, with URLSession, over a native port
  (`ExtensionSocket.swift`). Tested on 2026-09-25 with a test worker and a local echo server:
  the socket opened, sent and received, and the worker did not freeze.
- Pings the worker before a page's message. With no answer, Bosk asks WebKit to load the
  background again (3 tries), then unloads and loads the extension (at most once a minute).
  The restart is done only while one of the extension's pages is on screen (its popup, or a
  tab at its address): a popup that is closing gets no answer either, and its report once
  ended a worker that ran. Bosk also restarts an extension when WebKit reports that a worker
  failed to load.
- The worker holds a native port "bosk.alive" to Bosk. Bosk pings it every 15 s; no answer by
  the next ping, or the port gone while the extension stays loaded, and Bosk loads the
  extension again. This catches a worker that WebKit ended but still counts as loaded, with
  no popup open.
- Gives an extension page its own storage changes: after a `set`, `remove` or `clear`, the
  page's own `storage.onChanged` listeners get the change (Bitwarden's state layer waits for
  it). A copy that WebKit delivers itself within a moment is dropped.
- Does NOT do one thing Search does: hand the popup page a `chrome` of its own (built on
  WebKit's) to answer `extension.getViews`. WebKit finds a page's listeners through the global
  `chrome` and `browser`; with that replacement no message, port message or storage change
  from any other context reached the popup. That was the cause of Bitwarden's failed login
  ("Invalid verification code" one second after the server said yes), of "Syncing failed",
  and of Dark Reader's popup staying at "Loading". Found by cutting the shim in half in a test
  extension until the popup heard its worker again.
- Bosk itself keeps every worker loaded: `ExtensionManager` calls `loadBackgroundContent` for
  each loaded extension every 15 s, which starts WebKit's 30 s unload timer again. So a worker
  behaves as a persistent background page, and the popup always finds the worker it started
  with. Cost: the worker's process stays (see "Memory cost").

Not ported: Search's passkey patch (it needs the passkey entitlement), and Search's
`chrome-extension://` page addresses (existing extension pages would lose their storage).
Bosk's bookmarks have no folders, and tab indexes are in the focused window only.

## Things Bosk does to keep extensions fast

- A ZIP or CRX is unpacked one time at install. WebKit unpacks a ZIP on every load, on the
  main thread (about 1 s for uBlock Origin Lite).
- Extensions load after the first window frame, so they do not slow the launch
  (launch with 2 extensions: 5.5 s before this change, 0.4–0.6 s after).

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
| Bitwarden (Chrome Web Store) | 2026.8.0 | Yes | **No** | Freezes after log in (2026-09-24). It opens a WebSocket from its service worker, and WebKit deadlocks there (see the gaps below). The popup, the icon and the Web Inspector console then stop working. Use the Safari build. |
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
- WebKit sometimes does not start a worker again after it unloads it. Then every message to the
  worker waits forever. The shim works around it (see below).

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
  Bosk also does this when WebKit reports that a worker failed to load.

Not ported: Search's passkey patch (it needs the passkey entitlement), and Search's
`chrome-extension://` page addresses (existing extension pages would lose their storage).
Bosk's bookmarks have no folders, and tab indexes are in the focused window only.

## Things Bosk does to keep extensions fast

- A ZIP or CRX is unpacked one time at install. WebKit unpacks a ZIP on every load, on the
  main thread (about 1 s for uBlock Origin Lite).
- Extensions load after the first window frame, so they do not slow the launch
  (launch with 2 extensions: 5.5 s before this change, 0.4–0.6 s after).

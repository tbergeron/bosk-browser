# Chrome extension compatibility

Bosk runs Chrome extensions with WebKit's `WKWebExtension` (macOS 15.4+). WebKit implements
most of the WebExtensions API, but not all of Chrome's. This file records what was tested.

Tested on 2026-09-23, macOS 27.0, Debug build. Installs came from the Chrome Web Store
through "Add to Bosk" (the Debug option `-BoskInstallWebStoreIDs` does the same without clicks).

## Results

| Extension | Version | Installs | Works | Notes |
|---|---|---|---|---|
| uBlock Origin Lite | 2026.920.1710 | Yes | **Yes** | Blocks `adsbygoogle.js` on `/ads` (scripts/test-pages.py). Popup opens. Blocking starts after WebKit compiles the rules: about 20 s after install, and again in the background at each launch. |
| Dark Reader | 4.9.132 | Yes | **Yes** | Pages turn dark (tested on Wikipedia). |
| Return YouTube Dislike | 4.0.5 | Yes | Loads without errors | Not tested on YouTube. |
| Vimium | 2.4.2 | Yes | **Partly** | Background script fails: WebKit has no `chrome.webNavigation.onHistoryStateUpdated`. Commands that need the background do not work. Key handling in the page: not tested (needs a person). |
| Bitwarden | 2026.8.0 | Yes | **No** | Background fails: `this.device.toString` (Bitwarden does not recognize the browser). Popup and autofill not tested: autofill needs an account. |
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
- Native messaging goes through the app's delegate; Bosk does not implement it, so password
  managers that talk to a desktop app (1Password) cannot work.
- Extensions that check for "Chrome" or "Safari" by user agent or by API shape may fail
  (Bitwarden).

## Things Bosk does to keep extensions fast

- A ZIP or CRX is unpacked one time at install. WebKit unpacks a ZIP on every load, on the
  main thread (about 1 s for uBlock Origin Lite).
- Extensions load after the first window frame, so they do not slow the launch
  (launch with 2 extensions: 5.5 s before this change, 0.4–0.6 s after).

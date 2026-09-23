# Manual checklist

Some behavior needs a person: system privacy prompts, real accounts, and file pickers.
Run these checks before a release. Start the local test pages first:

```bash
python3 scripts/test-pages.py
```

Then open http://localhost:8765 in Bosk.

"Verified" shows what was already checked during development (2026-09-23), and how.

## Page behavior (M5)

| Check | Expected | Verified |
|---|---|---|
| /dialogs: alert, confirm, prompt | Each opens as a sheet on the window, with the site name. Confirm returns true/false. | alert and confirm: yes (automated UI test) |
| /popups: target=_blank link | Opens a new tab below the page, selected | Yes |
| /popups: window.open, then close | The new tab closes itself; Bosk goes back to the page that opened it | Close: yes. Return to opener: fixed after the test, check again |
| /download | Saves bosk-test.txt to ~/Downloads (then "bosk-test 2.txt" …). The first download shows a macOS prompt for the Downloads folder. A tab that opened only for the download closes itself. | File saved and unique names: yes. **The macOS prompt blocks Bosk until it is answered** (WebKit asks for the folder on the main thread). |
| /auth | A sign-in sheet opens. User "bosk", password "bosk" shows "Signed in". Cancel shows "Sign-in needed". | Cancel: yes. Sign in: **not tested** (no password typed during development) |
| /upload | The file panel opens as a sheet; "Send" shows the byte count | Not tested |
| /form | Type text, do not send, go to another tab: the tab stays awake past the sleep time | Yes (`-BoskSleepAfterSeconds 15`) |
| /media | Bosk asks "Allow localhost to use your camera and microphone?"; macOS may also ask the first time; video shows | Not tested. (The permission method had a wrong signature and was never called; fixed after the M5 tests.) |
| A page that does not exist | Bosk's error page with "Try Again". It is not saved in history. | Yes |
| http://example.com (no HTTPS) | Loads (App Transport Security allows web content) | Yes |
| Google sign-in (accounts.google.com) | Sign-in works; Google does not say "browser not supported" | Not tested |
| A pop-up OAuth flow (for example "Sign in with GitHub" on a site) | The pop-up opens as a tab, and after sign-in the site continues | Not tested |
| Video call (for example meet.google.com) | Camera and mic work; the tab does not sleep during the call | Not tested |
| Full-screen YouTube video | Full screen enters and exits | Not tested |
| Cmd+F on a long page | Find bar; Return and Shift+Return go to the next and previous match; Esc closes | Not tested by a person |
| Cmd+P | Print panel with the page | Not tested |
| Cmd-click a link | Opens in a background tab below the current tab | Not tested |
| Command bar: type a few letters of a visited site | The first row is that site ("Switch to Tab" if it is open) | Yes ("git" → GitHub, Switch to Tab) |
| Command bar: type an address and press Return | The page opens | **Not tested with a real key press** (background test tools cannot press Return) |

## Extensions (M6)

| Check | Expected | Verified |
|---|---|---|
| Chrome Web Store page of an extension | "Add to Bosk" in the top bar; the prompt lists the access; the extension button appears | Yes (uBlock Origin Lite and 5 others) |
| uBlock Origin Lite on /ads | "blocked" (about 20 s after install, while WebKit compiles the rules) | Yes |
| An extension's popup | Opens under its button | Yes (test extension, uBlock Origin Lite) |
| A tab that wakes from sleep | Content scripts run in it | Yes (test extension banner) |
| Vimium: press `f` on a page | Link hints | **Not tested** (background tools cannot send keys to a page); the background script fails, see extension-compat.md |
| Bitwarden: sign in in the popup, autofill a login form | Works | **Not tested**; the background script fails, see extension-compat.md |
| Settings > Extensions: switch one off, Remove one | The button goes away; after Remove, the extension is gone after relaunch | Not tested by a person |
| Settings > Extensions > Load an unpacked extension > Choose… with scripts/test-extension | Installs after the prompt | Tested through the Debug option `-BoskInstallExtension`, not through the panel |

## Settings and default browser (M7)

| Check | Expected | Verified |
|---|---|---|
| Settings > Make Default | macOS asks to confirm; after that a link clicked in Mail opens in Bosk | **Not tested** (it changes your Mac's default browser) |
| Settings > default page zoom 150 % | Open and new tabs show pages at 150 % | New tabs: yes (set with `defaults write`). The picker itself: not tested by a person |
| Cmd+= / Cmd+- / Cmd+0 | Zoom one tab; Cmd+0 goes back to the default | Not tested |
| Double-click an .html file in Finder, with Bosk as its app | Opens in a new Bosk tab | Not tested |

## Settings window (panes)

| Check | Expected | Verified |
|---|---|---|
| Open Settings (Cmd+,) and click each pane | General, Tabs, Extensions, Downloads, Privacy, About show their cards | Yes (screenshots, dark and light) |
| General > Appearance: Light, Dark, System | Settings, browser window and sidebar change at once | Light and System: yes |
| General > Appearance on a page that uses `prefers-color-scheme` | The page changes with the setting | Not tested |
| General > Correct spelling as you type: on, then type "teh " in a text field | The word is corrected; with the switch off it is not. If it works only after a relaunch, the row text must say so | **Not tested** (Bosk writes WebKit's `WebAutomaticSpellingCorrectionEnabled` key; not confirmed that WebKit reads it) |
| Tabs > Sleep tabs, launch with `-BoskSleepAfterSeconds 15` | A normal background tab sleeps; a pinned tab stays awake | Not tested (pinned rule: unit test only) |
| Tabs > Sleep tabs off | No tab sleeps, also under memory pressure | Not tested |
| Downloads > Change…, then download /download | The file goes to the new folder. If the folder is deleted later, files go to ~/Downloads | Not tested |
| Downloads > Ask where to save each file, then download | A save panel opens; Cancel stops the download and removes it from the list | Not tested |
| Privacy > History > Clear | Asks first; after that, command bar suggestions show no visited sites | Not tested |
| Privacy > Sign out of everything | Asks first; after that, a site you were signed in to asks you to sign in | Not tested |
| Privacy > Cache > Clear | No prompt; sign-ins stay | Not tested |
| Extensions > paste a store link, and a bare ID | Add turns on; Add shows the permission prompt and installs | Not tested |
| Extensions > Open the Store | chromewebstore.google.com opens in a tab of a browser window | Not tested |
| Extensions > … > Reload on an unpacked extension, after a change in its folder | The change takes effect; permissions stay | Not tested |
| Extensions > … > Remove | The extension is gone, also after relaunch | Not tested |
| About > Send Feedback | A GitHub new-issue page opens with the Bosk and macOS versions in the text | Not tested |
| About > Check now | Off in builds without a Sparkle feed ("Not set up in this build") | Yes (Debug build) |
| Bosk > Check for Updates… | Off (gray) in builds without a Sparkle feed. About Bosk, Settings…, File > New Window and Close Tab stay on | Yes (Debug build; the item cannot be pressed, the others can) |

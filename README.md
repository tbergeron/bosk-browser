<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Bosk icon">
</p>

# Bosk

A small, fast, opinionated web browser for macOS. Built on WebKit.

**Private by design.** No telemetry. No bloat. Just pure raw speed.

- Tabs in a sidebar, pinned tabs as a grid, a sidebar that folds into a strip.
- Tabs sleep after 30 minutes idle to keep memory low. Pinned tabs stay awake. Settings can turn sleep off.
- Chrome extension support through WebKit's `WKWebExtension`.
- A built-in ad and tracker blocker (EasyList and EasyPrivacy), with a switch in Settings and one per site.

Requires macOS 26 or later.

## Privacy

Bosk has no backend and no account is needed. It collects nothing about you. Your history, tabs and
settings stay on your Mac. The ad blocker downloads its filter lists from easylist.to once a week,
with no cookies and nothing about you in the request.

## Build

```bash
brew install xcodegen
xcodegen generate
open Bosk.xcodeproj
```

Core logic tests:

```bash
swift test --package-path Packages/BoskCore
```

## Documentation

- [docs/perf-budgets.md](docs/perf-budgets.md): speed and memory budgets, and how to measure them
- [docs/extension-compat.md](docs/extension-compat.md): tested Chrome extensions and WebKit's gaps
- [docs/manual-checklist.md](docs/manual-checklist.md): checks that need a person, before a release
- [docs/release.md](docs/release.md): signing, notarization and Sparkle updates

## Scripts

| Script | What it does |
|---|---|
| `scripts/test-pages.py` | Local test pages (dialogs, pop-ups, downloads, sign-in, forms, ads) |
| `scripts/test-extension/` | A small Manifest V3 extension to test extension support |
| `scripts/measure-memory.sh` | Total memory of a running Debug build and its WebKit processes |
| `scripts/measure-hitches.sh` | Instruments hitch trace of the sidebar and tab switching |
| `scripts/release.sh` | Signed, notarized DMG and Sparkle appcast |

## Contributing

Bosk stays small on purpose: every feature must earn its place, and speed and low memory come
first. If you share that vision and want to make Bosk better, pull requests are welcome. Good
fits are fixes, speed and memory gains, and polish. Before you build a large new feature,
open an issue first, so we can agree it fits a browser with no bloat.

## License

MIT

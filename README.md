# Bosk

A small, fast, opinionated web browser for macOS. Built on WebKit.

- Tabs in a sidebar, pinned tabs as a grid, a sidebar that folds into a strip.
- Tabs sleep after 60 minutes idle to keep memory low.
- Chrome extension support through WebKit's `WKWebExtension`.
- No account. Nothing collected. Very few settings.

Requires macOS 26 or later.

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

## License

MIT

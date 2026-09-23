# Performance budgets

Bosk is about a fast UI and low memory use. These are the budgets, how to measure them,
and the last measured values. Measure again after any change to the sidebar, tabs or sleep.

| Budget | Target | Last measured (2026-09-23, Debug unless noted) | Status |
|---|---|---|---|
| App bundle size | < 10 MB | 5.4 MB (Release, with Sparkle) | Met |
| Launch to first window frame | ≤ 300 ms | 309–347 ms warm, 736 ms cold (Debug, 15 restored tabs); 378–552 ms with 2 extensions | Not met in Debug; measure Release |
| App process footprint at launch | ≤ 60 MB | 27–33 MB with no extensions; 52–54 MB with 2; 577 MB with 7 (see extension-compat.md) | Met without many extensions |
| 30 tabs, 29 asleep vs 1 tab | Close to 1 tab | 262 MB vs 197 MB (26 awake: 2,373 MB) | Met |
| Sleeping tab's web process ends | Yes | Yes, but WebKit ends it after a delay (up to ~105 s) | Met |
| Hitches during sidebar fold/unfold | 0 | 0 in one run, 4 short (17–33 ms) in the next run | Not stable |
| Switch to an awake tab | Next frame | No hitch within 100 ms in most switches | Partly met |
| Switch to a sleeping tab | Snapshot on next frame | Snapshot shown at once; web view made one frame later | Met (by design) |

The test Mac runs at 60 Hz, so a hitch is at least one 16.7 ms frame. There was no 120 Hz display
to test on.

## How to measure

**Memory.** Run a Debug build. It writes its WebKit process IDs to
`~/Library/Caches/Bosk/processes.json` every 2 seconds. Then:

```bash
scripts/measure-memory.sh
```

To test tab sleep without a 60-minute wait, start the Debug build with a short idle limit:

```bash
open -n build/Build/Products/Debug/Bosk.app --args -BoskSleepAfterSeconds 20
```

**Hitches.** The Debug build has a harness (`-BoskPerfTest YES`) that folds the sidebar six times
and switches tabs eight times, with signposts around each. The script records an Instruments
"Animation Hitches" trace and prints the hitches that happen during those signposts:

```bash
scripts/measure-hitches.sh
```

The results change from run to run with other load on the Mac (Xcode indexing, other apps).
Run it two or three times and compare.

## What made the difference

- The page is resized one time only, never on each animation frame. WebKit holds the
  commit that resizes a page until the page draws at the new size (tens of ms).
- The layout work for a fold is done one frame before the animation starts.
- The sidebar and window backgrounds are solid colors. Two overlapping "behind window"
  blur views cost render time on every animation frame.
- The sleep check asks all pages for their media state at the same time, with a 1 s limit.
  A suspended background page may never answer.

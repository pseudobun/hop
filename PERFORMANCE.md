# Performance

What hop costs, measured, and how to measure it again. The numbers below were measured on
2026-11-11 on a Mac mini (Apple silicon, macOS 27.2) over Screen Sharing. They compare `main`
before and after the work on the `perf/profile-and-trim` branch.

## How to measure

```sh
just bench          # timings + footprint (optimised Debug build, "hop Dev" data)
just bench 200      # + footprint before and after 200 rounds of every scenario
just bench 200 -DebugBenchmarkStay YES                   # then: leaks <pid>, heap <pid>, vmmap <pid>
just bench 300 -DebugBenchmarkSoakOnly clipboard         # soak one scenario
just bench 0 -DebugClipboardDir /path/to/a/copy          # a fixed clipboard history
```

`scripts/bench.sh` builds Debug with `-O` and signs it ad hoc with `get-task-allow`, so `leaks`,
`heap` and `malloc_history` can attach. `hop/App/DebugBenchmark.swift` drives the real panels on
the main thread:

- **Timings:** each scenario 25 times; median and p90 in milliseconds of main-thread time. Each
  run drains its own autorelease pool, as a run-loop turn would.
- **Soak:** every scenario again N times, back to the run loop between rounds. The footprint
  (`phys_footprint`) is printed after warm-up and after the soak.
- **A/B:** the numbers below are the medians of 5 runs per build, each with a fresh copy of the
  same real clipboard history (15 entries, 14 of them images). Without a fixed history the
  clipboard numbers move with whatever the dev build has recorded.

Other tools used for this report:

| Measurement | Tool |
|---|---|
| Leaks | `leaks <pid>` after a soak |
| What holds memory | `vmmap --summary`, `heap -s`, `malloc_history` (`MallocStackLogging=1`) |
| Where the main thread spends its time | `sample <pid> 8` during a soak of one scenario |
| Idle CPU | `ps -o time=` over 10 s, `top -stats cpu,idlew` |

## Results

### Memory

| | before | after |
|---|---|---|
| Footprint after warm-up | 102 MB | **77 MB** |
| Footprint after 100 more rounds of every scenario | 122 MB | **102 MB** |
| Peak footprint | 196 MB | **161 MB** |
| Footprint, launcher only (before the clipboard is shown) | 62–63 MB | **52 MB** |
| Leaks (`leaks`, after 100 soak rounds) | 0 | 0 |

Soaking 50, 300 or 600 rounds of one scenario ends at the same footprint (about 100 MB in the
Debug build): memory stops growing once caches are full. Nothing grows with use.

Benchmark builds are Debug with `-O`; a release build at rest is about 45 MB (README).

### Main thread

p50 / p90, milliseconds:

| | before | after |
|---|---|---|
| Clipboard: show + hide | 23.1 / 25.8 | **10.1 / 11.0** |
| Clipboard: type "the" (4 keys) | 46.3 / 52.3 | **22.2 / 25.1** |
| Launcher: show + hide | 0.87 / 1.37 | 0.83 / 1.27 |
| Launcher: type "terminal" (8 keys) | 12.6 / 13.6 | 12.5 / 14.4 |
| Launcher: type "10 km to mi" (11 keys) | 15.1 / 16.1 | 15.2 / 16.8 |
| Emoji: open, type "heart" | 10.3 / 10.8 | 10.4 / 11.7 |
| Notes: show + hide | 32.6 / 35.2 | 32.6 / 35.9 |
| Settings: show + close | 33.8 / 36.8 | 33.6 / 35.4 |

Typing in the launcher was already about 1.5 ms a key and stays there. Showing Notes and Settings
is mostly the window server ordering the window in (`SLSWindowIsOrderedIn`), not hop's code.

### Idle

0 % CPU and about one wakeup every 10 s while the Mac is idle, before and after.

## What changed

1. **The launcher's watermark** (`WatermarkView`). It drew a panel-sized image through an
   NSImage drawing handler, which kept two bitmaps (10.9 MB and 4.7 MB) for a mark at 5 %
   opacity. It now draws only the bunny's square, once per size, straight into one bitmap.
2. **App icons** (`IconCache`). `cgImage(forProposedRect:)` returns the nearest representation,
   128 × 128 (64 KB), for a 44 px row. Icons are now drawn into a bitmap of exactly the drawn
   size, about 8 KB each. Cache keys include the size, so Settings' 20 and 36 pt tiles no
   longer share one image.
3. **Clipboard history window.**
   - Rows are updated in place as the launcher's are; `reloadData` re-added and laid out every
     visible row view on each keystroke.
   - The preview is built again only when the selected entry changes, not on every keystroke.
   - Image previews are decoded at the preview's size, not in full (a 5K screenshot is 59 MB
     decoded).
   - The source app's icon is a 16 pt bitmap, not a full workspace icon.
4. **Row views are reused** in the clipboard, Notes and action-panel lists.
5. **Clipboard capture off the main thread.**
   - `index.json` is encoded and written on a background queue. A full history (2 000
     entries, text up to 2 MB each) is megabytes of JSON, encoded about a second after every
     copy.
   - Copied images are converted to PNG, hashed and written off the main thread. A PNG's size
     is read from its header instead of decoding it.
6. **Background work.**
   - The app index rescans only when a change can alter the app list: a watched folder, or an
     app's `Contents`. An app updating files inside its bundle used to rescan every app.
   - `ProcessRunner.run` is `@concurrent`. Under approachable concurrency it ran on its
     caller's actor, so spawning `scutil` and AppleScript ran on the main thread.
   - The drag watcher asks the drag pasteboard at most every 50 ms. It used to ask on every
     drag event (60–120 a second) while text was selected or a window moved.
7. **KeePass search.** Each keystroke now touches each database's auto-lock once, not once per
   entry. Favourites are looked up once per database, and the `keepassxc-cli` path at most
   every 10 s.

Items 5–7 do not appear in the benchmark (it doesn't copy, rescan, drag or unlock KeePass); they
are judged from the code.

## Release build at rest

Measured on 2026-11-12 on olympus: Mac mini, Apple M4 Pro, 24 GB, macOS 27.2, one display
(3320 × 2040, Screen Sharing). The installed release builds from the beta casks ran together:
paw 0.1.0-beta.21, hop 0.1.0-beta.13 and tip 0.1.0-beta.1.

Idle counters come from `proc_pid_rusage` (CPU time, `ri_pkg_idle_wkups` + `ri_interrupt_wkups`,
`ri_phys_footprint`) over 120 s with nobody at the keyboard. CLI round trips are the median and
p90 of 50 runs after 10 warm-up runs, process start included; starting `/usr/bin/true` costs
1.4 ms on this machine.

| | |
|---|---|
| Idle CPU | 0.03 % |
| Wakeups | 11.5 per 10 s |
| Footprint | 43.7 MB (peak 46.7 MB) |
| Threads | 3 |
| App bundle / binary | 9.3 MB / 3.5 MB |
| `hop version` | 10.4 ms p50, 11.9 ms p90 |
| `hop clip count` | 12.3 ms p50, 13.1 ms p90 |
| `hop apps term --json` | 54.5 ms p50, 63.7 ms p90 |

`just bench` on the same day (`beta`, optimised Debug build, "hop Dev" data), milliseconds of
main-thread time, median / p90:

| Scenario | ms |
|---|---|
| First show | 15.2 |
| Show with a cold icon cache | 5.3 |
| Show + hide | 0.85 / 1.13 |
| Type "safari" (6 keys) | 10.8 / 11.8 |
| Type "terminal" (8 keys) | 12.0 / 12.5 |
| Type "sys set" (7 keys) | 13.7 / 13.9 |
| Type "12*3+4" (6 keys) | 16.0 / 17.9 |
| Type "10 km to mi" (11 keys) | 18.5 / 22.1 |
| Clear to an empty query | 1.27 / 1.32 |
| Move ↓↓↓↓↓ ↑↑↑↑↑ (10 keys) | 0.23 / 0.24 |
| Clipboard: show + hide | 15.7 / 18.6 |
| Clipboard: type "the" (4 keys) | 9.6 / 10.0 |
| Notes: show + hide | 33.5 / 34.9 |
| Settings: show + close | 40.3 / 43.9 |
| Emoji: open, type "heart" | 10.8 / 16.0 |

The benchmark build's footprint went from 51 MB after the first show to 80.5 MB after every
scenario had run once, Settings and Notes included.

## Known costs

- Showing Notes and Settings costs about 30 ms, mostly in the window server.
- Settings builds its window at launch and keeps the last page's views after it closes.
- The clipboard folds and keeps every entry's search text after the first search, for fast
  typing. A large history roughly doubles in memory.
- `FuzzyScorer.score` allocates two arrays per call. It is 0.5 ms for a whole query today.

`hopTests` covers the background save, off-main image capture and its de-duplication, PNG sizes
read without decoding, icon sizes, per-size icon cache keys and the app-index filter.

# Changelog

## 0.1.0-preview — 2026-09-30

First public preview. Requires macOS 26 or later on Apple Silicon.

This build is **not notarized** (no Apple Developer ID yet). See `FIRST-RUN.md` inside the download for how to open it. Unsigned preview builds store data locally, so the widget and `ohm receipt` show no data in them; builds you compile yourself with your own Apple team keep full functionality.

### Added
- Menu bar popover with live system power, battery forecast and thermal state.
- Energy ledger (SQLite) with a daily per-app battery receipt.
- E-core lane: move an app to the efficiency cores (`PRIO_DARWIN_BG`), including regular Apple apps such as Xcode or Safari. System components stay protected.
- Journaled freezing with an independent watcher (`ohm-thawd`) that thaws everything if Ohm is killed.
- Runaway process detector with notifications (move to E-core, freeze after confirmation, quit).
- Rule engine with natural-language rules via on-device Foundation Models; new rules start disabled.
- Widget with today's receipt.
- `ohm` command-line tool (`receipt`, `top`, `ecore`, `freeze`, `thaw`, `thaw --all`) over a user-only control socket, and App Intents for Shortcuts.

### Measured (M3, macOS 27, idle)
- Memory about 21 MB (`phys_footprint`, app + watcher), CPU about 0.03 %, package 8.7 MB.

### Known limitations
- Live per-component CPU/DRAM/ANE power is not available from IOReport on macOS 27; GPU power and total system load are shown.
- Automatic (rule-based) freezing is effectively off by default: only apps on a verified list can be frozen by rules.

# Ohm

[Türkçe](./README.tr.md) | English

**Where did your battery go? See it, and stop it with one click.**

Ohm is a lightweight macOS menu bar utility for Apple Silicon that monitors live power consumption, attributes energy usage to applications in intuitive battery minutes, and lets you relegate heavy background tasks to Efficiency cores (E-cores) or suspend them safely.

---

## Features

- **Live Power Flow (IOReport):** Displays total system load (`SystemLoad`), live GPU power, CPU power aggregated from per-process energy metrics, P/E cluster utilization, and thermal pressure.
  > *Note (per [Docs/PLAN.md](./Docs/PLAN.md)): On macOS 27, IOReport CPU/DRAM/ANE energy counters do not update per-second; component-level live CPU/DRAM/ANE wattage is therefore omitted, while live GPU power and total system load are reported continuously.*
- **Energy Ledger & Daily Receipt:** Measures application energy in joules and translates consumption into clear "battery minutes" and percentage (e.g., *"Slack consumed 38 min battery today"*).
- **E-Core Lane:** Relegate background applications to efficiency cores on demand using Darwin scheduling (`PRIO_DARWIN_BG`), keeping performance cores free.
- **Journaled Freezing & Safety:** Suspend idle background applications via kernel `SIGSTOP` and resume them with `SIGCONT` when they come to the foreground (≈20 ms measured on M3). Uses a write-ahead journal (`~/Library/Application Support/Ohm/Freeze/`) and an independent watchdog (`ohm-thawd`) to ensure all processes thaw within milliseconds even if Ohm crashes or is killed (`kill -9`). Automatic rule-based freezing is restricted to verified topologies and is effectively off by default ([Docs/adr/0004-freeze-safety.md](./Docs/adr/0004-freeze-safety.md)).
- **Runaway Process Detector:** Identifies hidden background processes consuming excessive CPU over extended durations and presents instant actions: *Move to E-core*, *Freeze*, or *Quit*.
- **Rule Engine & Natural Language Rules:** Create automated rules based on system triggers (power source, battery level, thermal state, foreground app, time). Includes on-device natural language rule translation powered by Apple Foundation Models (`@Generable`, requires Apple Intelligence).
- **Battery Forecasting:** Predicts remaining battery life based on your current app workload using a local online linear regression model.
- **Widget:** macOS Notification Center and desktop widget providing a quick summary of today's battery receipt.
- **CLI & Shortcuts (App Intents):** *Coming soon* (in active development).

---

## Measured Resource Footprint

Measurements taken on **Apple M3** running **macOS 27** ([Docs/perf/T-061b-idle-runtime.md](./Docs/perf/T-061b-idle-runtime.md)):

- **Idle Memory:** ~21 MB total physical footprint (`phys_footprint`: Ohm ~19 MB + `ohm-thawd` ~1.9 MB).
- **Idle CPU:** ~0.03% average (0.0267%).
- **Package Size:** 8.7 MB.

---

## Requirements

- **Platform:** Exclusively Apple Silicon (M1/M2/M3/M4 or newer).
- **Operating System:** macOS 26+ (macOS Tahoe or newer).

---

## Installation

### Building from Source (Current)

Ohm can be compiled locally using Xcode 27 and XcodeGen:

1. **Clone the repository:**
   ```bash
   git clone https://github.com/kuarezma/ohm.git
   cd ohm
   ```

2. **Install XcodeGen (if not installed):**
   ```bash
   brew install xcodegen
   ```

3. **Build and test using the CI script:**
   ```bash
   bash scripts/ci/build-test.sh
   ```

4. **Or build with Xcode / xcodebuild directly:**
   ```bash
   cd app
   xcodegen generate
   xcodebuild -project Ohm.xcodeproj -scheme Ohm -configuration Debug build
   ```

### Preview Releases (Unsigned)

Experimental preview archives (`Ohm-<version>-preview.zip`) are published as pre-releases on [GitHub Releases](https://github.com/kuarezma/ohm/releases). Because Ohm does not yet have a paid Apple Developer ID, macOS Gatekeeper will block it on first launch. See [packaging/preview/FIRST-RUN.md](./packaging/preview/FIRST-RUN.md) for launch steps or run `xattr -dr com.apple.quarantine /Applications/Ohm.app`. If App Group container access is restricted on your machine, compiling from source with your free Personal Team is recommended.

### Pre-built Releases & Homebrew Cask

- **Pre-built signed binaries:** Available with the first signed release on GitHub Releases.
- **Homebrew Cask:** A cask template is prepared at [packaging/homebrew/ohm.rb](./packaging/homebrew/ohm.rb). Installation via `brew install --cask ohm` will be available with the first signed release.

---

## Privacy & Security

- **100% Local & Offline:** Ohm makes no network calls, contains no tracking, and collects zero telemetry. All metrics and rules remain strictly on-device in the sandboxed App Group container (`*.dev.ohm`) and local storage.
- **Protected Processes:** System processes (`/System/`, `/usr/`, `/Library/Apple/`), Apple application bundles, and Ohm itself are protected by a strict static scope gate.
- **Crash Safety:** The companion watcher daemon (`ohm-thawd`) monitors Ohm continuously and unfreezes all suspended processes immediately if Ohm exits unexpectedly.
- For full details, see [Docs/adr/0004-freeze-safety.md](./Docs/adr/0004-freeze-safety.md) and [SECURITY.md](./SECURITY.md).

---

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](./CONTRIBUTING.md) for environment setup, testing commands, and development guidelines.

---

## License

Licensed under the [Apache License 2.0](./LICENSE).

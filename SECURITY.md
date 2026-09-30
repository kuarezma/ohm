# Security Policy

## Supported Versions

Ohm is currently in active development. Security updates are applied to the `main` branch and will be included in subsequent tagged releases.

| Version | Supported          | Platform                    |
| ------- | ------------------ | --------------------------- |
| `main`  | :white_check_mark: | macOS 26+ (Apple Silicon)   |

## Reporting a Vulnerability

If you discover a security vulnerability in Ohm, please **do not open a public issue**. Instead, report it privately using GitHub Security Advisories:

- **Private Advisory Submission:** [Open a private security advisory on GitHub](https://github.com/kuarezma/ohm/security/advisories/new)

Please include:
- A description of the vulnerability and potential impact.
- Clear reproduction steps or proof-of-concept code.
- Your macOS version and hardware configuration.

You will receive an acknowledgment within 48 hours, followed by updates on remediation and coordinated disclosure.

## Security Model Summary

Ohm interacts directly with kernel and system scheduling primitives (`SIGSTOP`/`SIGCONT`, `PRIO_DARWIN_BG`, `libIOReport`, `proc_pid_rusage`). To ensure system stability and prevent user data loss, Ohm adheres to the strict security invariants defined in [Docs/adr/0004-freeze-safety.md](./Docs/adr/0004-freeze-safety.md):

1. **Freeze Safety & Watchdog (`ohm-thawd`)**:
   - Before any process receives `SIGSTOP`, a journal record is persisted to disk (`~/Library/Application Support/Ohm/Freeze/`) and flushed with `fsync` (Write-Ahead Logging).
   - An independent, lightweight watcher daemon (`ohm-thawd`) monitors Ohm. If Ohm crashes, hangs, or is terminated unexpectedly (`kill -9`), `ohm-thawd` automatically thaws all suspended processes by sending `SIGCONT` within milliseconds.
   - Any surviving frozen processes are also recovered and thawed upon subsequent launch.
   - Any foreground application activation (`NSWorkspace.didActivateApplicationNotification`) immediately triggers an automatic thaw.

2. **Protected Processes & Static Scope Gate**:
   - Ohm enforces a strict static scope gate: system processes located in `/System/`, `/usr/`, `/Library/Apple/`, Apple bundles (`com.apple.*`), and Ohm itself (`dev.ohm.*`) are protected and excluded from automatic intervention.
   - Automatic rule-based freezing is restricted to verified topologies; in the default configuration, automatic rule freeze is effectively disabled by default per [Docs/adr/0004-freeze-safety.md](./Docs/adr/0004-freeze-safety.md).

3. **Privacy & Local Storage**:
   - Ohm operates entirely offline. It does not use `URLSession`, initiate HTTP/network requests, or collect telemetry.
   - All energy metrics, rules, and ledger records are stored locally on-device inside the App Group container (`*.dev.ohm`) and local application support paths.

# Contributing to Ohm

Thank you for your interest in contributing to Ohm! Ohm is an energy and core governor built specifically for Apple Silicon Macs running macOS 26+.

## Development Environment

To build and contribute to Ohm, you will need:
- An **Apple Silicon Mac** (M1/M2/M3/M4) running **macOS 26+**.
- **Xcode 27+** (with Command Line Tools installed).
- **XcodeGen**: Install via Homebrew:
  ```bash
  brew install xcodegen
  ```

### Project Generation & Code Signing

Ohm uses XcodeGen to generate its Xcode project dynamically. `app/Ohm.xcodeproj` is generated from `app/project.yml` and is intentionally gitignored.

1. Generate the project:
   ```bash
   cd app && xcodegen generate
   ```
2. Configure local code signing (optional):
   Create `app/Local.xcconfig` (which is gitignored) with your Apple Developer Team ID:
   ```xcconfig
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   ```
   If you do not have an Apple Developer team configured, local debug builds can be performed with signing disabled (`CODE_SIGNING_ALLOWED=NO`).

## Build & Test Commands

Before submitting changes, verify that all automated checks pass locally.

### Automated CI Suite
The easiest way to verify project generation, test suites, and debug compilation is the CI script:
```bash
bash scripts/ci/build-test.sh
```

### Swift Unit Tests (OhmCore)
To run the full suite of unit tests for the core logic:
```bash
cd app/OhmCore && swift test
```

You can also run targeted test suites:
```bash
cd app/OhmCore
swift test --filter OhmLedger
swift test --filter OhmGovernor
swift test --filter OhmRules
swift test --filter OhmSampling
```

### Xcode Build
To build the menu bar app directly via `xcodebuild`:
```bash
cd app
xcodegen generate
xcodebuild -project Ohm.xcodeproj -scheme Ohm -configuration Debug build
```

### Release Packaging Dry-Run
To test release artifact packaging and entitlement expansion without signing credentials:
```bash
bash scripts/ci/release.sh --dry-run
```

## Architecture & Multi-Model Coordination

- **Architecture & Specifications:**
  - [Docs/PLAN.md](./Docs/PLAN.md): Overall project architecture, technical feasibility, and feature scope.
  - [Docs/adr/](./Docs/adr/): Architectural Decision Records detailing system design:
    - [ADR 0001: Modules & Concurrency](./Docs/adr/0001-modules-and-concurrency.md)
    - [ADR 0002: Energy Ledger Schema](./Docs/adr/0002-energy-ledger-schema.md)
    - [ADR 0003: Rule DSL](./Docs/adr/0003-rule-dsl.md)
    - [ADR 0004: Freeze Safety & Activation Model](./Docs/adr/0004-freeze-safety.md)

- **Multi-Model Coordination:**
  - Ohm is developed with a collaborative multi-model team structure.
  - Coordination guidelines, task tracking, and role handoffs live in [Docs/coordination/ROLES.md](./Docs/coordination/ROLES.md), [Docs/coordination/TASKS.md](./Docs/coordination/TASKS.md), and [Docs/coordination/HANDOFF.md](./Docs/coordination/HANDOFF.md).
  - Status updates are reported via local `Docs/coordination/board.json` (gitignored).

## Pull Request & Commit Guidelines

1. **Minimal Diffs:** Touch only files directly required for the task. Avoid formatting changes to untouched lines.
2. **Commit Hygiene:** Use clear, conventional commit messages:
   - `feat: add new metric view`
   - `fix: resolve race condition in governor recovery`
   - `docs: update build instructions`
   - `test: add regression test for ledger interval calculation`
3. **Verification Evidence:** Include the output of `bash scripts/ci/build-test.sh` in your PR description.
4. **Never Commit Secrets or Local State:** Ensure `app/Local.xcconfig`, `.xcodeproj`, `DerivedData`, and credentials are never checked into version control.

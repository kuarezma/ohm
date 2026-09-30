# Running the Ohm Preview Release

This preview release is unsigned because the project does not currently have a paid Apple Developer ID certificate.

Because of this, macOS Gatekeeper will block the application from opening on the first launch. Follow the steps below to run Ohm.

---

## First Launch Steps (Gatekeeper Bypass)

1. Move **`Ohm.app`** to your **`/Applications`** folder.
2. Double-click **`Ohm.app`**. macOS will show a prompt stating that Apple cannot check it for malicious software. Click **Done** (or **Cancel**).
3. Open **System Settings › Privacy & Security**.
4. Scroll down to the **Security** section. You will see a notice stating *"Ohm was blocked from use because it is not from an identified developer"*.
5. Click **Open Anyway**, enter your Mac password or Touch ID when prompted, and confirm by clicking **Open**.

### Alternative: Terminal Command

If you prefer using Terminal, remove the quarantine attribute directly:

```bash
xattr -dr com.apple.quarantine /Applications/Ohm.app
```

Then open Ohm normally from Spotlight or `/Applications`.

---

## Important Note on App Groups & Building from Source

Ohm shares energy metrics between the menu bar application, background worker, and widget via an App Group container (`dev.ohm`). On modern macOS versions (macOS 15/Tahoe+), access to team-prefixed App Group containers requires binaries signed with an active Apple Developer Team identity; unsigned ad-hoc builds may fail to access the shared Energy Ledger when launched via LaunchServices.

If you encounter an "Access denied" or "Runtime start failed" error with pre-built binaries on your system, please compile Ohm locally from source using your free Personal Team:

```bash
git clone https://github.com/kuarezma/ohm.git
cd ohm
bash scripts/ci/build-test.sh
```

Pre-built preview archives from CI are intended for testing; local compilation with your Personal Team provides full access to App Group containers and widget functionality.

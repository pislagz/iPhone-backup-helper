# iPhone Backup Helper — notes for Claude Code

A lightweight macOS menu-bar app (an iMazing Mini alternative) that makes local iPhone/iPad backups to the Mac over USB or Wi-Fi, with per-device schedules and conditions. No backup viewer: restores happen in Finder. Full research and decisions: `docs/PLAN.md` (read it first; section 6 "Decisions" is binding).

## Hard requirements
- **Finder compatibility:** backups are standard MobileSync backups in `~/Library/Application Support/MobileSync/Backup/<UDID>/` (Info.plist, Manifest.plist, Manifest.db, Status.plist, hashed file tree) so Finder lists and restores them. One incremental backup per device (no snapshots in the MVP).
- **Encrypted and unencrypted** backups both work. The device encrypts; the app never needs the backup password. Show encryption status per device.
- **Fully offline:** the app never sends packets to the internet. Only the usbmuxd Unix socket `/var/run/usbmuxd` and the LAN connection to the phone that usbmuxd sets up. No URLSession/HTTP, no updater, analytics, crash reporting or remote config. Do not build/ship libcurl or ideviceactivation. Any direct IP connect must be restricted to loopback/link-local/RFC1918/ULA in code. A CI check enforces this.
- **Self-contained:** no Homebrew at runtime. libplist, libimobiledevice-glue, libusbmuxd, libimobiledevice and the TLS library are built from source (pinned versions/commits) as universal (arm64+x86_64) dylibs, placed in `Contents/Frameworks`, rpath-linked and signed with the app. Ship their license texts.
- **Licensing:** libimobiledevice & co. are LGPL-2.1 — link dynamically. Do NOT copy code from libimobiledevice's `tools/` (GPL, e.g. idevicebackup2.c); write our own backup driver in Swift against the library's mobilebackup2 API, using the protocol knowledge only.
- **Passcode on every backup** (iOS 16.1+): unavoidable. Flow: notify "Unlock your iPhone to back up", wait (configurable, default 5 min), then time out and retry later in the window.
- Minimum macOS 13 Ventura (MenuBarExtra, SMAppService). iOS: whatever mobilebackup2 supports.

## Tech
- Swift 5.9+, SwiftUI `MenuBarExtra`, `LSUIElement` (no Dock icon), Swift Package Manager (no Xcode project needed). `scripts/` assembles the `.app` bundle.
- The build/dev machine for Claude Code is **Linux with no Swift toolchain**: you cannot compile locally. All compilation and tests run in **GitHub Actions on macOS runners** (repo is public, so they're free). Push, then watch with `gh run watch` / `gh run view --log-failed`, and fix until green. Keep pure logic (rules, scheduler, plist parsing, usbmux framing) in a library target with XCTest unit tests that don't need a device.
- Keep the backup engine behind a `BackupEngine` protocol (libimobiledevice engine first; `AppleMobileBackup` wrapper optional, off by default).

## Workflow rules
- Work on the branch you are given. Focused commits: `git -c user.name=Claude -c user.email=noreply@anthropic.com commit ...`
- Push: `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -u origin <branch>`
- Never push to `main`, never merge, never force-push, never touch other repos, never create releases or tags.
- Disk on the dev box is tight (~1 GB free): no large downloads, no local toolchains. CI caches the built C libraries.
- If something needs a product decision, make the smallest reasonable choice and list it in `docs/DECISIONS-FOR-PP.md`.

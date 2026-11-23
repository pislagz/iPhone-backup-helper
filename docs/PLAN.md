# iPhone Backup — a lightweight menu-bar app for local iPhone backups (research and plan, 2026-11-23)

## 1. How Finder and iMazing do it
- **usbmuxd** (Apple daemon, socket `/var/run/usbmuxd`) multiplexes TCP to devices over USB *and* Wi-Fi (Bonjour `_apple-mobdev2._tcp`). Plist protocol: `ListDevices`, `Listen` (Attached/Detached events), `Connect`, `ReadPairRecord` (non-root apps get pair records this way; `/var/db/lockdown` is SIP-protected).
- **lockdownd** on device (port 62078): TLS session using the pair record. `GetValue` (device info; battery via domain `com.apple.mobile.battery` → `BatteryCurrentCapacity`, `BatteryIsCharging`), `StartService`.
- **com.apple.mobilebackup2** service (DeviceLink protocol): the device's BackupAgent streams files and the computer writes them. The device does the encryption.
- Sync lock: notification_proxy (`syncWillStart/DidStart/DidFinish`) + AFC lock on `/com.apple.itunes.lock_sync`. This shows "Sync in progress" and prevents clashes with Finder.
- Output format: `~/Library/Application Support/MobileSync/Backup/<UDID>/` (Info.plist, Manifest.plist/db, Status.plist, hashed files). Finder restores from there. It's TCC-protected, so our app needs **Full Disk Access**.
- Wi-Fi: needs Finder's "Show this iPhone when on Wi-Fi" (lockdown `com.apple.mobile.wireless_lockdown` / `EnableWifiConnections`). Same pairing. Reachability is flaky when the phone is asleep and not charging.
- Apple also ships its own CLI: `/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/Versions/A/AppleMobileDeviceHelper.app/Contents/Resources/AppleMobileBackup` (backup/restore/password/erase). Undocumented flags; check `--help` on the Mac.
- iMazing Mini: a menu-bar companion that holds per-device settings (frequency, time window, min battery, location, snapshot retention, encryption) and skips a backup when the last one is too recent. It counts manual backups.

## 2. Hard constraint: passcode on every backup
Since iOS 16.1 / 15.7.1 (CVE-2022-32929) the device asks for its **passcode at the start of every local backup**. This applies to iMazing, AppleMobileBackup and libimobiledevice. It can't be bypassed, so a fully unattended overnight backup is impossible. Design around it:
- When a backup triggers: macOS notification "Unlock iPhone to back up" → wait N min → time out and retry later in the window.
- Retest on current iOS (26.x).

## 3. Engine options
| Option | Pros | Cons |
|---|---|---|
| A. Wrap `AppleMobileBackup` | Apple's own code, max Finder compatibility, zero protocol work | private/undocumented, flags/progress unclear, may change with macOS |
| B. libimobiledevice (LGPL-2.1, Homebrew/bundled dylibs) | proven `idevicebackup2` logic, progress callbacks, works over Wi-Fi through Apple's usbmuxd on macOS, battery/info APIs | C deps to bundle/sign; lags new iOS sometimes |
| C. Pure Swift reimplementation (usbmux + lockdown TLS + DeviceLink/mobilebackup2) | no deps, full control | most work; must handle all edge cases ourselves |
| (pymobiledevice3 is GPL-3 Python, fine for prototyping, bad for shipping) |

**Recommendation:** Swift app; engine behind a `BackupEngine` protocol. Start with **B** (libimobiledevice) and keep **A** as a fallback/compare. Device discovery via usbmuxd `Listen` can be native Swift (simple). Run a spike first to decide.

## 4. App architecture
- SwiftUI `MenuBarExtra` app, no Dock icon (`LSUIElement`), launch at login via `SMAppService`. macOS 13+.
- **DeviceMonitor**: usbmuxd `Listen` → USB/Wi-Fi presence per UDID. Poll battery via lockdown every few min while present.
- **Scheduler/RuleEngine** (per device): frequency (daily / every N h / weekly), time window, min battery (or "ok if charging"), connection (USB only / USB+Wi-Fi), min interval since last success, Mac on AC power, enough free disk.
- **BackupRunner**: sync lock, run engine, progress, cancel, IOPMAssertion to block idle sleep, handle passcode wait/timeout.
- **Snapshots (optional):** before each run, APFS-clone the backup folder (`clonefile`) → cheap history. Retention N days. The default `<UDID>` folder stays the one Finder sees.
- **Menu UI**: device rows (name, model, battery %, charging, USB/Wi-Fi icon, last backup, next window), "Back up now", progress bar, Settings window, notifications (start/needs passcode/done/failed).
- Encryption: show status. Enabling/changing the password is left to Finder (v1). Optionally store the password in the Keychain later.
- Logs: `os_log` + a log file. Read the last backup date from `Info.plist`/`Status.plist`, so Finder backups count too.

## 5. Milestones
0. **Spike (on pp's Mac, 1 day):** list devices (USB+Wi-Fi), read battery, run `idevicebackup2` and `AppleMobileBackup` into MobileSync, confirm Finder sees/restores, measure the passcode-prompt flow over Wi-Fi.
1. Menu-bar skeleton + DeviceMonitor + battery display.
2. Manual "Back up now" with progress + notifications.
3. Rules/scheduler + persistence + login item.
4. Robustness: sleep, disconnect mid-backup, disk space, Finder running concurrently, multiple devices.
5. Optional: snapshots/retention, custom location (symlink caveat), signed/notarized build. No auto-updater (offline requirement); updates = manually downloaded new build.

## 6. Decisions (pp, 2026-11-23)
- Wi-Fi: requires one-time "Show this iPhone when on Wi-Fi" in Finder. Accepted. Wi-Fi backups are in scope for the MVP.
- Passcode on every backup: accepted. Use the notify, wait and retry flow.
- Feature set: like iMazing Mini (menu bar, per-device rules, battery), with no viewer.
- **Versions:** support as wide a range as practical. Proposal: macOS 13 Ventura+ (the minimum for MenuBarExtra and SMAppService). iOS: whatever mobilebackup2 supports. iOS 15 to 26 are tested; older versions are best effort.
- **Self-contained:** no Homebrew. Engine B means building libimobiledevice, libplist, libusbmuxd, libimobiledevice-glue and a TLS library (OpenSSL or mbedTLS) as universal (arm64 + x86_64) dylibs. They go in Contents/Frameworks and are signed with the app. Dynamic linking keeps LGPL compliance simple: ship the licenses and the source offer. Engine A is self-contained by default because it ships with macOS.
- **History/snapshots:** NOT in the MVP. MVP = one Finder-style incremental backup per device (the first run is a full backup, later runs only transfer changes). Snapshots are a future "advanced" option.
- **Encryption:** support both encrypted and unencrypted backups. No password is needed to run a backup, because the device encrypts. Show the encryption status per device. Setting or changing the password stays in Finder for v1.
- **Fully offline (hard requirement):** the app must never send packets to the internet. Only local traffic: the usbmuxd Unix socket (/var/run/usbmuxd), and for Wi-Fi the LAN connection to the phone that usbmuxd/remoted set up (Bonjour/mDNS + TCP on the local network).
  - No Sparkle/auto-update, analytics, crash reporting, telemetry, or remote config. No URLSession/CFNetwork HTTP code.
  - Bundled libs: build without network extras. Do not ship libcurl, ideviceactivation (contacts Apple), or anything else that fetches from the net. OpenSSL/mbedTLS only for the local lockdown TLS session.
  - The app talks to the phone through usbmuxd and never opens its own sockets to non-local addresses. If we must connect to the device IP directly, allow only link-local/RFC1918/ULA destinations and refuse everything else in code.
  - macOS 15+: Wi-Fi discovery may trigger the "Local Network" permission prompt (NSLocalNetworkUsageDescription). That is local only.
  - Out of scope: things the OS or the iPhone do themselves (Gatekeeper/notarization check on first launch, the iPhone talking to Apple). Engine A (Apple's AppleMobileBackup) is an Apple binary; the spike must verify it makes no internet connections, otherwise it is dropped as a fallback.
  - Verification: CI check that the binary doesn't link network/HTTP APIs, plus a test run behind a firewall (LuLu / Little Snitch, or pf rule blocking non-local traffic) showing zero outbound internet connections during discovery, battery polling and a full backup.

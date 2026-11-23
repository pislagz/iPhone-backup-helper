# MVP roadmap (branch `mvp`, one draft PR to `main`)

## M1 — Scaffold, CI, bundled libs, device list + battery
- SwiftPM package: `Sources/BackupCore` (library: usbmux client, lockdown/device info via libimobiledevice, models, rules, scheduler — pure logic testable), `Sources/CLibimobiledevice` (system-library / module map target over the vendored headers+dylibs), `Sources/iPhoneBackupHelper` (SwiftUI MenuBarExtra app), `Tests/BackupCoreTests`.
- `scripts/build-deps.sh`: builds pinned libplist, libimobiledevice-glue, libusbmuxd, libimobiledevice (+ TLS: OpenSSL 3 built minimal `no-shared`? → prefer building OpenSSL as static into libimobiledevice so only our 4 dylibs ship; or mbedTLS — pick what builds cleanly) as universal arm64+x86_64 dylibs with `@rpath` install names, deployment target 13.0, no tools, no Python bindings, no curl/activation. Output to `vendor/` (gitignored); CI caches it keyed on the script hash.
- `scripts/make-app.sh`: swift build -c release (universal), assemble `iPhone Backup Helper.app` (Info.plist with LSUIElement, NSLocalNetworkUsageDescription, bundle id `io.github.pislagz.iphonebackuphelper`, min 13.0), copy dylibs into Contents/Frameworks, fix rpaths, ad-hoc codesign (`codesign --force --deep -s -`), include `Contents/Resources/Licenses/`. Produce a zip.
- `.github/workflows/ci.yml` on macos runner: build deps (cached), `swift test`, make-app, offline check (`scripts/check-offline.sh`: fail if any binary in the bundle links/imports URLSession, CFNetwork HTTP symbols, libcurl, Sparkle, etc.; `nm`/`otool -L` based; also grep sources for URLSession/URLRequest/NWConnection to non-local), upload the zip as an artifact.
- DeviceMonitor: device list + attach/detach events (USB and Wi-Fi/network) via libimobiledevice `idevice_events_subscribe`/`idevice_get_device_list_extended` (or our own usbmux Listen client). Per device via lockdown: DeviceName, ProductType (map to marketing name where cheap), ProductVersion, battery (`com.apple.mobile.battery`: BatteryCurrentCapacity, BatteryIsCharging), WillEncrypt (`com.apple.mobile.backup` domain) for encryption status. Poll battery every ~2 min while present; handle not-paired/untrusted (show "Trust this Mac on the iPhone"), and the Wi-Fi-only-when-awake flakiness gracefully.
- Last backup date read from `MobileSync/Backup/<UDID>/Info.plist` ("Last Backup Date") / Status.plist so Finder backups count. Detect missing Full Disk Access (can't read the MobileSync folder) and show a row with a button opening the FDA pane (`x-apple.systempreferences:` URL via NSWorkspace is local, fine).
- Menu UI: per device row: name, model, battery % + charging, USB/Wi-Fi icon, encrypted lock, last backup ("2 h ago"), placeholder "Back up now". Quit item. Known (previously seen) devices persist and show as "not reachable".

## M2 — Backup engine + manual backup
- `BackupEngine` protocol; `LibimobiledeviceBackupEngine`: own Swift implementation of the mobilebackup2 client loop (version exchange, notification_proxy sync lock `com.apple.itunes-mobdev.syncWillStart` etc. + AFC lock file `/com.apple.itunes.lock_sync`, write Info.plist like Finder/iTunes does, `mobilebackup2_send_request("Backup", ...)`, then handle DLMessageDownloadFiles / UploadFiles / GetFreeDiskSpace / ContentsOfDirectory / CreateDirectory / MoveFiles / MoveItems / RemoveFiles / RemoveItems / CopyItem / DisconnectStatus / ProcessMessage, writing into the MobileSync folder; progress from the messages' progress field). Incremental (reuse existing folder). Must produce Finder-restorable backups, encrypted or not. Write to the real location; on success Status.plist/Manifest come from the device.
- Passcode wait: detect the device waiting for passcode (no progress after starting / specific error) → notification "Unlock your iPhone to back up"; timeout (default 5 min) → cancel cleanly and mark "waiting for passcode timed out".
- IOPMAssertion (PreventUserIdleSystemSleep) during backup; cancel button; one backup at a time per device; refuse if Finder/another sync holds the lock (report "Device busy").
- User notifications (UNUserNotificationCenter): started, needs passcode, finished (duration, size), failed (reason).
- Menu: "Back up now", progress bar with %, cancel.
- Logging: os_log + rolling log file in `~/Library/Logs/iPhoneBackupHelper/`, "Show log" menu item.
- Unit tests for the message handlers using a fake transport and a temp dir.

## M3 — Rules, scheduler, settings, login item
- Per-device settings (persisted JSON in Application Support): enabled, frequency (daily / every N hours / weekly on days), time window (start–end, may cross midnight), min battery % with "ignore if charging", connection (USB only / USB or Wi-Fi), require Mac on AC power, min free disk space (GB), min interval since last successful backup (counts Finder backups), passcode wait timeout, retry interval within window.
- RuleEngine: pure function (now, device state, mac state, settings, last backup) → decision {run, wait(reason), skip(reason)} with human-readable reason shown in the menu ("Next: today 20:00–23:00", "Waiting: battery 14% < 20%"). Extensive unit tests incl. DST and midnight-crossing windows.
- Scheduler: timer tick (every minute) + react to device attach/battery changes/wake from sleep (NSWorkspace notifications).
- Settings window (SwiftUI, opened from menu): device list + the settings above; General: launch at login (SMAppService.mainApp), notifications toggles. Also "Forget device".

## M4 — Robustness, packaging, docs
- Sleep/wake mid-backup, device disconnect mid-backup (clean abort, retry later), disk full, Finder running a sync concurrently, multiple devices queued (one at a time), app quit during backup (cancel cleanly).
- Offline hardening review; `docs/OFFLINE.md` with the firewall verification procedure (LuLu/Little Snitch/pf) for pp.
- `docs/TESTING.md`: manual test checklist on a real Mac+iPhone (USB, Wi-Fi, encrypted, unencrypted, Finder restore, passcode timeout, battery rule, window rule).
- README: install (unzip, move to /Applications, right-click Open because ad-hoc signed, grant Full Disk Access, enable "Show this iPhone when on Wi-Fi" in Finder), usage, limits, licenses.
- CI artifact is the final deliverable zip.

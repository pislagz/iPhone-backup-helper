# iPhone Backup Helper

A small macOS menu-bar app that backs up your iPhone or iPad to your Mac, over USB or Wi-Fi, on a schedule and under conditions you choose (time window, battery level, Mac on power, free disk space ...). Think "iMazing Mini", without a backup viewer.

- **Finder-compatible.** Backups are ordinary MobileSync backups in `~/Library/Application Support/MobileSync/Backup/<UDID>/`. Finder lists them and restores them. Backups made in Finder count too. There is one incremental backup per device (no snapshots).
- **Encrypted and unencrypted** backups both work. The iPhone does the encrypting, so the app never needs (or sees) your backup password. Each device shows a lock icon for its encryption status. Setting or changing the password stays in Finder.
- **Fully offline.** No internet access, no updater, no analytics, no crash reporting. The app only talks to Apple's local device service (`/var/run/usbmuxd`) and, for Wi-Fi backups, to the phone on your LAN. See [`docs/OFFLINE.md`](docs/OFFLINE.md) for how this is enforced and how to verify it with a firewall.
- **Self-contained.** The libimobiledevice libraries it needs are built from source and shipped inside the app. No Homebrew needed.
- Requires **macOS 13 Ventura or later** (Apple silicon and Intel).

## Install

The app is ad-hoc signed (not notarized), so the first launch needs one extra click.

1. Download the build: on GitHub open the latest successful run of the **CI** workflow for this branch (Actions tab) and download the artifact **iPhone-Backup-Helper**. GitHub wraps it in its own zip, so unzip twice: the inner `iPhone-Backup-Helper.zip` contains `iPhone Backup Helper.app` and an `INSTALL.txt`. With the GitHub CLI: `gh run download <run-id> -n iPhone-Backup-Helper`.
2. Move `iPhone Backup Helper.app` to `/Applications`.
3. **Right-click the app → Open → Open** (once). If macOS still refuses ("cannot be opened because the developer cannot be verified"), open System Settings → Privacy & Security and click "Open Anyway" next to the message. As a last resort: `xattr -dr com.apple.quarantine "/Applications/iPhone Backup Helper.app"`.
4. **Grant Full Disk Access**: System Settings → Privacy & Security → Full Disk Access → add `iPhone Backup Helper` and switch it on. macOS protects the MobileSync folder; without this the app can't write backups or read the date of the last one. **Quit and reopen the app after enabling it.** The menu shows a banner with a button for this until it works.
5. The first time you connect an iPhone, tap **Trust** on the phone (and enter its passcode). The first Wi-Fi use may show a macOS "Local Network" prompt: allow it.
6. For **Wi-Fi backups**: in Finder select the iPhone and tick **"Show this iPhone when on Wi-Fi"**, then Apply (one time per device). Without it, only USB works.
7. Optional: Settings → General → **Launch at login**. macOS may ask you to approve it in System Settings → General → Login Items.

## Use

Click the iPhone icon in the menu bar.

- **Each device row** shows its name, model, iOS version, battery level (with a bolt while charging), a lock icon if its backups are encrypted, a USB or Wi-Fi icon, and the time of the last backup (Finder backups included). Devices you connected before stay in the list as "Not reachable".
- **Back up now** starts a backup immediately. A progress bar and a Cancel button appear while it runs. If another device is being backed up, this one shows **Queued** and starts when its turn comes (one backup at a time; Cancel removes it from the queue).
- **Settings…** opens the settings window:
  - per device: automatic backups on/off, frequency (daily, every N hours, or on chosen weekdays), time window (may cross midnight), minimum battery % (optionally ignored while charging), USB only or USB + Wi-Fi, require the Mac on AC power, minimum free disk space, minimum time since the last successful backup, how long to wait for the passcode, retry interval inside the window, and "Forget device" (removes the device and its settings; never its backups);
  - general: launch at login and which notifications to show.
- Under a device with automatic backups on, the menu says what happens next: `Next: today 20:00–23:00`, `Waiting: battery 14% < 20%`, `Queued: …`, `Waiting: retry in 12 min`.
- **Show Log** reveals the log file (`~/Library/Logs/iPhoneBackupHelper/`). It contains no passwords.
- **Quit** during a backup cancels it cleanly first (partial files removed, the iPhone's sync lock released), which can take a few seconds.

### Restoring

Restores happen in Finder, as always: select the iPhone → **Restore Backup…** and pick the backup.

## What to expect (limits)

- **The iPhone asks for its passcode at the start of every local backup** (iOS 16.1 and later). That can't be bypassed, so a fully unattended overnight backup is impossible. The app shows a notification "Unlock your iPhone to back up", waits (5 minutes by default, configurable), and if nobody unlocks the phone it stops and tries again later in the window.
- Wi-Fi backups need the phone awake or charging, on the same network, with Finder's Wi-Fi sync option on. A phone that is asleep may not be reachable.
- **Finder or another app syncing the same phone** at the same time: the app shows "Device busy", leaves the other sync alone and tries again later.
- If the **Mac sleeps** mid-backup, the backup is stopped cleanly and started again after wake-up if it's still due. While a backup runs, the Mac is kept awake (idle sleep only).
- If the phone is **unplugged or the disk fills up** mid-backup, the run stops cleanly. The previous backup stays intact and the app tries again later.
- No backup viewer, no snapshots or history, no custom backup location, no automatic updates (to update, install a newer build manually).
- The Applications list in a *first* backup made by this app may be empty in Finder's backup list. The phone restores from the backup's manifest regardless. (Backups that Finder made earlier keep their list.)
- Built and unit-tested in CI. Real-device behaviour has to be checked by hand: see [`docs/TESTING.md`](docs/TESTING.md).

## Documents

- [`docs/PLAN.md`](docs/PLAN.md): research, architecture and binding decisions.
- [`docs/TASKS.md`](docs/TASKS.md): milestones M1–M4.
- [`docs/DECISIONS-FOR-PP.md`](docs/DECISIONS-FOR-PP.md): every judgement call made along the way.
- [`docs/TESTING.md`](docs/TESTING.md): manual test checklist for a real Mac and iPhone.
- [`docs/OFFLINE.md`](docs/OFFLINE.md): offline design and firewall verification (LuLu, Little Snitch, pf).

## Build from source

Needs a Mac with Xcode command line tools. CI does exactly this.

```sh
scripts/build-deps.sh       # libplist, libimobiledevice-glue, libusbmuxd, libimobiledevice, OpenSSL -> vendor/ (universal)
swift test                  # unit tests (no device needed)
scripts/make-app.sh         # dist/iPhone Backup Helper.app and dist/iPhone-Backup-Helper.zip
scripts/check-offline.sh    # fails if the bundle or sources could use the network
```

## Licenses

- **iPhone Backup Helper** itself: no license has been chosen yet (open question in `docs/DECISIONS-FOR-PP.md`).
- Bundled libraries, linked **dynamically** as separate dylibs in `Contents/Frameworks` so they can be replaced:
  - [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice), [libimobiledevice-glue](https://github.com/libimobiledevice/libimobiledevice-glue), [libplist](https://github.com/libimobiledevice/libplist): **LGPL-2.1**
  - [libusbmuxd](https://github.com/libimobiledevice/libusbmuxd): **LGPL-2.1** (its `usbmuxd` tools are GPL-2.0 and are not built or shipped)
  - [OpenSSL 3.x](https://github.com/openssl/openssl): **Apache-2.0**, linked statically into libimobiledevice
- The exact versions/commits, source locations and license texts are inside the app: `iPhone Backup Helper.app/Contents/Resources/Licenses/` (start with `VERSIONS.txt`). The source of each library is public at the commits listed there; `scripts/build-deps.sh` rebuilds them. Because the libraries are separate dylibs, you can rebuild and swap any of them.
- The backup driver is our own Swift code written against the libimobiledevice library API. No code from libimobiledevice's GPL command-line tools was copied.

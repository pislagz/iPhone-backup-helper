# Manual test checklist (real Mac + real iPhone)

CI only runs unit tests against fakes, so everything that touches a real device is checked here. Tick each item and note the macOS version, iOS version, USB or Wi-Fi, and the result. Do the whole list once per release candidate.

## Setup

- A Mac on macOS 13 or later (ideally also one on the newest macOS). An iPhone on a current iOS, and if you can, a second device (an older iPhone or an iPad) for the queue test.
- Install the CI artifact as in the README (right-click → Open, Full Disk Access, restart the app).
- Pair the iPhone with this Mac (tap "Trust" on the phone). For Wi-Fi: Finder → select the iPhone → "Show this iPhone when on Wi-Fi" → Apply.
- Have a way to see the log: menu → Show Log (`~/Library/Logs/iPhoneBackupHelper/iPhoneBackupHelper.log`).
- Know where backups go: `~/Library/Application Support/MobileSync/Backup/<UDID>/`.
- Delete or move away any old backup of the test phone if you want to see a first (full) backup too. Never test destructive steps on the only copy of a backup you need.

## 1. Discovery and display

- [ ] Plug in the iPhone by USB: it appears within a few seconds with name, model, iOS version, battery % (and the bolt when charging), lock icon (encrypted or not), USB icon, "Last backup" time.
- [ ] Unplug: the row stays, dimmed, "Not reachable (last seen …)".
- [ ] Locked phone: row says "Unlock the iPhone …". Untrusted Mac (Reset Location & Privacy on the phone): "Tap Trust …", and after tapping Trust it recovers without restarting the app.
- [ ] Wi-Fi: with the cable unplugged and "Show this iPhone when on Wi-Fi" on, the phone shows the Wi-Fi icon (it may need to be charging or awake). With Wi-Fi sync off in Finder the row says so.
- [ ] Without Full Disk Access the menu shows the banner and the button opens the right Privacy pane.

## 2. Manual backups

- [ ] **USB, unencrypted** phone (Finder: turn "Encrypt local backup" off): "Back up now", unlock the phone and enter the passcode when asked, progress moves, notification "finished" appears, "Last backup" updates.
- [ ] **USB, encrypted** phone (Finder: "Encrypt local backup" on, with a known password): same flow; the app never asks for the password.
- [ ] **Wi-Fi**, encrypted and unencrypted (cable unplugged, phone awake and on the same network): same flow.
- [ ] Second run is incremental: much faster than the first and the folder doesn't grow by a full copy.
- [ ] Cancel in the middle of a backup: stops within about 10 s, the row says "Backup cancelled", the phone's "Sync in progress" indicator disappears, and `*.ibh-part` files are gone from the backup folder (`find ~/Library/Application\ Support/MobileSync/Backup -name '*.ibh-part'` prints nothing).
- [ ] After a cancelled or failed run, Finder still lists the previous backup with its old date, and a new backup completes normally.

## 3. Finder compatibility (the important one)

- [ ] After a backup made by this app, open Finder → the iPhone → "Manage Backups…": the backup is listed with the right device name and a recent date (and the lock icon for encrypted ones).
- [ ] **Restore** that backup to the phone from Finder ("Restore Backup…"). Use a spare phone or one you can wipe. Check that apps, photos, messages and settings come back. For an encrypted backup, enter the password in Finder.
- [ ] Make a backup in Finder, then one with this app, then another in Finder: all work, "Last backup" is right everywhere.
- [ ] Known limit to confirm: the app list shown by Finder for a *first* backup made by this app may be empty (the device restores from the manifest anyway).

## 4. Passcode flow

- [ ] Start a backup and leave the phone locked: a notification "Unlock your iPhone to back up" appears once, the row says "Unlock your iPhone and enter its passcode".
- [ ] Unlock and enter the passcode within the wait time: the backup continues.
- [ ] Set the passcode wait to 1 minute (Settings → device) and ignore the prompt: after about a minute the backup stops with "was not unlocked in time", a failure notification appears once, and the phone returns to normal.
- [ ] Scheduled run: the retry happens after the retry interval inside the window, not every minute.

## 5. Schedule rules (enable automatic backups in Settings for the device)

- [ ] **Window rule**: set a window starting 2 minutes from now. Before it: the row says "Next: today HH:MM–HH:MM". At the start the backup begins (and asks for the passcode). Outside the window nothing starts.
- [ ] **Window across midnight** (e.g. 23:00–02:00): "Next:" text is right before and after midnight, and one backup only runs per night.
- [ ] **Battery rule**: set the minimum battery above the phone's level with "ignore if charging" off: the row says "Waiting: battery 14% < 20%" style text and nothing starts. Charge the phone above the limit: the backup starts without touching the app. With "ignore if charging" on and the phone charging: it starts.
- [ ] **Connection rule**: "USB only" with the phone on Wi-Fi only: "Waiting: connect by USB".
- [ ] **AC power rule** (laptop): unplug the charger: "Waiting: Mac is on battery power".
- [ ] **Min free disk** set above the real free space: "Waiting: free disk space …".
- [ ] **Min interval** (counts Finder backups): make a backup in Finder, then see that the app waits ("Next: …").
- [ ] **Persistence across restarts**: let a scheduled backup finish, quit and reopen the app: it does **not** back up again (with and without Full Disk Access). Let one fail (pull the cable), quit and reopen within the retry interval: "Waiting: retry in N min".

## 6. Robustness

- [ ] **Queueing two devices** (two phones, or one phone plus one iPad): start both with "Back up now" within a second. One runs, the other shows "Queued (next)" with a Cancel button, then starts by itself when the first finishes. Never two at once. Cancel the queued one: it leaves the queue and doesn't run.
- [ ] Same with scheduled backups: both due at the window start; the menu shows "Queued…" text for the second.
- [ ] **Disconnect mid-backup**: pull the cable during the transfer (or, for Wi-Fi, turn Wi-Fi off on the phone). Within about 15 s the row says "The iPhone was disconnected during the backup", the sync lock on the phone is released, no `*.ibh-part` files remain, Finder still shows the previous backup. Plug in again: the scheduler retries after the retry interval (inside the window), or "Back up now" works at once.
- [ ] **Sleep mid-backup**: start a backup and close the lid / `pmset sleepnow`. On wake: the backup is reported as interrupted ("the Mac went to sleep"), no error notification, and within about 20 s of wake a due backup starts again by itself. While a backup is running and the Mac is idle, the Mac does not go to sleep by itself.
- [ ] **Device unplugged during sleep**: start a backup, sleep the Mac, unplug the phone, wake: no backup is attempted against the missing phone and no retry delay appears; plug it in again and the backup starts right away.
- [ ] **Quit mid-backup**: menu → Quit (and also ⌘Q, and a logout/restart as a second check). The app stops the backup first (the quit may take up to ~25 s), the phone's sync indicator disappears, no `*.ibh-part` files remain, and Finder still shows the previous backup. Reopen the app: the interrupted run is not counted as a success or a failure.
- [ ] **Finder syncing at the same time**: start a backup in Finder, then "Back up now" here: the row says "Device busy (Finder or another app is syncing)", Finder's backup is **not** disturbed. The reverse (Finder started while we run) must not corrupt anything either. Later the scheduler retries.
- [ ] **Disk full**: make the Mac's free space small (e.g. fill a disk image's worth, or test with a small volume). The app refuses to start under about 200 MB free with "the Mac's disk is full"; with less space than the backup needs the device stops with the same message. No partial files remain, the old backup is untouched.
- [ ] **Forget device**: unplugged device → Settings → Forget: its row and settings disappear, its backup folder is untouched. Plug it in again: it comes back with default settings (automatic backups off).

## 7. Launch at login and settings

- [ ] Settings → General → "Launch at login" on: log out and in (or restart): the menu-bar icon is back without opening the app. If macOS asks for approval, System Settings → General → Login Items shows the app.
- [ ] Turn it off: it no longer starts at login.
- [ ] Settings persist across restarts (`~/Library/Application Support/iPhoneBackupHelper/settings.json`).
- [ ] Notification toggles (started / needs passcode / finished / failed) each work.

## 8. Offline

- [ ] Run the firewall procedure in `docs/OFFLINE.md` for USB and Wi-Fi. Zero non-local connections.

## Reporting

For every failed item: macOS and iOS versions, USB or Wi-Fi, encrypted or not, the relevant part of the log (menu → Show Log; it contains no passwords and shortens UDIDs), and what the menu said.

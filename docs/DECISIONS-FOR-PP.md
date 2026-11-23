# Decisions for pp (smallest reasonable choices made along the way)

## M1
- **libimobiledevice pinned to master (60bf03b, 2026-11-18)**, not the 1.4.0 tag, for current-iOS support. Master requires `libtatsu` (which pulls in libcurl, i.e. network code) only for its CLI tools. We build no tools, and `build-deps.sh` removes the libtatsu configure check. No libcurl/libtatsu ships. Documented in `Contents/Resources/Licenses/VERSIONS.txt`.
- **TLS: OpenSSL 3.5.9 built static** and linked into libimobiledevice, so only four dylibs ship (libplist, libimobiledevice-glue, libusbmuxd, libimobiledevice).
- **Device discovery polls** `idevice_get_device_list_extended` every 2 s (attach/detach events are derived from the diff) instead of `idevice_events_subscribe`. It is simpler and gives USB and Wi-Fi entries per UDID. Can be swapped for events later without UI changes.
- **Reading a device that was never paired** makes libimobiledevice's handshake request pairing, so the iPhone shows its "Trust This Computer?" dialog. We retry only every 30 s while the device is untrusted.
- **Offline check and libc resolver symbols:** `getaddrinfo`/`gethostbyname` are imported by libimobiledevice(-glue)'s generic socket helpers, so the check does not ban them at symbol level. It bans HTTP/URL-loading/curl/Sparkle/CFNetwork/Network.framework linkage and symbols, plus the same APIs in our sources. Real proof is the firewall test planned for M4 (`docs/OFFLINE.md`).
- **Full Disk Access detection:** try to list `MobileSync/Backup`. If it doesn't exist yet, probe `~/Library/Safari` as a TCC indicator. After granting FDA, macOS usually requires restarting the app, which the UI says.
- **Product names:** table covers iPhones (6s to 17 / Air) and iPod touch 7; iPads show just "iPad" for now.
- **Ad-hoc signed** app (`codesign -s -`), so users must right-click → Open the first time.

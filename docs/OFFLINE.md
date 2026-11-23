# Offline verification

iPhone Backup Helper must never send a packet to the internet. This page lists what the app does and doesn't do on the network, what CI checks automatically, and how to **prove it on a real Mac** with a firewall.

## What the app talks to

| Peer | How | Why |
|---|---|---|
| `/var/run/usbmuxd` | Unix domain socket (local) | Apple's device daemon. List devices, connect to an iPhone over USB. |
| The iPhone on the LAN | TCP to the address usbmuxd reports (Wi-Fi backups only) | Only after pairing and "Show this iPhone when on Wi-Fi" in Finder. Link-local, RFC 1918 or IPv6 unique-local addresses only (see below). |
| Nothing else | | No update check, analytics, crash reporting, remote config, DNS lookups of our own. |

The macOS "Local Network" prompt may appear for Wi-Fi backups. That permission covers the LAN only.

## Hardening in code

- **No networking API in our sources.** `URLSession`, `URLRequest`, `NWConnection`, `CFHTTP`, WebKit, and any `http(s)://` literal are banned (CI check below).
- **Local-address guard** (`LocalAddressPolicy`, `NativeDeviceBackend.connectionIsLocal`). libimobiledevice opens a TCP connection straight to the sockaddr that usbmuxd reports for a Wi-Fi device. Before every device connection (discovery reads and backups) we list the device again and refuse unless the connection is USB (through usbmuxd) or every network address of that device is loopback, link-local (`169.254/16`, `fe80::/10`), RFC 1918 (`10/8`, `172.16/12`, `192.168/16`) or IPv6 ULA (`fc00::/7`). IPv4-mapped IPv6 is judged by its IPv4 part. A device with any other address is dropped from the list, and an unknown address family counts as refused. Unit-tested.
- **No redirect of the device service.** libusbmuxd reads `USBMUXD_SOCKET_ADDRESS` (a `host:port` or socket path) from the environment. `OfflineGuard.sanitizeEnvironment()` removes it at launch, before any library call, so a stray variable can't point the app at a remote muxer.
- **Bundled libraries** are built without libcurl, libtatsu, ideviceactivation, Python bindings or any CLI tool. OpenSSL is linked statically into libimobiledevice and is used only for the TLS session with the phone's lockdownd. `libimobiledevice` and `libusbmuxd` do import `getaddrinfo`/`gethostbyname` in their generic socket helpers; the app never gives them a host name (UDIDs and sockaddrs only). The firewall test below is the proof for that.
- **Notifications, login item, settings, logs** are local files and system APIs. Logs go to `~/Library/Logs/iPhoneBackupHelper/`; nothing is uploaded. Backup folders are only read and written locally.

## What CI checks (`scripts/check-offline.sh`, every push)

1. No Mach-O in the app bundle links CFNetwork, Network.framework, WebKit, libcurl, nghttp, Sparkle or telemetry SDKs, or imports `NSURLSession`/`CFHTTP*`/`curl_*` symbols or Swift `URLSession`/`URLRequest`/`NWConnection` symbols.
2. No file in the bundle is named like curl, ideviceactivation, Sparkle or tatsu.
3. No source file uses the networking APIs above or contains an `http(s)://` URL outside comments.

This is static evidence. It can't see what libc or the bundled C libraries do at run time, which is why the firewall test exists.

## Firewall verification (do this once per release, on a real Mac)

Goal: during discovery, battery polling and a full backup (USB **and** Wi-Fi), there are **zero** connections to non-local addresses and zero DNS requests.

Setup: install the app as in the README, grant Full Disk Access, pair an iPhone, enable "Show this iPhone when on Wi-Fi" in Finder. Quit Finder-based syncs. Use a fresh login session if possible, so other apps' traffic is easy to tell apart.

### Option A: LuLu (free, https://objective-see.org/products/lulu.html)

1. Install LuLu and finish its setup. In LuLu's Preferences: **uncheck** "Allow Apple programs" and "Allow installed applications" (otherwise those connections are allowed silently and not logged), and set the mode to normal (alert on every new connection).
2. Launch iPhone Backup Helper. Plug the iPhone in over USB and run "Back up now". Unplug, then repeat over Wi-Fi.
3. **Expected: LuLu shows no alert for iPhone Backup Helper at all.** USB backups never use the network stack; Wi-Fi backups go to a LAN address, and LuLu only filters outbound connections it sees from the app. If LuLu raises an alert, check the remote address: a `192.168.x.x`/`10.x.x.x`/`172.16-31.x.x`/`169.254.x.x`/`fe80::`/`fd..`/`fc..` address is the phone and is fine (note it in the report), anything else is a **failure**.
4. As a negative control, click "Block" if prompted, and confirm backups over USB still work. That shows the app doesn't depend on the internet.
5. Open LuLu's rule list and confirm there is no rule for iPhone Backup Helper pointing to a public address.

### Option B: Little Snitch (commercial, https://www.obdev.at/littlesnitch)

1. Create a profile with "Silent mode: Deny" and no rules allowing iPhone Backup Helper.
2. Run the same USB and Wi-Fi sessions as above.
3. Open **Little Snitch → Network Monitor**, filter by `iPhone Backup Helper`. **Expected:** no connection to any non-local address and no DNS (port 53/mDNS to unicast resolvers) traffic from the process. Wi-Fi backups may show a TCP connection to the phone's LAN address on port 62078 (lockdownd) and the mobilebackup2 port. Only the phone's LAN address is acceptable.
4. Silent-mode "Deny" must not break USB backups.

### Option C: pf (built in, no extra software)

This blocks everything the app could send to the internet at the packet filter and counts the attempts. It needs admin rights.

```sh
# 1. Rule file: log and drop anything that leaves the Mac for a non-local address.
sudo tee /etc/pf.anchors/ibh-offline-test >/dev/null <<'RULES'
local4 = "{ 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4 }"
local6 = "{ ::1, fe80::/10, fc00::/7, ff00::/8 }"
block drop out log quick inet  from any to ! $local4
block drop out log quick inet6 from any to ! $local6
RULES

# 2. Load it into the main ruleset (adds the anchor if missing) and enable pf.
grep -q ibh-offline-test /etc/pf.conf || \
  printf 'anchor "ibh-offline-test"\nload anchor "ibh-offline-test" from "/etc/pf.anchors/ibh-offline-test"\n' | sudo tee -a /etc/pf.conf >/dev/null
sudo pfctl -f /etc/pf.conf && sudo pfctl -e

# 3. Watch what pf drops (separate terminal), then run USB and Wi-Fi backups.
sudo tcpdump -n -e -ttt -i pflog0

# 4. Afterwards: counters, then remove the test rules again.
sudo pfctl -a ibh-offline-test -s rules -v
sudo pfctl -d
sudo sed -i '' '/ibh-offline-test/d' /etc/pf.conf
```

Because pf sees all processes, other apps' blocked packets also show up in `pflog0`. Quit browsers, mail and sync clients first, and check the process with `sudo lsof -nP -i -a -c iPhoneBackupHelper` while a backup runs.

**Expected:** a successful USB backup and a successful Wi-Fi backup, and no entries in `pflog0` caused by iPhone Backup Helper (check the PID against `lsof`).

### Extra checks (any option)

```sh
# Sockets of the app while it runs and during a backup: only the usbmuxd Unix socket and, for Wi-Fi, the phone's LAN address.
sudo lsof -nP -a -c iPhoneBackupHelper -i
lsof -nP -a -c iPhoneBackupHelper -U | grep usbmuxd

# Linked libraries and imports of the shipped binaries (should list no CFNetwork/curl/WebKit):
otool -L "/Applications/iPhone Backup Helper.app/Contents/MacOS/iPhoneBackupHelper"
for f in "/Applications/iPhone Backup Helper.app/Contents/Frameworks/"*.dylib; do echo "== $f"; otool -L "$f"; done
```

### What to record

In the release notes or PR: macOS version, firewall tool and version, USB and Wi-Fi result (pass/fail), any alert with its remote address. A single unexplained non-local connection is a release blocker.

## Out of scope (not our traffic)

Gatekeeper's first-launch check, the iPhone's own communication with Apple, and Finder or other apps running at the same time.

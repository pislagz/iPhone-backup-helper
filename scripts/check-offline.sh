#!/usr/bin/env bash
# Offline guard. Fails when the app (or its bundled libraries) could talk to the internet:
#   1. no Mach-O in the bundle links networking/updater/HTTP libraries or imports HTTP symbols
#   2. no source file uses URLSession / URLRequest / NWConnection / CFNetwork HTTP APIs
#      or contains an http(s):// URL outside comments
# Usage: scripts/check-offline.sh [path/to/App.app]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/dist/iPhone Backup Helper.app}"
fail=0
bad() { echo "OFFLINE CHECK FAILED: $*" >&2; fail=1; }

# Frameworks/dylibs that must never be linked.
FORBIDDEN_LIBS='libcurl|CFNetwork|Network\.framework|NetworkExtension|Sparkle|libnghttp|libssh|WebKit|Crashlytics|Firebase|Sentry|Mixpanel|Amplitude|Telemetry'
# Undefined symbols that indicate HTTP / URL loading / sockets to arbitrary hosts.
FORBIDDEN_SYMS='NSURLSession|NSURLConnection|NSURLRequest|CFHTTP|CFURLConnection|CFReadStreamCreateForHTTPRequest|_curl_|nw_connection_create|nw_endpoint_create_host'
# Note: libc name resolution (getaddrinfo/gethostbyname) is imported by libimobiledevice(-glue)'s generic
# socket helpers and can't be banned at the symbol level; the app only hands them usbmuxd/UDIDs. The
# runtime firewall test (docs/OFFLINE.md, M4) is the proof there.

if [[ ! -d "$APP" ]]; then bad "app bundle not found: $APP"; fi

if [[ -d "$APP" ]]; then
  while IFS= read -r -d '' f; do
    file "$f" | grep -q 'Mach-O' || continue
    deps="$(otool -L "$f" | grep -E '^[[:space:]]' | awk '{print $1}')"
    if echo "$deps" | grep -Eqi "$FORBIDDEN_LIBS"; then
      bad "$f links a forbidden library:"; echo "$deps" | grep -Ei "$FORBIDDEN_LIBS" >&2
    fi
    # Only inspect the arm64 slice (x86_64 is identical modulo arch).
    syms="$(nm -u -arch arm64 "$f" 2>/dev/null || nm -u "$f" 2>/dev/null)"
    if echo "$syms" | grep -Eq "$FORBIDDEN_SYMS"; then
      bad "$f imports forbidden symbols:"; echo "$syms" | grep -E "$FORBIDDEN_SYMS" >&2
    fi
    # Swift symbol mangling of Foundation's networking types.
    if echo "$syms" | grep -Eq 'URLSession|URLRequest|NWConnection|NWEndpoint'; then
      bad "$f references URLSession/URLRequest/NWConnection:"; echo "$syms" | grep -E 'URLSession|URLRequest|NWConnection|NWEndpoint' >&2
    fi
  done < <(find "$APP" -type f -print0)
  # Bundled ideviceactivation / curl must not exist at all.
  if find "$APP" \( -iname '*curl*' -o -iname '*ideviceactivation*' -o -iname '*sparkle*' -o -iname '*tatsu*' \) | grep -q .; then
    bad "forbidden file in bundle:"; find "$APP" \( -iname '*curl*' -o -iname '*ideviceactivation*' -o -iname '*sparkle*' -o -iname '*tatsu*' \) >&2
  fi
fi

# Source scan (comment lines are ignored for the URL rule).
SRC_DIRS=("$ROOT/Sources")
if grep -rnE 'URLSession|URLRequest|NWConnection|NWEndpoint|CFHTTP|NSURLConnection|WKWebView|import Network|import WebKit' --include='*.swift' --include='*.m' --include='*.c' --include='*.h' "${SRC_DIRS[@]}"; then
  bad "network API used in sources (see above)"
fi
if grep -rnE 'https?://' --include='*.swift' --include='*.m' --include='*.c' --include='*.h' "${SRC_DIRS[@]}" | grep -Ev ':[0-9]+:[[:space:]]*(//|\*|/\*)'; then
  bad "http(s) URL in non-comment source (see above)"
fi

if [[ $fail -eq 0 ]]; then echo "offline check passed"; fi
exit $fail

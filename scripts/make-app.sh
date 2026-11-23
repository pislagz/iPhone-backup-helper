#!/usr/bin/env bash
# Assembles dist/iPhone Backup Helper.app (universal, ad-hoc signed) and a zip.
# Requires vendor/ (scripts/build-deps.sh) and the Swift toolchain.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VENDOR="$ROOT/vendor"
DIST="$ROOT/dist"
APP_NAME="iPhone Backup Helper"
EXEC_NAME="iPhoneBackupHelper"
APP="$DIST/$APP_NAME.app"
VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${APP_BUILD:-1}"
MIN_MACOS=13.0

[[ -f "$VENDOR/.complete" ]] || { echo "vendor/ missing: run scripts/build-deps.sh first" >&2; exit 1; }

rm -rf "$DIST"; mkdir -p "$DIST"

# One build per architecture (plain SwiftPM build system), then lipo.
bins=()
for arch in arm64 x86_64; do
  scratch="$ROOT/.build-$arch"
  swift build -c release --product "$EXEC_NAME" \
    --triple "$arch-apple-macosx$MIN_MACOS" --scratch-path "$scratch"
  bin_dir="$(swift build -c release --triple "$arch-apple-macosx$MIN_MACOS" --scratch-path "$scratch" --show-bin-path)"
  bins+=("$bin_dir/$EXEC_NAME")
done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/$EXEC_NAME"

# Bundled libraries: real files only (install names are @rpath/<versioned file>).
for f in "$VENDOR/lib/"*.dylib; do
  [[ -L "$f" ]] || cp "$f" "$APP/Contents/Frameworks/"
done
cp -R "$VENDOR/licenses/." "$APP/Contents/Resources/Licenses/"
[[ -f "$ROOT/LICENSE" ]] && cp "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/LICENSE-iPhoneBackupHelper.txt" || true

# rpaths: drop the dev-time absolute path, make sure the bundle one exists.
EXE="$APP/Contents/MacOS/$EXEC_NAME"
install_name_tool -delete_rpath "$VENDOR/lib" "$EXE" 2>/dev/null || true
otool -l "$EXE" | grep -q "@executable_path/../Frameworks" || install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE"
if otool -l "$EXE" | grep -q "$VENDOR"; then echo "dev rpath still present in executable" >&2; exit 1; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
  <key>CFBundleIdentifier</key><string>io.github.pislagz.iphonebackuphelper</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>iPhone Backup Helper talks to your iPhone or iPad over your local network (Wi-Fi) to back it up to this Mac. It never connects to the internet.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

# Ad-hoc signing: libraries first, then the app.
for f in "$APP/Contents/Frameworks/"*.dylib; do codesign --force -s - "$f"; done
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"

# The deliverable zip: the app plus a short INSTALL.txt (ditto keeps modes, symlinks and signatures).
STAGE="$DIST/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
cat > "$STAGE/INSTALL.txt" <<'TXT'
iPhone Backup Helper - install

1. Move "iPhone Backup Helper.app" to /Applications.
2. Right-click the app > Open > Open (once; the app is ad-hoc signed, not notarized).
   If macOS still refuses: System Settings > Privacy & Security > "Open Anyway".
3. System Settings > Privacy & Security > Full Disk Access: add the app and switch it on,
   then quit and reopen the app.
4. Connect the iPhone and tap "Trust" on it.
5. For Wi-Fi backups: in Finder select the iPhone and tick "Show this iPhone when on Wi-Fi".

Licenses of the bundled libraries: iPhone Backup Helper.app/Contents/Resources/Licenses/
Full documentation: README.md in the source repository.
TXT
(cd "$STAGE" && ditto -c -k . "$DIST/iPhone-Backup-Helper.zip")
rm -rf "$STAGE"
echo "built: $APP"
lipo -archs "$EXE"
otool -L "$EXE"

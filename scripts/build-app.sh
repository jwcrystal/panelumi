#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
APP="build/SwitchDeck.app"

# The version has one source, VERSION. scripts/check-version.sh holds the
# rules. Both bundle keys take the same X.Y.Z string: Apple allows a version of
# one to three period-separated integers as CFBundleVersion, and every updater
# that reads it (Sparkle included) compares the parts as numbers, so 0.9.100
# sorts above 0.9.99 without a hand-counted build number.
./scripts/check-version.sh
VERSION="$(tr -d '[:space:]' < VERSION)"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product SwitchDeck

BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)/SwitchDeck"
if [ ! -x "$BIN" ]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SwitchDeck"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Localisation: every `Resources/<lang>.lproj` ships as-is, because the strings
# are looked up in Bundle.main. English needs no file: the literals in the
# source are the fallback.
for lproj in Resources/*.lproj; do
  [ -d "$lproj" ] || continue
  cp -R "$lproj" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>SwitchDeck</string>
    <key>CFBundleExecutable</key>
    <string>SwitchDeck</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.jwcrystal.switchdeck</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hant</string>
    </array>
    <key>CFBundleName</key>
    <string>SwitchDeck</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>__VERSION__</string>
    <key>CFBundleVersion</key>
    <string>__VERSION__</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>SwitchDeck uses System Events to change appearance and other system settings.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>SwitchDeck records audio when you start Recording from its menu.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

sed -i '' -e "s/__VERSION__/$VERSION/g" "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing"
# A certificate identity keeps the designated requirement stable across builds,
# so macOS keeps the Accessibility grant. Falls back to ad-hoc (CDHash-based,
# which loses permission on every rebuild) when the identity is missing.
#
# Every build uses the hardened runtime and the entitlements file, so local
# builds behave like notarized ones. Notarization also needs a secure
# timestamp: set TIMESTAMP=1 (needs network) for release builds; local builds
# skip it to stay fast and offline.
SIGN_IDENTITY="${SIGN_IDENTITY:-SwitchDeck Local Signing}"
ENTITLEMENTS="Resources/SwitchDeck.entitlements"
SIGN_FLAGS=(--force --options runtime --entitlements "$ENTITLEMENTS")
if [ "${TIMESTAMP:-0}" = "1" ]; then
  SIGN_FLAGS+=(--timestamp)
else
  SIGN_FLAGS+=(--timestamp=none)
fi
if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$APP"
  echo "    signed with: $SIGN_IDENTITY"
else
  codesign "${SIGN_FLAGS[@]}" --sign - "$APP"
  echo "    signed ad-hoc (run scripts/setup-signing.sh for a stable identity)"
fi
codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
codesign -d -r- "$APP" 2>&1 | grep designated | sed 's/^/    /'
codesign -dv "$APP" 2>&1 | grep -E '^CodeDirectory' | sed 's/^/    /'

echo "==> Built $APP"
echo "    open $APP"

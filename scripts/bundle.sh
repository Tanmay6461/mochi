#!/bin/bash
# Builds NotchPet.app so macOS permissions (Accessibility, Automation) belong to NotchPet,
# not to whichever terminal launched it. Usage: scripts/bundle.sh [--open]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="build/NotchPet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NotchPet "$APP/Contents/MacOS/NotchPet"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.notchpet.app</string>
    <key>CFBundleName</key><string>NotchPet</string>
    <key>CFBundleExecutable</key><string>NotchPet</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>NotchPet switches you back to the terminal tab where your Claude session is running.</string>
</dict>
</plist>
PLIST

# Sign with a fixed local certificate if you've made one (see README), so macOS keeps
# Accessibility/Automation permissions across rebuilds. Otherwise fall back to ad-hoc
# signing, which changes every build and makes macOS forget the permissions.
IDENTITY="NotchPet Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with \"$IDENTITY\" (permissions survive rebuilds)"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1
    echo "Ad-hoc signed: macOS will forget Accessibility after this rebuild (see README: fixed signing)"
fi
echo "Built $APP"

if [ "${1:-}" = "--open" ]; then
    pkill -x NotchPet 2>/dev/null || true
    sleep 0.5
    open "$APP"
fi

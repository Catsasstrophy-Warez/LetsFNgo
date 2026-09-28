#!/bin/bash
# Builds Nexus for iOS 27 and installs it on the iPhone connected to this Mac.
#
#   scripts/install-on-iphone.sh [TEAM_ID]
#
# Needs Xcode 27, signed in to your Apple ID (Xcode → Settings → Accounts;
# a free Apple ID works, the app then expires after 7 days). The team ID is
# found from your Apple Development certificate when you don't pass one.
# Bundle IDs end in your team ID; set BUNDLE_ID_PREFIX (e.g.
# com.yourname.nexus) to change the part before it.
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

say "Checking Xcode"
xcodebuild -version | head -1
major=$(xcodebuild -version | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
[ "${major:-0}" -ge 27 ] || fail "Nexus needs Xcode 27 or later (iOS 27 SDK). Install it from the App Store or developer.apple.com."

TEAM_ID="${1:-${TEAM_ID:-}}"
if [ -z "$TEAM_ID" ]; then
    TEAM_ID=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)
fi
[ -n "$TEAM_ID" ] || fail "No team ID found. Sign in with your Apple ID in Xcode → Settings → Accounts, click Manage Certificates → + → Apple Development, then run this again (or pass your team ID: scripts/install-on-iphone.sh ABCDE12345)."
echo "Team: $TEAM_ID"

say "Finding your iPhone"
devices_json=$(mktemp)
xcrun devicectl list devices --json-output "$devices_json" >/dev/null
DEVICE=$(python3 - "$devices_json" <<'EOF'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
phones = [d for d in devices
          if d.get("hardwareProperties", {}).get("platform") == "iOS"
          and d.get("connectionProperties", {}).get("pairingState") == "paired"]
# Prefer the one that's connected right now.
phones.sort(key=lambda d: d.get("connectionProperties", {}).get("tunnelState") != "connected")
if phones:
    d = phones[0]
    print(d["identifier"], d.get("hardwareProperties", {}).get("udid", ""), d.get("deviceProperties", {}).get("name", "iPhone"), sep="|")
EOF
)
rm -f "$devices_json"
[ -n "$DEVICE" ] || fail "No paired iPhone. Connect it with a cable, unlock it, tap Trust, and turn on Developer Mode (Settings → Privacy & Security → Developer Mode), then run this again."
IFS='|' read -r DEVICE_ID DEVICE_UDID DEVICE_NAME <<<"$DEVICE"
echo "Device: $DEVICE_NAME"

say "Generating the Xcode project"
command -v xcodegen >/dev/null || { command -v brew >/dev/null || fail "Install Homebrew (brew.sh) or XcodeGen first."; brew install xcodegen; }
spec=project.yml
if [ -n "${BUNDLE_ID_PREFIX:-}" ]; then
    # A copy beside project.yml, so its relative paths still resolve.
    spec=project.local.yml
    sed "s/com\.catsasstrophy\.nexus/$BUNDLE_ID_PREFIX/g" project.yml >"$spec"
fi
xcodegen generate --spec "$spec" --project . --quiet

say "Metal toolchain (first run only)"
xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -qi "installed" || xcodebuild -downloadComponent MetalToolchain

say "Building for iOS 27 (the first build takes a few minutes)"
build=build/device
# Building for this phone (its UDID) lets automatic signing register it.
destination="generic/platform=iOS"
[ -n "$DEVICE_UDID" ] && destination="id=$DEVICE_UDID"
xcodebuild build -project Nexus.xcodeproj -scheme NexusApp -configuration Debug \
    -destination "$destination" -derivedDataPath "$build" \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -quiet
app="$build/Build/Products/Debug-iphoneos/Nexus.app"
[ -d "$app" ] || fail "The build finished but $app is missing."

say "Installing on $DEVICE_NAME"
xcrun devicectl device install app --device "$DEVICE_ID" "$app"
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")

say "Launching"
if ! xcrun devicectl device process launch --device "$DEVICE_ID" "$bundle"; then
    echo "If the phone says \"Untrusted Developer\": Settings → General → VPN & Device Management → your Apple ID → Trust, then open Nexus."
fi
say "Done. Nexus is on $DEVICE_NAME."

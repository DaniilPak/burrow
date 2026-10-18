#!/bin/zsh
# Builds Burrow.app and burrowctl into ./build, signed with the virtualization entitlement.
# SIGN_IDENTITY defaults to ad-hoc ("-"), which is enough to run on this Mac.
set -euo pipefail
cd "${0:A:h}/.."

CONFIG=${CONFIG:-release}
IDENTITY=${SIGN_IDENTITY:--}
OUT=build
APP="$OUT/Burrow.app"

swift build -c "$CONFIG" --product Burrow
swift build -c "$CONFIG" --product burrowctl
BIN=$(swift build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/Burrow" "$APP/Contents/MacOS/Burrow"
[[ -f Support/AppIcon.icns ]] && cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/burrowctl" "$OUT/burrowctl"

# burrowctl builds configurations too, so it carries the same entitlement.
codesign --force --options runtime --entitlements Support/Burrow.entitlements --sign "$IDENTITY" "$OUT/burrowctl"
codesign --force --options runtime --entitlements Support/Burrow.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP and $OUT/burrowctl"

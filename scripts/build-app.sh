#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
[[ -f "$root/.env" ]] && source "$root/.env"
swift build --package-path "$root" -c release

app="$root/.build/Scribe.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/Scribe" "$app/Contents/MacOS/Scribe"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$root/Resources/Scribe.entitlements" \
    --sign "${CODE_SIGN_IDENTITY:?Set CODE_SIGN_IDENTITY to a codesigning identity, or - for ad-hoc}" \
    "$app"

"$root/scripts/smoke-test-app.sh" "$app"

print "$app"

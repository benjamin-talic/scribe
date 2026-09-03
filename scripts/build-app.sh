#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
swift build --package-path "$root" -c release

app="$root/.build/Scribe.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$root/.build/release/Scribe" "$app/Contents/MacOS/Scribe"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
codesign \
    --force \
    --options runtime \
    --entitlements "$root/Resources/Scribe.entitlements" \
    --sign "${CODE_SIGN_IDENTITY:--}" \
    "$app"

"$root/scripts/smoke-test-app.sh" "$app"

print "$app"

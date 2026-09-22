#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}

# An explicitly supplied CODE_SIGN_IDENTITY (e.g. `CODE_SIGN_IDENTITY=- ./scripts/build-app.sh`)
# must win over whatever the gitignored .env sets as a default, not be silently overwritten by it.
[[ -v CODE_SIGN_IDENTITY ]] && explicit_code_sign_identity=$CODE_SIGN_IDENTITY
[[ -f "$root/.env" ]] && source "$root/.env"
[[ -v explicit_code_sign_identity ]] && CODE_SIGN_IDENTITY=$explicit_code_sign_identity

swift build --package-path "$root" -c release

app="$root/.build/Scribe.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/Scribe" "$app/Contents/MacOS/Scribe"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

identity="${CODE_SIGN_IDENTITY:?Set CODE_SIGN_IDENTITY to a codesigning identity, or - for ad-hoc}"
# Ad-hoc signing has no real identity to timestamp against and doesn't need Apple's timestamp
# service; requesting one anyway waits on the network for no reason. A real identity still gets one.
timestamp_flag=(--timestamp)
[[ "$identity" == "-" ]] && timestamp_flag=(--timestamp=none)

codesign \
    --force \
    --options runtime \
    "${timestamp_flag[@]}" \
    --entitlements "$root/Resources/Scribe.entitlements" \
    --sign "$identity" \
    "$app"

"$root/scripts/smoke-test-app.sh" "$app"

print "$app"

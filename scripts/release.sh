#!/bin/zsh
# Build, notarize, staple and zip Scribe for a GitHub release.
# Usage: ./scripts/release.sh [notarytool keychain profile]
set -euo pipefail

root=${0:A:h:h}
profile=${1:-scribe}
app="$root/.build/Scribe.app"
zip="$root/.build/Scribe.zip"

CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:?Set CODE_SIGN_IDENTITY to a Developer ID Application identity}" \
    "$root/scripts/build-app.sh"

ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
ditto -c -k --keepParent "$app" "$zip"

print "$zip"

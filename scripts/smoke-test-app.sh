#!/bin/zsh
set -euo pipefail

app=${1:?usage: smoke-test-app.sh /path/to/Scribe.app}
plist="$app/Contents/Info.plist"

plutil -lint "$plist" >/dev/null
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" == "local.scribe.app" ]]
[[ "$(plutil -extract CFBundleIconFile raw -o - "$plist")" == "AppIcon" ]]
[[ -f "$app/Contents/Resources/AppIcon.icns" ]]
[[ "$(plutil -extract LSUIElement raw -o - "$plist")" == "true" ]]
plutil -extract NSMicrophoneUsageDescription raw -o - "$plist" >/dev/null
plutil -extract NSAudioCaptureUsageDescription raw -o - "$plist" >/dev/null
codesign --verify --deep --strict "$app"
entitled=$(codesign -d --entitlements :- "$app" 2>/dev/null \
    | plutil -extract 'com\.apple\.security\.device\.audio-input' raw -o - -)
[[ "$entitled" == "true" ]]

#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}

if [[ ${CODE_SIGN_IDENTITY:-} == "-" ]]; then
    print -u2 "Set CODE_SIGN_IDENTITY to a stable Apple Development or Developer ID identity."
    exit 1
fi

"$root/scripts/build-app.sh"

destination="${SCRIBE_INSTALL_DIR:-/Applications}/Scribe.app"
rm -rf "$destination"
cp -R "$root/.build/Scribe.app" "$destination"

print "$destination"

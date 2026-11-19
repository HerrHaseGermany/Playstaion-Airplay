#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?Pass the signed app path}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)"
identity="${CODE_SIGN_IDENTITY:--}"
staging="${PLAYLINK_DISTRIBUTION_DIR:-$HOME/Library/Developer/PlayLink/Distribution}/$version"
mkdir -p "$staging"
xcrun swiftc -parse-as-library -O -framework AppKit -framework CoreAudio \
    -target "$(uname -m)-apple-macos14.2" Setup/SetupMain.swift -o .build/PlaystationAirplaySetup
for mode in Install Uninstall; do
    helper="$staging/$mode Playstation Airplay.app"
    mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Resources"
    cp .build/PlaystationAirplaySetup "$helper/Contents/MacOS/Setup"
    cp .build/AppIcon.icns "$helper/Contents/Resources/AppIcon.icns"
    python3 - "$helper" "$mode" "$version" <<'PY'
import plistlib,sys
from pathlib import Path
helper,mode,version=sys.argv[1:]
info={
    'CFBundleIdentifier': 'de.raudzis.playlink.' + ('setup' if mode == 'Install' else 'uninstall'),
    'CFBundleName': mode + ' Playstation Airplay',
    'CFBundleExecutable': 'Setup', 'CFBundlePackageType': 'APPL',
    'CFBundleIconFile': 'AppIcon.icns',
    'CFBundleShortVersionString': version, 'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '14.2', 'NSHighResolutionCapable': True,
}
Path(helper,'Contents','Info.plist').write_bytes(plistlib.dumps(info))
PY
    if [ "$mode" = Install ]; then
        # Strip metadata only before copying signed payloads into the helper.
        xattr -cr "$helper"
        ditto --norsrc "$app" "$helper/Contents/Resources/Playstation Airplay.app"
        cp 'dist/Playstation Airplay Audio Output.pkg' "$helper/Contents/Resources/"
    else
        xattr -cr "$helper"
    fi
    codesign --force --sign "$identity" --options runtime --timestamp=none "$helper"
    codesign --verify --deep --strict --verbose=2 "$helper"
done
cp README.md CHANGELOG.md "$staging/"
ditto -c -k --keepParent --norsrc "$staging" "$PWD/dist/Playstation Airplay-$version.zip"
printf '\nTest release: %s\n' "$PWD/dist/Playstation Airplay-$version.zip"

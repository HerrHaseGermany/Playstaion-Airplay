#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
driver="$PWD/.build/driver/PlaystationAirplay.driver"
mkdir -p "$driver/Contents/MacOS" "$driver/Contents/Resources"
# Generate a branded copy while preserving Apple's original source and license.
python3 - <<'PY'
from pathlib import Path
source = Path('Driver/Vendor/NullAudio.c').read_text()
for old, new in {
    'com.apple.audio.NullAudio': 'de.raudzis.playlink.audio',
    'NullAudioBox_UID': 'de.raudzis.playlink.output.box',
    'NullAudioDevice_UID': 'de.raudzis.playlink.output',
    'NullAudioDevice_ModelUID': 'de.raudzis.playlink.output.model',
    'CFSTR("DeviceName")': 'CFSTR("Playstation Airplay")',
    'CFSTR("ManufacturerName")': 'CFSTR("Christian Raudzis")',
    'CFSTR("Null Box")': 'CFSTR("Playstation Airplay")',
    'CFSTR("Null Model")': 'CFSTR("Playstation Airplay")',
}.items():
    if old not in source: raise SystemExit('Vendor source changed: ' + old)
    source = source.replace(old, new)
Path('.build/driver/BrandedNullAudio.c').write_text(source)
wrapper = Path('Driver/PlaystationAirplay.c').read_text().replace('"Vendor/NullAudio.c"', '"BrandedNullAudio.c"')
Path('.build/driver/PlaystationAirplay.c').write_text(wrapper)
PY
xcrun clang -bundle -O2 -fblocks -arch arm64 -arch x86_64 -mmacosx-version-min=14.2 \
    -framework CoreAudio -framework CoreFoundation \
    .build/driver/PlaystationAirplay.c -o "$driver/Contents/MacOS/PlaystationAirplay"
cp Driver/Info.plist "$driver/Contents/Info.plist"
cp Driver/Vendor/LICENSE.txt "$driver/Contents/Resources/Apple-Sample-License.txt"
identity="${CODE_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
    identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
fi
identity="${identity:--}"
xattr -cr "$driver"
codesign --force --sign "$identity" --options runtime --timestamp=none "$driver"
codesign --verify --strict --verbose=2 "$driver"
mkdir -p dist
pkgbuild --root "$PWD/.build/driver/PlaystationAirplay.driver" \
    --install-location '/Library/Audio/Plug-Ins/HAL/PlaystationAirplay.driver' \
    --identifier de.raudzis.playlink.audio.pkg --version 0.1.0 \
    "$PWD/.build/driver/Component.pkg"
productbuild --distribution Driver/Distribution.xml --package-path .build/driver \
    "$PWD/dist/Playstation Airplay Audio Output.pkg"

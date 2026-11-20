#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

node -e 'const [a,b] = process.versions.node.split(".").map(Number); if (a < 22 || (a === 22 && b < 12)) throw Error("Node.js 22.12 or newer is required")'
bash scripts/build-driver.sh
bash scripts/build-icon.sh
npm ci --omit=dev
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
build_root="${PLAYLINK_BUILD_DIR:-$HOME/Applications}"
app="$build_root/Playstation Airplay.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/runtime" "$app/Contents/Resources/backend/bot"
cp "$binary_dir/PlayLink" "$app/Contents/MacOS/PlayLink"
cp scripts/Info.plist "$app/Contents/Info.plist"
cp .build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp 'dist/Playstation Airplay Audio Output.pkg' "$app/Contents/Resources/"
cp "$(command -v node)" "$app/Contents/Resources/runtime/node"
cp bot/bridge.mjs bot/pcm.mjs bot/audio.mjs bot/follow.mjs bot/shutdown.mjs "$app/Contents/Resources/backend/bot/"
cp package.json package-lock.json "$app/Contents/Resources/backend/"
rsync -a --delete node_modules/ "$app/Contents/Resources/backend/node_modules/"
# Finder may attach metadata after a previous launch; strip it from build output.
xattr -cr "$app"

# Use the same identity for the app, runtime and native voice dependency.
identity="${CODE_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
    identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
fi
identity="${identity:--}"
while IFS= read -r -d '' native; do
    codesign --force --sign "$identity" --options runtime --timestamp=none "$native"
done < <(find "$app/Contents/Resources/backend/node_modules" -type f \( -name '*.node' -o -name '*.dylib' \) -print0)
codesign --force --sign "$identity" --options runtime --timestamp=none \
    --entitlements scripts/node.entitlements.plist "$app/Contents/Resources/runtime/node"
codesign --force --sign "$identity" --options runtime --timestamp=none "$app"
codesign --verify --deep --strict --verbose=2 "$app"
"$app/Contents/Resources/runtime/node" "$app/Contents/Resources/backend/bot/bridge.mjs" --doctor
mkdir -p dist
ditto -c -k --keepParent --norsrc "$app" "$PWD/dist/Playstation Airplay.zip"
CODE_SIGN_IDENTITY="$identity" bash scripts/build-distribution.sh "$app"
printf '\nBuilt %s\n' "$app"

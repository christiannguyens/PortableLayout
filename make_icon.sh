#!/bin/zsh
# Builds Resources/AppIcon.icns (the Dock / Cmd-Tab icon).
#   ./make_icon.sh              use the built-in design (Tools/draw_icon.swift)
#   ./make_icon.sh my-pic.png   use your own square image (1024×1024 PNG/JPG works best)
# Then run ./build.sh to bake it into the app.
set -euo pipefail
cd "$(dirname "$0")"

TMP=$(mktemp -d)
SRC="$TMP/source.png"
if [[ $# -ge 1 ]]; then
    sips -s format png -z 1024 1024 "$1" --out "$SRC" >/dev/null
else
    swift Tools/draw_icon.swift "$SRC"
fi

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$SRC" Resources/AppIcon-preview.png
rm -rf "$TMP"
echo "Made Resources/AppIcon.icns — now run ./build.sh"

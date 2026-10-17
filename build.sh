#!/bin/zsh
# Builds PortableDash.app into ./build.   Usage:  ./build.sh          (build)
#                                                 ./build.sh install  (build + copy to ~/Applications)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/PortableDash.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
    Sources/*.swift -o "$APP/Contents/MacOS/PortableDash"

cp Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Ad-hoc sign so macOS can attach privacy permissions to the app.
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/PortableDash.app
    cp -R "$APP" ~/Applications/
    echo "Installed to ~/Applications/PortableDash.app"
fi

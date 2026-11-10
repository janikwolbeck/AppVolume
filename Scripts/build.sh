#!/bin/bash
# Baut AppVolume.app (ad hoc signiert) und AppVolume.dmg mit Programme-Verknüpfung.
# Benötigt nur die Xcode Command Line Tools (xcode-select --install); Xcode selbst ist nicht nötig.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="AppVolume"
MIN_MACOS="14.2"
BUILD="build"
APP="$BUILD/$NAME.app"
DMG="$BUILD/$NAME.dmg"

command -v swiftc >/dev/null || { echo "Fehler: swiftc nicht gefunden. Bitte 'xcode-select --install' ausführen." >&2; exit 1; }

echo "→ Kompiliere $NAME …"
rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -wmo -parse-as-library -swift-version 5 \
    -target "$(uname -m)-apple-macos$MIN_MACOS" \
    -o "$APP/Contents/MacOS/$NAME" \
    "$NAME"/*.swift

cp "$NAME/Info.plist" "$APP/Contents/Info.plist"
cp "$NAME/AppIcon.icns" "$APP/Contents/Resources/"
cp -R "$NAME"/*.lproj "$APP/Contents/Resources/"

echo "→ Signiere ad hoc …"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "→ Erzeuge $DMG …"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGING" -format UDZO -ov -quiet "$DMG"

echo "Fertig: $APP und $DMG"

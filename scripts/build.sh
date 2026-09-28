#!/bin/bash
# Builds NextUp.app, signs it, installs it to ~/Applications, and launches it.
# Pass --no-install to stop after building build/NextUp.app.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=NextUp
IDENTITY="NextUp Local Signing"
BUILD=build
APP="$BUILD/$NAME.app"
DEST="$HOME/Applications/$NAME.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$NAME"

mkdir -p "$BUILD"
if [ ! -f "$BUILD/AppIcon.icns" ]; then
  swiftc -O scripts/make-icon.swift -o "$BUILD/make-icon"
  "$BUILD/make-icon" "$BUILD/AppIcon.iconset"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# A stable identity keeps Full Disk Access and Calendar grants across rebuilds (see create-signing-identity.sh).
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "warning: '$IDENTITY' missing, signing ad-hoc. Privacy grants will reset on every rebuild." >&2
  echo "         Run scripts/create-signing-identity.sh once to fix that." >&2
  codesign --force --sign - "$APP"
fi

[ "${1:-}" = "--no-install" ] && { echo "Built $APP"; exit 0; }

pkill -x "$NAME" 2>/dev/null && sleep 0.5 || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed and launched $DEST"

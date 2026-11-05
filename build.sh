#!/bin/bash
# Build Pocket3Bar.app into ./build
#   ./build.sh            build only
#   ./build.sh --install  build, then copy to ~/Applications and register the pocket3bar:// link
# Signing: uses the "Pocket3Bar Local Signing" identity if it's in your keychain (create it
# once with scripts/make-signing-identity.sh) so macOS keeps the camera permission across
# rebuilds; otherwise signs ad-hoc, and macOS asks for camera access again after each build.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Pocket3Bar.app
RES="$APP/Contents/Resources/server"
IDENT="Pocket3Bar Local Signing"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"

echo "compiling uvcctl (USB helper)"
clang -O2 -o "$RES/uvcctl" server/uvcctl.c -framework IOKit -framework CoreFoundation
cp server/server.py server/panel.html "$RES/"

echo "compiling Pocket3Bar"
swiftc -O -swift-version 5 -parse-as-library -o "$APP/Contents/MacOS/Pocket3Bar" app/Pocket3Bar.swift
cp app/Info.plist "$APP/Contents/Info.plist"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENT\""; then
  SIGN="$IDENT"
else
  SIGN="-"
  echo "note: no '$IDENT' identity; signing ad-hoc (see scripts/make-signing-identity.sh)"
fi
codesign --force --sign "$SIGN" "$RES/uvcctl"
codesign --force --sign "$SIGN" "$APP"
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/Pocket3Bar.app"
  mkdir -p "$HOME/Applications"
  pkill -x Pocket3Bar 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  echo "installed $DEST"
fi

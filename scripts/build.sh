#!/bin/bash
# Builds "build/WallAero Engine.app" from the Swift package.
#
#   scripts/build.sh            universal app: Apple Silicon and Intel
#   scripts/build.sh --native   only for this Mac's processor; twice as fast, for development
#   scripts/build.sh --install  also copy the app to /Applications
#   scripts/build.sh --dist     also pack the app into dist/WallAeroEngine.zip, the download in the README
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="WallAero Engine"   # the bundle, as shown in Finder
EXECUTABLE="WallAeroEngine"  # the Swift product inside it; also names the archive
APP="build/$APP_NAME.app"
INSTALL=0
DIST=0
NATIVE=0
ARCH_FLAGS=(--arch arm64 --arch x86_64)

for argument in "$@"; do
    case "$argument" in
        --install) INSTALL=1 ;;
        --dist) DIST=1 ;;
        --native) NATIVE=1; ARCH_FLAGS=() ;;
        *) echo "Unknown option: $argument" >&2; exit 1 ;;
    esac
done

if [ "$DIST" -eq 1 ] && [ "$NATIVE" -eq 1 ]; then
    echo "--dist packs the universal app for every Mac; drop --native" >&2
    exit 1
fi

echo "→ Compiling…"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

if [ ! -f Resources/AppIcon.icns ]; then
    echo "→ Drawing the icon…"
    swift scripts/make-icon.swift Resources/AppIcon.icns
fi

echo "→ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

echo "→ Signing (ad hoc)…"
codesign --force --sign - --timestamp=none "$APP"

if [ "$DIST" -eq 1 ]; then
    echo "→ Packing dist/$EXECUTABLE.zip…"
    mkdir -p dist
    rm -f "dist/$EXECUTABLE.zip"
    # The signature lives in the bundle's files, so this Mac's extended attributes (provenance)
    # are left out; they would only add a __MACOSX folder to the archive.
    ditto -c -k --keepParent --norsrc --noextattr --noacl "$APP" "dist/$EXECUTABLE.zip"
fi

if [ "$INSTALL" -eq 1 ]; then
    echo "→ Installing to /Applications…"
    if pgrep -x "$EXECUTABLE" >/dev/null; then
        osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || pkill -x "$EXECUTABLE" || true
        sleep 1
    fi
    # The app was called AiWallpaper before. Its library and settings move over when the new
    # one first opens, so the copy this script installed under the old name can go.
    if [ -d "/Applications/AiWallpaper.app" ]; then
        echo "→ Removing the old /Applications/AiWallpaper.app…"
        pgrep -x AiWallpaper >/dev/null && { osascript -e 'quit app "AiWallpaper"' >/dev/null 2>&1 || pkill -x AiWallpaper || true; sleep 1; }
        rm -rf "/Applications/AiWallpaper.app"
    fi
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    APP="/Applications/$APP_NAME.app"
fi

echo "✓ $APP"

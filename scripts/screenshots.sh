#!/bin/bash
# Renders the README screenshots into docs/screenshots/en and docs/screenshots/ru from the built
# app, using your library and settings. The windows appear on screen for a few seconds while they
# are captured; the copy of WallAero Engine you are running is not affected.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/WallAero Engine.app"
[ -x "$APP/Contents/MacOS/WallAeroEngine" ] || scripts/build.sh --native

# shoot <language> <region format>: both are set for this run only, so numbers read "22.4 s" in
# English and "22,4 с" in Russian whatever this Mac's own settings are.
shoot() {
    mkdir -p "docs/screenshots/$1"
    "$APP/Contents/MacOS/WallAeroEngine" --screenshots "$PWD/docs/screenshots/$1" -AppleLanguages "($1)" -AppleLocale "$2"
}

shoot en en_US
shoot ru ru_RU

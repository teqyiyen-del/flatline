#!/bin/bash
# Builds dist/Flatline.dmg: the app next to an Applications shortcut, on the designed background.
# Run ./app/build.sh first. Needs dmgbuild: pip install dmgbuild
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
rm -f dist/Flatline.dmg
"${DMGBUILD:-dmgbuild}" -s app/dmg/settings.py -D app=app/build/Flatline.app Flatline dist/Flatline.dmg
echo "Built $(pwd)/dist/Flatline.dmg"

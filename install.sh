#!/bin/bash
# Builds NotchBlack, installs it to /Applications and opens it.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

pkill -x NotchBlack 2>/dev/null || true
sleep 0.5
rm -rf /Applications/NotchBlack.app
cp -R NotchBlack.app /Applications/
open /Applications/NotchBlack.app

echo "NotchBlack is installed and running. Look for its icon in the menu bar."

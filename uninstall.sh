#!/bin/bash
# Removes the hooks, status files and the app.
set -euo pipefail
cd "$(dirname "$0")"

./hooks/install-hooks.sh --uninstall
pkill -x Lantern 2>/dev/null || true
rm -rf /Applications/Lantern.app
defaults delete se.wishyouwerehere.lantern 2>/dev/null || true
echo "Lantern removed."

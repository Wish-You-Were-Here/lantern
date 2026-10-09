#!/bin/bash
# Installs the hooks and builds/installs the app in one step.
set -euo pipefail
cd "$(dirname "$0")"

command -v swiftc >/dev/null || { echo "swiftc not found. Run: xcode-select --install"; exit 1; }
command -v jq >/dev/null || { echo "jq not found (built in from macOS 15, otherwise: brew install jq)"; exit 1; }

./hooks/install-hooks.sh
./build.sh --install

#!/bin/bash
# Builds Peace from source and installs it. Pass --uninstall to remove it.
set -euo pipefail

repo="${PEACE_REPO:-https://gitlab.com/q_welpl/peacemusic.git}"

if [ -n "${PEACE_INSTALL_DIR:-}" ]; then
    dest="$PEACE_INSTALL_DIR"
elif [ -w /Applications ]; then
    dest=/Applications
else
    dest="$HOME/Applications"
fi

if [ "${1:-}" = "--uninstall" ]; then
    pkill -x PeaceMusic || true
    rm -rf "$dest/Peace.app"
    echo "Removed $dest/Peace.app"
    exit 0
fi

if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]; then
    echo "Peace needs macOS 26 or later." >&2
    exit 1
fi
if ! swift --version >/dev/null 2>&1; then
    echo "Swift not found. Install Xcode 26." >&2
    exit 1
fi

# Piped from curl there's no checkout next to this script.
script="${BASH_SOURCE[0]:-}"
if [ -n "$script" ] && [ -f "$(dirname "$script")/Package.swift" ]; then
    src="$(cd "$(dirname "$script")" && pwd)"
else
    src="$(mktemp -d)"
    trap 'rm -rf "$src"' EXIT
    git clone --quiet --depth 1 "$repo" "$src"
fi

"$src/scripts/build.sh"

mkdir -p "$dest"
pkill -x PeaceMusic || true
rm -rf "$dest/Peace.app"
ditto "$src/build/Peace.app" "$dest/Peace.app"
echo "Installed $dest/Peace.app"
open "$dest/Peace.app"

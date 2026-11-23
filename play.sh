#!/bin/sh
# Downloads the latest creakpad release and runs it.
#
#   curl -fsSL https://raw.githubusercontent.com/Benoitded/creakpad/main/play.sh | sh
#
# It installs one file, ~/.local/bin/creakpad. Delete that file to uninstall.
set -e

fail() {
    printf '\n  creakpad: %s\n\n' "$1" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "this runs on macOS only (it plays through a MacBook's trackpad)."

url="https://github.com/Benoitded/creakpad/releases/latest/download/creakpad.zip"
dest="$HOME/.local/bin"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "downloading creakpad…"
curl -fsSL "$url" -o "$tmp/creakpad.zip" \
    || fail "the download failed. Check your connection, or get it from github.com/Benoitded/creakpad/releases"
ditto -x -k "$tmp/creakpad.zip" "$tmp"
mkdir -p "$dest"
mv -f "$tmp/creakpad" "$dest/creakpad"
echo "installed ~/.local/bin/creakpad"

# Piped into sh, stdin is the script itself, so give creakpad the keyboard back.
"$dest/creakpad" "$@" </dev/tty

#!/bin/sh
# Builds creakpad as one program for Apple Silicon and Intel Macs.
#
#   ./build.sh            build ./creakpad (signed for this Mac only)
#   ./build.sh release    also sign it with your Developer ID, have Apple notarize it, and make
#                         dist/creakpad.zip, which runs on any Mac without security warnings
#
# Adapted from nospeaker's build.sh (MIT, github.com/os6/nospeaker).
set -e
mode="$1"
cd "$(dirname "$0")"

fail() {
    printf '\n  creakpad: %s\n\n' "$1" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "this builds on macOS only (it drives a Mac's trackpad)."

# /usr/bin/swiftc exists even without developer tools (it only offers to install them), so ask xcode-select.
{ xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null 2>&1; } || fail "Swift isn't installed. Install Apple's Command Line Tools:

    xcode-select --install

  then run ./build.sh again."

mkdir -p build
echo "building for Apple Silicon…"
swiftc -O -swift-version 5 -target arm64-apple-macos12 creakpad.swift -o build/creakpad-arm64 \
    || fail "the Apple Silicon build failed (errors above). Make sure Xcode or the Command Line Tools are up to date."
echo "building for Intel…"
swiftc -O -swift-version 5 -target x86_64-apple-macos13 creakpad.swift -o build/creakpad-x86_64 \
    || fail "the Intel build failed (errors above). Make sure Xcode or the Command Line Tools are up to date."

lipo -create build/creakpad-arm64 build/creakpad-x86_64 -output build/creakpad
codesign -s - -f build/creakpad 2>/dev/null
mv -f build/creakpad creakpad     # a rename, so a copy that's already running isn't disturbed
echo "built ./creakpad ($(lipo -archs creakpad)). Run it with: ./creakpad"

[ "$mode" = "release" ] || exit 0

# Release: Developer ID signature (with the hardened runtime Apple requires), then notarization.
# By its hash: a name with accents (Benoît) comes back garbled from the shell.
identity=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ { print $2; exit }')
[ -n "$identity" ] || fail "no Developer ID Application certificate in your keychain. Add one in Xcode:
  Settings > Accounts > your team > Manage Certificates > + > Developer ID Application,
  then run ./build.sh release again."

profile="${NOTARY_PROFILE:-creakpad}"
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 || fail "no saved notary sign-in called \"$profile\". Save one once (it asks for an app-specific password,
  made at account.apple.com > Sign-In and Security > App-Specific Passwords):

    xcrun notarytool store-credentials $profile --apple-id <your Apple ID> --team-id <your team ID>

  then run ./build.sh release again."

echo "signing with the Developer ID $identity…"
codesign --force --options runtime --timestamp --sign "$identity" creakpad
codesign --verify --strict creakpad

mkdir -p dist
rm -f dist/creakpad.zip
ditto -c -k --norsrc --noextattr creakpad dist/creakpad.zip    # the program alone, at the top of the zip

echo "sending to Apple for notarization (usually a minute or two)…"
xcrun notarytool submit dist/creakpad.zip --keychain-profile "$profile" --wait \
    || fail "notarization didn't pass. See why with: xcrun notarytool log <submission id> --keychain-profile $profile"

codesign --verify --strict -R="notarized" --check-notarization creakpad \
    || fail "Apple accepted it, but macOS can't confirm the notarization yet. Try again in a minute."
shasum -a 256 dist/creakpad.zip | sed 's|dist/||' > dist/creakpad.zip.sha256
echo "released: dist/creakpad.zip (+ .sha256), signed and notarized. Attach both to the GitHub release:

    gh release create v1.0 dist/creakpad.zip dist/creakpad.zip.sha256 --title v1.0"

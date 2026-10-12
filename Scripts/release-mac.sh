#!/bin/bash
#
# Builds the downloadable Caw Beta: signed with a Developer ID certificate,
# hardened runtime, packed in a .dmg, notarized by Apple and stapled.
# Maintainer only: it needs a "Developer ID Application" certificate in the
# login keychain and notarytool credentials saved under the profile name
# below (xcrun notarytool store-credentials caw-notary ...).
#
#   Scripts/release-mac.sh                 build, sign, notarize
#   Scripts/release-mac.sh --no-notarize   build and sign only (to test)
#
# Output: build/release/Caw-Beta-<version>.dmg and a .sha256 file.

set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE=caw-notary
notarize=1
[[ "${1:-}" == "--no-notarize" ]] && notarize=0

identity_line=$(security find-identity -v -p codesigning | grep -m1 '"Developer ID Application:' || true)
if [[ -z "$identity_line" ]]; then
    echo "No Developer ID Application certificate in the keychain." >&2
    exit 1
fi
identity=$(awk '{print $2}' <<<"$identity_line")
team=$(sed -E 's/.*\(([A-Z0-9]{10})\)".*/\1/' <<<"$identity_line")

if (( notarize )) && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "No notarytool credentials saved as \"$NOTARY_PROFILE\"." >&2
    exit 1
fi

derived=build/DerivedData
out=build/release
rm -rf "$derived" "$out"
mkdir -p "$out"

echo "── Building"
xcodebuild -project VoiceApp.xcodeproj -scheme "Caw Beta" -configuration Release-Beta \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" -quiet clean build \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
    ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=non-global \
    DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
    OTHER_SWIFT_FLAGS="\$(inherited) -file-prefix-map $PWD=." \
    OTHER_CFLAGS="\$(inherited) -ffile-prefix-map=$PWD=."

app="$derived/Build/Products/Release-Beta/Caw Beta.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")

echo "── Checking the signature"
codesign --verify --deep --strict "$app"
# (Captured first: grep -q stopping early would fail the pipe under pipefail.)
details=$(codesign -d --verbose=2 "$app" 2>&1)
grep -q 'flags=0x10000(runtime)' <<<"$details" || { echo "Hardened runtime is not on." >&2; exit 1; }
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null)
if grep -q get-task-allow <<<"$entitlements"; then
    echo "The app carries get-task-allow; Apple would refuse it." >&2
    exit 1
fi
# No build machine paths (home folder, user name) left in the app.
if LC_ALL=C grep -r -a -q "$HOME" "$app"; then
    echo "The app contains a path from this Mac ($HOME)." >&2
    exit 1
fi
# The beta never carries the personal edition's extras.
if [[ -e "$app/Contents/Resources/Home" ]]; then
    echo "The Home folder is in the app; it belongs to the personal edition only." >&2
    exit 1
fi

echo "── Packing"
dmg="$out/Caw-Beta-$version.dmg"
stage=$(mktemp -d "${TMPDIR:-/tmp}/caw-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Caw Beta.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Caw Beta" -srcfolder "$stage" -format UDZO -ov "$dmg"
codesign --sign "$identity" --timestamp "$dmg"

if (( notarize )); then
    echo "── Notarizing (Apple usually answers within a few minutes)"
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg"
fi

(cd "$out" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
echo "$dmg"

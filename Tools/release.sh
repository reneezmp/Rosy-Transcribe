#!/bin/bash
#
# Builds a release, zips it, signs it, and prints the appcast entry.
#
# Run on the M4. Publishing an update is then three steps:
#   1. ./Tools/release.sh
#   2. paste the printed <item> into appcast.xml, commit and push
#   3. create a GitHub release tagged v<version> and attach the zip
#
# Step 2 and 3 are both required. The appcast is what the app reads; the
# release is where the file it names actually lives.

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="RosyTranscribe.xcodeproj"
REPO="reneezmp/RosyTranscriber"
DERIVED="$(pwd)/.build/DerivedData"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die() { printf '\n\033[31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
say "Version"
# ---------------------------------------------------------------------------
settings="$(xcodebuild -project "$PROJECT" -target RosyTranscribe -showBuildSettings 2>/dev/null)"
SHORT="$(echo "$settings" | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')"
BUILD="$(echo "$settings" | awk -F' = ' '/ CURRENT_PROJECT_VERSION /{print $2; exit}')"
[ -n "$SHORT" ] && [ -n "$BUILD" ] || die "Could not read the version from the project."
echo "Short version: $SHORT"
echo "Build:         $BUILD"

if git tag --list | grep -qx "v$SHORT"; then
    die "v$SHORT is already tagged. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION first —
       Sparkle orders updates by CFBundleVersion, so a build that does not
       increase is a build nobody will ever be offered."
fi

# ---------------------------------------------------------------------------
say "Building"
# ---------------------------------------------------------------------------
./build.sh

APP="build/RosyTranscribe.app"
[ -d "$APP" ] || die "build.sh did not produce $APP"

ZIP="build/RosyTranscribe-$SHORT.zip"
rm -f "$ZIP"
# ditto, not zip: an .app is a bundle with symlinks and permissions that a
# plain zip mangles.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
LENGTH="$(stat -f%z "$ZIP")"
echo "Zipped: $ZIP ($LENGTH bytes)"

# ---------------------------------------------------------------------------
say "Signing"
# ---------------------------------------------------------------------------
SIGN_TOOL="$(find "$DERIVED/SourcePackages/artifacts" -name sign_update -type f 2>/dev/null | head -1 || true)"
if [ -z "$SIGN_TOOL" ]; then
    SIGN_TOOL="$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f 2>/dev/null | head -1 || true)"
fi
[ -n "$SIGN_TOOL" ] || die "Could not find Sparkle's sign_update tool.
       It arrives with the Sparkle package; build once in Xcode first.
       First time only, generate the keypair with the generate_keys tool
       beside it, and put the printed public key in the project's
       INFOPLIST_KEY_SUPublicEDKey build setting."

SIGNATURE="$("$SIGN_TOOL" "$ZIP" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[ -n "$SIGNATURE" ] || die "sign_update produced no signature. Is the private key in the login Keychain?"

# ---------------------------------------------------------------------------
say "Paste this into appcast.xml, newest first"
# ---------------------------------------------------------------------------
cat <<XML

    <item>
      <title>$SHORT</title>
      <pubDate>$(date -u +"%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$SHORT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/$REPO/releases/download/v$SHORT/RosyTranscribe-$SHORT.zip"
        length="$LENGTH"
        type="application/octet-stream"
        sparkle:edSignature="$SIGNATURE" />
    </item>

XML

say "Then"
echo "  1. paste the block above into appcast.xml, commit, push to main"
echo "  2. create the release and attach the zip:"
echo "       gh release create v$SHORT $ZIP --title $SHORT"
echo "     (or do it in the browser — the filename must match the url above)"
echo
echo "Rosy picks it up on next launch, or from Rosy Transcribe ▸ Check for Updates…"

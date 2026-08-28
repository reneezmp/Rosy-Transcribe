#!/bin/bash
#
# Builds Rosy Transcribe as a universal (arm64 + x86_64) app for macOS 13.0,
# and proves it — an app that cannot launch on Rosy is a silent failure, so
# every claim this script makes is checked against the built binary.
#
# Run on the M4. Copy build/RosyTranscribe.app to the target machine.

set -euo pipefail

PROJECT="RosyTranscribe.xcodeproj"
SCHEME="RosyTranscribe"
CONFIG="Release"
REQUIRED_TARGET="13.0"
DERIVED="$(pwd)/.build/DerivedData"
OUT="$(pwd)/build"

cd "$(dirname "$0")"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die() { printf '\n\033[31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight: can this Xcode still target macOS 13.0?
#
# Newer Xcode releases periodically drop older deployment targets. If 13.0 is
# gone, the whole project needs rethinking, and silently building for 14.0
# would produce an app that cannot launch on the machine it was built for.
# ---------------------------------------------------------------------------
say "Preflight"

command -v xcodebuild >/dev/null || die "xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"

echo "Xcode:  $(xcodebuild -version | head -1)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
echo "SDK:    macOS $(xcrun --sdk macosx --show-sdk-version)  ($SDK_PATH)"

SDK_MIN="$(plutil -extract SupportedTargets.macosx.MinimumDeploymentTarget raw -o - "$SDK_PATH/SDKSettings.plist" 2>/dev/null || echo "")"
if [ -z "$SDK_MIN" ]; then
    echo "WARNING: could not read the SDK's minimum deployment target."
    echo "         Check the build log below for 'deployment target' warnings."
else
    echo "SDK minimum deployment target: macOS $SDK_MIN"
    LOWEST="$(printf '%s\n%s\n' "$SDK_MIN" "$REQUIRED_TARGET" | sort -V | head -1)"
    if [ "$LOWEST" != "$SDK_MIN" ]; then
        die "This Xcode can no longer target macOS $REQUIRED_TARGET (its floor is $SDK_MIN).
       Rosy runs macOS 13.7 and cannot launch an app built for $SDK_MIN.
       Stop here and report back — do not raise the deployment target."
    fi
    echo "OK: macOS $REQUIRED_TARGET is still a permitted deployment target."
fi

# ---------------------------------------------------------------------------
say "Tests"
# The multipart envelope and the transcript formatter, neither of which needs
# the API or a key. Run before building the thing that ships.
# ---------------------------------------------------------------------------
xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    | grep -Ev '^$' \
    | tail -40

# ---------------------------------------------------------------------------
say "Building $CONFIG (universal)"
# ---------------------------------------------------------------------------
rm -rf "$OUT"
mkdir -p "$OUT"

xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    MACOSX_DEPLOYMENT_TARGET="$REQUIRED_TARGET" \
    | tail -20

APP="$DERIVED/Build/Products/$CONFIG/RosyTranscribe.app"
[ -d "$APP" ] || die "Build reported success but $APP does not exist."
cp -R "$APP" "$OUT/"
APP="$OUT/RosyTranscribe.app"
BIN="$APP/Contents/MacOS/RosyTranscribe"

# ---------------------------------------------------------------------------
say "Verifying the built binary"
# ---------------------------------------------------------------------------
ARCHS_BUILT="$(lipo -archs "$BIN")"
echo "Architectures:  $ARCHS_BUILT"
case "$ARCHS_BUILT" in
    *arm64*) ;; *) die "Binary is missing arm64." ;;
esac
case "$ARCHS_BUILT" in
    *x86_64*) ;; *) die "Binary is missing x86_64 — it will not run on Rosy." ;;
esac

# The minimum OS actually stamped into the Mach-O, per slice.
echo "Minimum OS stamped into each slice:"
FAILED=0
for arch in $ARCHS_BUILT; do
    MINOS="$(vtool -arch "$arch" -show-build-version "$BIN" 2>/dev/null | awk '/minos/ {print $2; exit}')"
    echo "  $arch: minos $MINOS"
    if [ -n "$MINOS" ]; then
        # Pass when MINOS <= REQUIRED_TARGET, i.e. MINOS sorts first.
        LOWEST="$(printf '%s\n%s\n' "$MINOS" "$REQUIRED_TARGET" | sort -V | head -1)"
        [ "$LOWEST" = "$MINOS" ] || { echo "    ^ too high for Rosy"; FAILED=1; }
    fi
done
[ "$FAILED" -eq 0 ] || die "The binary is stamped with a minimum OS above $REQUIRED_TARGET."

echo "Signature:"
codesign -dv "$APP" 2>&1 | sed 's/^/  /' || true

say "Done"
echo "App: $APP"
echo
echo "To install on Rosy: copy RosyTranscribe.app across, then right-click -> Open"
echo "the first time (it is signed to run locally, not notarised)."

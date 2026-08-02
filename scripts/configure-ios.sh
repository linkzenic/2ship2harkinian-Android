#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---simulator}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-14.0}"
BUNDLE_ID_OVERRIDE="${BUNDLE_ID:-}"
TWO_SHIP_IOS_VERSION="${TWO_SHIP_IOS_VERSION:-0.1.0}"
TWO_SHIP_IOS_BUILD_NUMBER="${TWO_SHIP_IOS_BUILD_NUMBER:-1}"

case "$MODE" in
    --simulator)
        IOS_PLATFORM="SIMULATORARM64"
        BUILD_DIR="$ROOT/build-ios-sim"
        ;;
    --device)
        IOS_PLATFORM="OS64"
        BUILD_DIR="$ROOT/build-ios-device"
        ;;
    --tvos-simulator)
        IOS_PLATFORM="SIMULATORARM64_TVOS"
        BUILD_DIR="$ROOT/build-tvos-sim"
        APPLE_SYSTEM_NAME="tvOS"
        APPLE_TARGET="tvos"
        ;;
    --tvos-device)
        IOS_PLATFORM="TVOS"
        BUILD_DIR="$ROOT/build-tvos-device"
        APPLE_SYSTEM_NAME="tvOS"
        APPLE_TARGET="tvos"
        ;;
    *)
        echo "Usage: scripts/configure-ios.sh [--simulator|--device|--tvos-simulator|--tvos-device]" >&2
        exit 2
        ;;
esac

APPLE_SYSTEM_NAME="${APPLE_SYSTEM_NAME:-iOS}"
APPLE_TARGET="${APPLE_TARGET:-ios}"
if [ "$APPLE_TARGET" = "tvos" ]; then
    BUNDLE_ID="${BUNDLE_ID_OVERRIDE:-com.linkzenic.2ship.tvos}"
else
    BUNDLE_ID="${BUNDLE_ID_OVERRIDE:-com.linkzenic.2ship.ios}"
fi

if [[ ! "$TWO_SHIP_IOS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "TWO_SHIP_IOS_VERSION must use numeric major.minor.patch form." >&2
    exit 2
fi
if [[ ! "$TWO_SHIP_IOS_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "TWO_SHIP_IOS_BUILD_NUMBER must be a positive integer." >&2
    exit 2
fi

# The embedded ZAPD revision identifies only macOS as an Apple linker target.
# iOS and tvOS require the same linker settings; apply the narrow adjustment
# while configuring and restore the checkout when the script exits.
ZAPD_CMAKE="$ROOT/ZAPDTR/ZAPD/CMakeLists.txt"
ZAPD_BACKUP=""
if grep -q 'CMAKE_SYSTEM_NAME STREQUAL "Darwin"' "$ZAPD_CMAKE"; then
    ZAPD_BACKUP="$(mktemp)"
    cp "$ZAPD_CMAKE" "$ZAPD_BACKUP"
    trap 'cp "$ZAPD_BACKUP" "$ZAPD_CMAKE"; rm -f "$ZAPD_BACKUP"' EXIT
    perl -0pi -e 's/CMAKE_SYSTEM_NAME STREQUAL "Darwin"/CMAKE_SYSTEM_NAME MATCHES "Darwin|iOS|tvOS"/g' "$ZAPD_CMAKE"
fi

set -- cmake -Wno-unused-cli \
    -S "$ROOT" -B "$BUILD_DIR" \
    -GXcode \
    -DCMAKE_SYSTEM_NAME="$APPLE_SYSTEM_NAME" \
    -DCMAKE_SYSTEM_VERSION="$DEPLOYMENT_TARGET" \
    -DDEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DBUILD_CROWD_CONTROL=OFF \
    -DPLATFORM="$IOS_PLATFORM" \
    -DTWO_SHIP_APPLE_TARGET="$APPLE_TARGET" \
    -DBUNDLE_ID="$BUNDLE_ID" \
    -DTWO_SHIP_IOS_VERSION="$TWO_SHIP_IOS_VERSION" \
    -DTWO_SHIP_IOS_BUILD_NUMBER="$TWO_SHIP_IOS_BUILD_NUMBER"

if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    set -- "$@" \
        "-DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM" \
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_STYLE=Automatic \
        -DSIGN_LIBRARY=ON
fi
if [ -n "${TWO_SHIP_O2R_PATH:-}" ]; then
    set -- "$@" "-DTWO_SHIP_O2R_PATH=$TWO_SHIP_O2R_PATH"
fi

"$@"
echo "Configured $BUILD_DIR"

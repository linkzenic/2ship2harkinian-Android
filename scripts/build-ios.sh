#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---simulator}"

"$ROOT/scripts/configure-ios.sh" "$MODE"

case "$MODE" in
    --simulator)
        BUILD_DIR="$ROOT/build-ios-sim"
        cmake --build "$BUILD_DIR" --target 2ship --config Release
        echo "Simulator app: $BUILD_DIR/mm/Release-iphonesimulator/2Ship 2 Harkinian.app"
        ;;
    --device)
        BUILD_DIR="$ROOT/build-ios-device"
        APP_PATH="$BUILD_DIR/mm/Release-iphoneos/2Ship 2 Harkinian.app"
        set -- cmake --build "$BUILD_DIR" --target 2ship --config Release -- \
            -destination generic/platform=iOS
        if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
            set -- "$@" -allowProvisioningUpdates -allowProvisioningDeviceRegistration
        fi
        if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
            set -- "$@" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
        fi
        "$@"
        if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
            codesign --remove-signature "$APP_PATH" 2>/dev/null || true
            rm -rf "$APP_PATH/_CodeSignature"
            rm -f "$APP_PATH/embedded.mobileprovision"
        fi
        echo "Device app: $APP_PATH"
        ;;
    --tvos-simulator)
        BUILD_DIR="$ROOT/build-tvos-sim"
        cmake --build "$BUILD_DIR" --target 2ship --config Release
        echo "Simulator app: $BUILD_DIR/mm/Release-appletvsimulator/2Ship 2 Harkinian.app"
        ;;
    --tvos-device)
        BUILD_DIR="$ROOT/build-tvos-device"
        APP_PATH="$BUILD_DIR/mm/Release-appletvos/2Ship 2 Harkinian.app"
        set -- cmake --build "$BUILD_DIR" --target 2ship --config Release -- \
            -destination generic/platform=tvOS
        if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
            set -- "$@" -allowProvisioningUpdates -allowProvisioningDeviceRegistration
        else
            set -- "$@" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
        fi
        "$@"
        if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
            codesign --remove-signature "$APP_PATH" 2>/dev/null || true
            rm -rf "$APP_PATH/_CodeSignature"
            rm -f "$APP_PATH/embedded.mobileprovision"
        fi
        echo "Device app: $APP_PATH"
        ;;
    *)
        echo "Usage: scripts/build-ios.sh [--simulator|--device|--tvos-simulator|--tvos-device]" >&2
        exit 2
        ;;
esac

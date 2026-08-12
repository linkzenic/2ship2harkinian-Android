#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/build-ios-device/mm/Release-iphoneos/2Ship 2 Harkinian.app}"
OUTPUT_PATH="${2:-$ROOT/dist/2Ship-2-Harkinian-iOS-unsigned.ipa}"

if [[ "$OUTPUT_PATH" != /* ]]; then
    OUTPUT_PATH="$(pwd)/$OUTPUT_PATH"
fi
if [ ! -d "$APP_PATH" ]; then
    echo "Missing iOS app bundle: $APP_PATH" >&2
    exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/2ship-ios-unsigned.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

mkdir -p "$STAGING_DIR/Payload"
rsync -a \
    --exclude "_CodeSignature" \
    --exclude "embedded.mobileprovision" \
    "$APP_PATH/" "$STAGING_DIR/Payload/2Ship 2 Harkinian.app/"

PUBLIC_APP="$STAGING_DIR/Payload/2Ship 2 Harkinian.app"
codesign --remove-signature "$PUBLIC_APP" 2>/dev/null || true
rm -rf "$PUBLIC_APP/_CodeSignature"
rm -f "$PUBLIC_APP/embedded.mobileprovision"

if codesign --verify "$PUBLIC_APP" 2>/dev/null; then
    echo "Refusing to package an app that still has a code signature." >&2
    exit 1
fi
if grep -R -a -F -q "/Users/" "$PUBLIC_APP"; then
    echo "Refusing to package an app containing a local macOS user path." >&2
    exit 1
fi
mkdir -p "$(dirname "$OUTPUT_PATH")"
(
    cd "$STAGING_DIR"
    /usr/bin/zip -qry "$OUTPUT_PATH" Payload
)

echo "Unsigned IPA: $OUTPUT_PATH"

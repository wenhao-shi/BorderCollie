#!/usr/bin/env bash
set -euo pipefail

BORDERCOLLIE_MODE="${1:-run}"
BORDERCOLLIE_APP_NAME="BorderCollie"
BORDERCOLLIE_BUNDLE_ID="Alpard.BorderCollie"
BORDERCOLLIE_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BORDERCOLLIE_DERIVED_DATA="${BORDERCOLLIE_DERIVED_DATA_PATH:-/private/tmp/BorderCollieDerivedDataRun}"
BORDERCOLLIE_APP_BUNDLE="$BORDERCOLLIE_DERIVED_DATA/Build/Products/Debug/$BORDERCOLLIE_APP_NAME.app"
BORDERCOLLIE_APP_BINARY="$BORDERCOLLIE_APP_BUNDLE/Contents/MacOS/$BORDERCOLLIE_APP_NAME"

pkill -x "$BORDERCOLLIE_APP_NAME" >/dev/null 2>&1 || true

xcodebuild build \
    -project "$BORDERCOLLIE_ROOT_DIR/BorderCollie.xcodeproj" \
    -scheme "$BORDERCOLLIE_APP_NAME" \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$BORDERCOLLIE_DERIVED_DATA"

open_app() {
    /usr/bin/open -n "$BORDERCOLLIE_APP_BUNDLE"
}

case "$BORDERCOLLIE_MODE" in
    run)
        open_app
        ;;
    --debug|debug)
        lldb -- "$BORDERCOLLIE_APP_BINARY"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$BORDERCOLLIE_APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BORDERCOLLIE_BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app
        sleep 1
        pgrep -x "$BORDERCOLLIE_APP_NAME" >/dev/null
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac

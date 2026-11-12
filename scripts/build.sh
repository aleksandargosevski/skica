#!/usr/bin/env bash
# Builds Skica.app into ./build and signs it.
#
# Options:
#   --run   restart the app after building
#   --zip   also create build/Skica-<version>.zip for a release
#
# Environment:
#   SKICA_VERSION        version written into Info.plist (e.g. 1.2.0)
#   SKICA_SIGN_IDENTITY  code signing identity (default: "Skica Dev" from scripts/create-cert.sh;
#                        without it the build is signed ad hoc, unless the identity was set explicitly)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Skica"
APP="$ROOT/build/$APP_NAME.app"
PLIST="$ROOT/Resources/Info.plist"
DEFAULT_IDENTITY="Skica Dev"
IDENTITY="${SKICA_SIGN_IDENTITY:-$DEFAULT_IDENTITY}"
VERSION="${SKICA_VERSION:-}"

RUN=false
ZIP=false
for arg in "$@"; do
  case "$arg" in
    --run) RUN=true ;;
    --zip) ZIP=true ;;
    *) echo "Error: unknown option $arg (expected --run or --zip)" >&2; exit 1 ;;
  esac
done

if [[ -n "$VERSION" && ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: SKICA_VERSION must look like 1.2.3, got \"$VERSION\"" >&2
  exit 1
fi

if [[ "$IDENTITY" != "-" ]] && ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  if [[ -n "${SKICA_SIGN_IDENTITY:-}" ]]; then
    echo "Error: signing identity \"$IDENTITY\" not found. Run scripts/create-cert.sh first." >&2
    exit 1
  fi
  echo "Warning: \"$DEFAULT_IDENTITY\" not found, signing ad hoc. Run scripts/create-cert.sh once for a stable signature." >&2
  IDENTITY="-"
fi

swift build -c release --package-path "$ROOT"
BIN_DIR="$(swift build -c release --package-path "$ROOT" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# The command-line tool; its build product is skica-cli because macOS file names ignore case
# and "skica" would collide with the app binary "Skica".
cp "$BIN_DIR/skica-cli" "$APP/Contents/Helpers/skica"
cp "$PLIST" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

# Quick Look: one binary in two extensions, Finder thumbnails and the space-bar preview.
for KIND in Thumbnail Preview; do
  APPEX="$APP/Contents/PlugIns/Skica$KIND.appex"
  mkdir -p "$APPEX/Contents/MacOS"
  cp "$BIN_DIR/SkicaQuickLook" "$APPEX/Contents/MacOS/Skica$KIND"
  cp "$ROOT/Resources/QuickLook/$KIND-Info.plist" "$APPEX/Contents/Info.plist"
done

if [[ -n "$VERSION" ]]; then
  for PLIST_PATH in "$APP/Contents/Info.plist" "$APP"/Contents/PlugIns/*.appex/Contents/Info.plist; do
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST_PATH"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST_PATH"
  done
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST")"
xattr -cr "$APP"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.cli" "$APP/Contents/Helpers/skica"
for APPEX in "$APP"/Contents/PlugIns/*.appex; do
  # Quick Look only loads sandboxed extensions.
  codesign --force --sign "$IDENTITY" --entitlements "$ROOT/Resources/QuickLook/QuickLook.entitlements" "$APPEX"
done
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"
# Registering the build lets macOS resolve the .skica document type it declares.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

if $ZIP; then
  ZIP_PATH="$ROOT/build/$APP_NAME-${VERSION:-dev}.zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent --norsrc --noextattr --noacl --noqtn "$APP" "$ZIP_PATH"
  echo "Created $ZIP_PATH"
fi

if $RUN; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  open "$APP"
  echo "Started $APP_NAME"
fi

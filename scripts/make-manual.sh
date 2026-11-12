#!/usr/bin/env bash
# Rebuilds the user guide in docs/manual: screenshots taken from the app, the shortcut table
# from the keymap, and Skica-Guide.pdf from the HTML.
#
# Usage: scripts/make-manual.sh [--no-build]
# Environment: SKETCH_SAMPLE=<file.sketch> refreshes the Sketch import screenshot (kept otherwise).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANUAL="$ROOT/docs/manual"
IMAGES="$MANUAL/images"
SHOTS="$ROOT/.build/shots"
export SKICA_DEBUG_SIZE="1280x800"

[[ "${1:-}" == "--no-build" ]] || "$ROOT/scripts/build.sh" >/dev/null 2>&1 || { echo "Error: the build failed; run scripts/build.sh to see why" >&2; exit 1; }
mkdir -p "$IMAGES"

# shot <name> <commands> <kind>: kind is "window" (the whole window), "inspector" (its right
# panel, cut to <height> pixels), "layers" (the left panel) or "canvas" (between the panels).
shot() {
  local name="$1" commands="$2" kind="$3" height="${4:-1560}"
  "$ROOT/scripts/snapshot.sh" "$name" "$commands" >/dev/null 2>&1 || { echo "Error: snapshot $name failed" >&2; exit 1; }
  local source="$SHOTS/$name.png" target="$IMAGES/$name.png"
  case "$kind" in
    window) sips -Z 1600 "$source" --out "$target" >/dev/null ;;
    inspector) sips -c "$height" 600 --cropOffset 0 1960 "$source" --out "$target" >/dev/null ;;
    layers) sips -c "$height" 480 --cropOffset 0 0 "$source" --out "$target" >/dev/null ;;
    canvas)
      sips -c 1544 1480 --cropOffset 0 480 "$source" --out "$target" >/dev/null
      sips -Z 1200 "$target" >/dev/null ;;
  esac
  echo "  $name"
}

echo "Screenshots:"
shot overview "" window
shot layers-panel "select:Card 2" layers 900
shot zen "toggleZen" window
shot palette "commandPalette" window
shot shortcuts "showShortcuts" window
shot hints "hintSelect" window
shot size-prompt "select:Hero,editGeometry,type:1360x480 @ 40,112" window
shot command-line "select:Card,zoomToSelection,commandLine,type:r 24; fill \$brand; shadow 0 8 24 #0002" window
shot selection "select:Card 1,zoomToSelection" window
shot inspector-style "select:Card" inspector 1560
shot inspector-text "select:Headline" inspector 1560
shot crop "cropDemo,zoomToSelection" window
shot edit-points "pasteSVG,enterSelection,selectNext,editPoints,zoomToSelection,zoomOut" canvas
shot inspector-symbol "select:Get Started Button" inspector 560
shot inspector-assets "" inspector 900
shot inspector-align "select:Card 1|Card 2|Card 3" inspector 300
shot inspector-stack "select:Menu" inspector 1040
shot inspector-export "select:App Icon" inspector 1560
shot svg-paste "pasteSVG,zoomToSelection" window
if [[ -n "${SKETCH_SAMPLE:-}" ]]; then
  SKICA_DEBUG_OPEN="$SKETCH_SAMPLE" shot sketch-import "" window
fi
sips -Z 256 "$ROOT/Resources/AppIconSource.png" --out "$IMAGES/icon.png" >/dev/null

echo "Shortcut table"
CLI="$(swift build -c release --package-path "$ROOT" --show-bin-path)/skica-cli"
TABLE="$(mktemp)"
trap 'rm -f "$TABLE"' EXIT
"$CLI" shortcuts --html > "$TABLE"
python3 - "$MANUAL/index.html" "$TABLE" <<'PY'
import re, sys
page, table = sys.argv[1], open(sys.argv[2]).read()
html = open(page).read()
start, end = "<!-- shortcuts:start -->", "<!-- shortcuts:end -->"
if start not in html or end not in html:
    sys.exit("index.html has no shortcut markers")
html = re.sub(re.escape(start) + ".*?" + re.escape(end), lambda _: start + "\n" + table + "\n" + end, html, flags=re.S)
open(page, "w").write(html)
PY

echo "PDF"
swift "$ROOT/scripts/render-pdf.swift" "$MANUAL/index.html" "$MANUAL/Skica-Guide.pdf" >/dev/null
echo "Done: $MANUAL/index.html and $MANUAL/Skica-Guide.pdf"

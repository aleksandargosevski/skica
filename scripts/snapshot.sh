#!/usr/bin/env bash
# Opens the sample document in the built app, runs commands and saves what the window shows,
# without needing screen recording access. See DebugSnapshot.swift for the command names.
#
# Usage: scripts/snapshot.sh <name> [comma,separated,commands]
# SKICA_DEBUG_OPEN=<file.skica|.sketch|.svg> opens that file instead of the sample.
# Writes .build/shots/<name>.png (window), <name>.layers.png (canvas as on screen) and
# <name>.inspector.png (the right panel).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:?usage: scripts/snapshot.sh <name> [commands]}"
COMMANDS="${2:-}"
OUT="$ROOT/.build/shots"
APP="$ROOT/build/Skica.app/Contents/MacOS/Skica"
mkdir -p "$OUT"
rm -f "$OUT/$NAME".*

[[ -x "$APP" ]] || { echo "Error: build the app first (scripts/build.sh)" >&2; exit 1; }
pkill -x Skica 2>/dev/null || true
sleep 0.5
SKICA_DEBUG_SIZE="${SKICA_DEBUG_SIZE:-}" SKICA_DEBUG_SNAPSHOT="$OUT/$NAME.png" SKICA_DEBUG_COMMANDS="$COMMANDS" "$APP" >/dev/null 2>"$OUT/$NAME.log" &
PID=$!
for _ in $(seq 1 40); do
  [[ -f "$OUT/$NAME.layers.png" ]] && break
  sleep 0.25
done
sleep 0.3
kill "$PID" 2>/dev/null || true
[[ -f "$OUT/$NAME.png" ]] || { echo "Error: no snapshot was written" >&2; exit 1; }

WIDTH=$(sips -g pixelWidth "$OUT/$NAME.png" | awk '/pixelWidth/ {print $2}')
HEIGHT=$(sips -g pixelHeight "$OUT/$NAME.png" | awk '/pixelHeight/ {print $2}')
sips -c "$HEIGHT" 700 --cropOffset 0 $((WIDTH - 700)) "$OUT/$NAME.png" --out "$OUT/$NAME.inspector.png" >/dev/null
echo "$OUT/$NAME.png"

#!/usr/bin/env bash
# Phase 3 offline review pipeline wrapper.
#
# Runs, for a given session (sessions/<name>/frames/*.png already on disk):
#   1. venv setup check (creates .venv with imagehash+pillow if missing)
#   2. bin/pipeline.py  -> sessions/<name>/analysis/manifest.json (+ OCR sidecars)
#   3. bin/build_index.py -> sessions/<name>/analysis/index.html
#   4. ImageMagick montage -> sessions/<name>/analysis/contact.png
#
# Does not touch the VM -- operates only on PNGs already captured to disk.
#
# Usage:
#   ./pipeline.sh                  # uses the most recently modified session
#   ./pipeline.sh --session demo   # uses sessions/demo

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

SESSION_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      SESSION_NAME="$2"
      shift 2
      ;;
    --session=*)
      SESSION_NAME="${1#--session=}"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--session <name>]"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SESSION_NAME" ]]; then
  # Most recently modified directory under sessions/
  SESSION_NAME="$(ls -t sessions | head -n1 || true)"
  if [[ -z "$SESSION_NAME" ]]; then
    echo "error: no sessions found under sessions/ and no --session given" >&2
    exit 1
  fi
  echo "no --session given; using most recent session: $SESSION_NAME"
fi

SESSION_DIR="sessions/$SESSION_NAME"
FRAMES_DIR="$SESSION_DIR/frames"
ANALYSIS_DIR="$SESSION_DIR/analysis"

if [[ ! -d "$FRAMES_DIR" ]]; then
  echo "error: $FRAMES_DIR does not exist" >&2
  exit 1
fi

# --- 1. venv setup check ---------------------------------------------------
PY="$ROOT/.venv/bin/python3"
if [[ ! -x "$PY" ]]; then
  echo "== .venv not found or incomplete; creating it =="
  python3 -m venv "$ROOT/.venv"
  "$ROOT/.venv/bin/pip" install --quiet imagehash pillow
elif ! "$PY" -c "import imagehash, PIL" >/dev/null 2>&1; then
  echo "== .venv missing imagehash/pillow; installing =="
  "$ROOT/.venv/bin/pip" install --quiet imagehash pillow
fi
if [[ ! -x "$PY" ]]; then
  echo "falling back to system python3 (imagehash/pillow must already be importable)"
  PY="python3"
fi

for tool in convert montage identify tesseract; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required tool '$tool' not found on PATH" >&2
    exit 1
  fi
done

# --- 2. run the frame/OCR/hash pipeline ------------------------------------
echo "== running pipeline.py on $SESSION_DIR =="
"$PY" "$ROOT/bin/pipeline.py" "$SESSION_DIR"

# --- 3. build the HTML timeline --------------------------------------------
echo "== building index.html =="
"$PY" "$ROOT/bin/build_index.py" "$SESSION_DIR"

# --- 4. build the contact sheet ---------------------------------------------
echo "== building contact sheet =="
mkdir -p "$ANALYSIS_DIR"
FRAME_FILES=("$FRAMES_DIR"/*.png)
if [[ ! -e "${FRAME_FILES[0]}" ]]; then
  echo "error: no PNG frames found in $FRAMES_DIR" >&2
  exit 1
fi
# ImageMagick's montage needs an explicit font to render frame labels; use
# a bundled macOS TTF if one is found, otherwise fall back to unlabeled tiles.
LABEL_FONT=""
for candidate in "/System/Library/Fonts/Supplemental/Arial.ttf" "/System/Library/Fonts/Supplemental/Helvetica.ttc"; do
  if [[ -f "$candidate" ]]; then
    LABEL_FONT="$candidate"
    break
  fi
done

MONTAGE_ARGS=(-tile 4x -geometry 320x200+6+6 -label '%[basename]' -background '#1b1d21' -fill white -pointsize 14)
if [[ -n "$LABEL_FONT" ]]; then
  MONTAGE_ARGS+=(-font "$LABEL_FONT")
else
  echo "warning: no system font found for montage labels; building contact sheet without labels"
  MONTAGE_ARGS=(-tile 4x -geometry 320x200+6+6 -background '#1b1d21')
fi

montage "${FRAME_FILES[@]}" "${MONTAGE_ARGS[@]}" "$ANALYSIS_DIR/contact.png"

echo ""
echo "== done =="
echo "manifest:     $ANALYSIS_DIR/manifest.json"
echo "timeline:     $ANALYSIS_DIR/index.html"
echo "contact sheet: $ANALYSIS_DIR/contact.png"

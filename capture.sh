#!/usr/bin/env bash
#
# capture.sh - Phase 2: on-demand, non-destructive screen capture of an
# already-running guest via QMP screendump. Does NOT terminate the VM.
#
# Usage:
#   ./capture.sh [--qmp <sock>] [--session <name>] [--device <display-dev-id>] \
#                [--out <file>] [--verify]
#
#   --qmp <sock>      QMP unix socket path (default: ./qmp.sock)
#   --session <name>  Session directory name under ./sessions/
#                      (default: a UTC timestamp for this run)
#   --device <id>     Target a specific display device/head for screendump
#                      (default: QEMU's default head; omits the arg)
#   --out <file>       Explicit output path (overrides the session scheme;
#                      relative paths are resolved to absolute)
#   --verify           After capture, run ImageMagick `identify` and warn if
#                      the frame looks blank (stddev ~= 0). Still exits 0 as
#                      long as the file exists. Without this flag, no
#                      dependency on ImageMagick.
#
# On success: prints the frame path and the screendump latency in ms, exit 0.
# On failure (no QMP socket, QMP error): prints a clear error, exit nonzero.
# The VM is left running in all cases.

set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"

QMP_SOCK="$PROJ/qmp.sock"
SESSION=""
DEVICE=""
OUT=""
VERIFY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --qmp)     QMP_SOCK="$2"; shift 2 ;;
    --session) SESSION="$2";  shift 2 ;;
    --device)  DEVICE="$2";   shift 2 ;;
    --out)     OUT="$2";      shift 2 ;;
    --verify)  VERIFY=1;      shift 1 ;;
    -h|--help)
      grep '^#' "$0" | sed -n '2,30p' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "capture.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ---- resolve QMP_SOCK to an absolute path for a clearer error message -------
case "$QMP_SOCK" in
  /*) ;;
  *) QMP_SOCK="$PROJ/$QMP_SOCK" ;;
esac

if [ ! -S "$QMP_SOCK" ]; then
  echo "capture.sh: no running VM / QMP socket not found at $QMP_SOCK" >&2
  exit 1
fi

UTC_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

if [ -n "$OUT" ]; then
  case "$OUT" in
    /*) OUT_PATH="$OUT" ;;
    *) OUT_PATH="$PROJ/$OUT" ;;
  esac
else
  SESSION_NAME="${SESSION:-$UTC_STAMP}"
  FRAME_DIR="$PROJ/sessions/$SESSION_NAME/frames"
  mkdir -p "$FRAME_DIR"
  # sequence number = count of existing frame_*.png files in this dir + 1
  SEQ=1
  if [ -d "$FRAME_DIR" ]; then
    EXISTING=$(find "$FRAME_DIR" -maxdepth 1 -name 'frame_*.png' | wc -l | tr -d ' ')
    SEQ=$((EXISTING + 1))
  fi
  SEQ_PADDED=$(printf '%03d' "$SEQ")
  OUT_PATH="$FRAME_DIR/frame_${UTC_STAMP}_${SEQ_PADDED}.png"
fi

mkdir -p "$(dirname "$OUT_PATH")"

# ---- capture ------------------------------------------------------------
CAPTURE_ARGS=("$QMP_SOCK" "$OUT_PATH")
if [ -n "$DEVICE" ]; then
  CAPTURE_ARGS+=("$DEVICE")
fi

if ! CAPTURE_OUTPUT="$("$PYTHON" "$PROJ/bin/capture.py" "${CAPTURE_ARGS[@]}" 2>&1)"; then
  echo "capture.sh: capture failed:" >&2
  echo "$CAPTURE_OUTPUT" >&2
  exit 1
fi

LATENCY_MS="$(echo "$CAPTURE_OUTPUT" | grep '^LATENCY_MS:' | sed 's/^LATENCY_MS: //')"

if [ ! -s "$OUT_PATH" ]; then
  echo "capture.sh: screendump reported success but no file was written at $OUT_PATH" >&2
  exit 1
fi

# ---- optional verify ------------------------------------------------------
if [ "$VERIFY" -eq 1 ]; then
  if command -v identify >/dev/null 2>&1; then
    STDDEV="$(identify -format '%[standard-deviation]' "$OUT_PATH" 2>/dev/null || echo "")"
    if [ -n "$STDDEV" ]; then
      # Compare as float; treat < 0.5 as effectively blank.
      IS_BLANK="$(awk -v v="$STDDEV" 'BEGIN { print (v < 0.5) ? 1 : 0 }')"
      if [ "$IS_BLANK" -eq 1 ]; then
        echo "capture.sh: WARNING: frame looks blank (stddev=$STDDEV): $OUT_PATH" >&2
      else
        echo "capture.sh: verify OK (stddev=$STDDEV)" >&2
      fi
    else
      echo "capture.sh: WARNING: identify produced no stddev for $OUT_PATH" >&2
    fi
  else
    echo "capture.sh: WARNING: --verify requested but 'identify' (ImageMagick) not found in PATH" >&2
  fi
fi

echo "FRAME: $OUT_PATH"
echo "LATENCY_MS: ${LATENCY_MS:-unknown}"
exit 0

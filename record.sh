#!/usr/bin/env bash
#
# record.sh - interval capture wrapper around capture.sh. Repeatedly calls
# capture.sh on a fixed cadence to build up a frame sequence for a session.
# This script owns no QMP/screendump logic itself -- every capture goes
# through capture.sh, unmodified.
#
# Usage:
#   ./record.sh --session <name> [--interval 5] [--duration 300] \
#               [--qmp ./qmp.sock] [--device virtio-gpu-pci] [--note "text"]
#
#   --session <name>   Session directory name under ./sessions/ (required)
#   --interval <secs>  Seconds between captures (default: 5)
#   --duration <secs>  Total seconds to run before stopping on its own
#                      (default: 0, meaning run until SIGINT/SIGTERM)
#   --qmp <sock>       QMP unix socket path, forwarded to capture.sh
#                      (default: ./qmp.sock)
#   --device <id>      Display device/head id, forwarded to capture.sh
#                      (default: unset -- capture.sh omits the flag and
#                      QEMU picks its default head)
#   --note <text>      Free-text note recorded in sessions/<name>/session.json
#
# On SIGINT/SIGTERM the loop stops cleanly (no frame is left half-written)
# and prints how many frames were captured and where they live. The VM is
# never touched directly -- capture.sh is non-destructive and so is this.

set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION=""
INTERVAL=5
DURATION=0
QMP="./qmp.sock"
DEVICE=""
NOTE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --session)  SESSION="$2";  shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --qmp)      QMP="$2";      shift 2 ;;
    --device)   DEVICE="$2";   shift 2 ;;
    --note)     NOTE="$2";     shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed -n '2,24p' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "record.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SESSION" ]; then
  echo "record.sh: --session <name> is required" >&2
  exit 2
fi

# ---- session provenance (written once, before the first capture) ---------
META_ARGS=(write --session "$SESSION" --interval "$INTERVAL" --duration "$DURATION")
if [ -n "$NOTE" ]; then
  META_ARGS+=(--note "$NOTE")
fi
python3 "$PROJ/bin/session-meta.py" "${META_ARGS[@]}"

# ---- capture loop ----------------------------------------------------------
FRAME_COUNT=0
STOP=0

on_signal() {
  STOP=1
}
trap on_signal INT TERM

report_and_exit() {
  echo "record.sh: stopped after $FRAME_COUNT frame(s) -- see $PROJ/sessions/$SESSION/frames" >&2
  exit 0
}

START_EPOCH=$(date +%s)

while :; do
  [ "$STOP" -eq 1 ] && report_and_exit

  CAPTURE_ARGS=(--session "$SESSION" --qmp "$QMP")
  if [ -n "$DEVICE" ]; then
    CAPTURE_ARGS+=(--device "$DEVICE")
  fi

  if "$PROJ/capture.sh" "${CAPTURE_ARGS[@]}"; then
    FRAME_COUNT=$((FRAME_COUNT + 1))
  else
    echo "record.sh: WARNING: capture failed, continuing" >&2
  fi

  [ "$STOP" -eq 1 ] && report_and_exit

  if [ "$DURATION" -gt 0 ]; then
    NOW_EPOCH=$(date +%s)
    ELAPSED=$((NOW_EPOCH - START_EPOCH))
    [ "$ELAPSED" -ge "$DURATION" ] && report_and_exit
  fi

  # Sleep in 1s ticks so a signal is noticed promptly instead of only
  # between full INTERVAL-second sleeps.
  SLEPT=0
  while [ "$SLEPT" -lt "$INTERVAL" ]; do
    [ "$STOP" -eq 1 ] && report_and_exit
    sleep 1
    SLEPT=$((SLEPT + 1))
  done
done

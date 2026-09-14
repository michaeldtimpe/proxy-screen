#!/usr/bin/env bash
#
# ingress.sh - Pack read-only host files into an ISO for sample delivery into
# the guest, matching boot.sh's INGRESS_ISO flag.
#
# Stages the given host paths into a temp directory, then builds an
# ISO9660+Joliet image with macOS `hdiutil makehybrid`. The resulting image
# is intended to be attached read-only, e.g.:
#
#   INGRESS_ISO="<absolute out>" ./boot.sh
#
# where it appears to the guest as a removable, read-only USB volume.
#
# Usage:
#   ./ingress.sh <path> [<path>...] [--out vm/ingress.iso] [--label SAMPLES]
#   ./ingress.sh --help

set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: ${BASH_SOURCE[0]} <path> [<path>...] [--out vm/ingress.iso] [--label SAMPLES]

  <path>...        One or more host files/directories to stage into the ISO.
                    Each must exist; the script aborts otherwise.
  --out <file>      Output ISO path (default: vm/ingress.iso).
  --label <name>    Volume label / -default-volume-name (default: SAMPLES).
  -h, --help        Show this help.

Builds an ISO9660+Joliet image (hdiutil makehybrid) containing copies of the
given inputs, for read-only delivery into the guest alongside boot.sh:

  INGRESS_ISO="<absolute out>" ./boot.sh

The guest sees this as a removable, read-only USB volume.
EOF
}

OUT="$PROJ/vm/ingress.iso"
LABEL="SAMPLES"
INPUTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --out)   OUT="$2";   shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do INPUTS+=("$1"); shift; done ;;
    -*) echo "ingress.sh: unknown arg: $1" >&2; exit 2 ;;
    *) INPUTS+=("$1"); shift ;;
  esac
done

if [ "${#INPUTS[@]}" -eq 0 ]; then
  echo "ingress.sh: no input paths given" >&2
  usage >&2
  exit 2
fi

for p in "${INPUTS[@]}"; do
  if [ ! -e "$p" ]; then
    echo "ingress.sh: input does not exist: $p" >&2
    exit 1
  fi
done

case "$OUT" in
  /*) : ;;
  *) OUT="$PROJ/$OUT" ;;
esac
mkdir -p "$(dirname "$OUT")"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ingress.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

for p in "${INPUTS[@]}"; do
  cp -R "$p" "$STAGE/"
done

rm -f "$OUT"
hdiutil makehybrid -iso -joliet -default-volume-name "$LABEL" -o "$OUT" "$STAGE"

echo "ingress.sh: created $OUT" >&2
echo
echo "INGRESS_ISO=\"$OUT\" ./boot.sh"
echo
echo "(appears in the guest as a removable, read-only USB volume)"

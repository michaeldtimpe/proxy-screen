#!/usr/bin/env bash
#
# snapshot.sh - Golden/overlay disk-state management for the guest qcow2.
#
# Complements boot.sh's EPHEMERAL flag: this script manages a read-only
# "golden" baseline disk (vm/golden.qcow2) and disposable copy-on-write
# overlays backed by it, so a run can be reset to a known clean state without
# re-provisioning the guest from scratch.
#
# Usage:
#   ./snapshot.sh golden [--from vm/guest.qcow2] [--force]
#   ./snapshot.sh new    [--out vm/guest.qcow2]
#   ./snapshot.sh reset  [--disk vm/guest.qcow2] [--yes]
#   ./snapshot.sh info
#   ./snapshot.sh --help
#
# Subcommands:
#   golden   Flatten <--from> into vm/golden.qcow2 via `qemu-img convert`,
#            then chmod it read-only. Refuses to overwrite an existing
#            golden unless --force.
#   new      Create a fresh copy-on-write overlay at <--out>, backed by
#            vm/golden.qcow2 via an ABSOLUTE backing path (so the overlay
#            works regardless of CWD). Refuses if golden is missing.
#   reset    DESTRUCTIVE: discard the working overlay at <--disk> and
#            recreate it fresh from golden (same as `new`). Prompts for an
#            interactive "y" confirmation unless --yes.
#   info     Print `qemu-img info --backing-chain` for golden and the
#            working overlay (vm/guest.qcow2 by default).
#
# Contract: golden always lives at vm/golden.qcow2. Overlays always carry an
# absolute backing-file path, so they remain valid no matter what directory
# they are booted from.

set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

QEMU_IMG="${QEMU_IMG:-qemu-img}"
GOLDEN="$PROJ/vm/golden.qcow2"
DEFAULT_DISK="$PROJ/vm/guest.qcow2"

usage() {
  cat <<EOF
Usage:
  ${BASH_SOURCE[0]} golden [--from <disk>] [--force]
  ${BASH_SOURCE[0]} new    [--out <disk>]
  ${BASH_SOURCE[0]} reset  [--disk <disk>] [--yes]
  ${BASH_SOURCE[0]} info
  ${BASH_SOURCE[0]} --help

  golden [--from vm/guest.qcow2] [--force]
      Flatten <--from> into vm/golden.qcow2 (qemu-img convert -O qcow2),
      then mark it read-only (chmod -w). Refuses to overwrite an existing
      golden unless --force is given.

  new [--out vm/guest.qcow2]
      Create a fresh copy-on-write overlay at <--out>, backed by
      vm/golden.qcow2 (absolute backing path). Refuses if golden is missing.

  reset [--disk vm/guest.qcow2] [--yes]
      DESTRUCTIVE. Deletes <--disk> and recreates it fresh from golden.
      Prompts for interactive "y" confirmation unless --yes is given.

  info
      Print 'qemu-img info --backing-chain' for golden and the working
      overlay (vm/guest.qcow2 unless overridden with --disk).

Golden always lives at: vm/golden.qcow2
EOF
}

require_golden() {
  if [ ! -f "$GOLDEN" ]; then
    echo "snapshot.sh: golden disk not found: $GOLDEN" >&2
    echo "snapshot.sh: create it first with: ${BASH_SOURCE[0]} golden" >&2
    exit 1
  fi
}

create_overlay() {
  # $1 = destination path for the new overlay
  local out="$1"
  mkdir -p "$(dirname "$out")"
  "$QEMU_IMG" create -f qcow2 -b "$GOLDEN" -F qcow2 "$out"
}

cmd_golden() {
  local from="$DEFAULT_DISK"
  local force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)  from="$2"; shift 2 ;;
      --force) force=1;   shift 1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "snapshot.sh golden: unknown arg: $1" >&2; exit 2 ;;
    esac
  done

  if [ ! -f "$from" ]; then
    echo "snapshot.sh: source disk not found: $from" >&2
    exit 1
  fi
  if [ -f "$GOLDEN" ] && [ "$force" -ne 1 ]; then
    echo "snapshot.sh: golden already exists: $GOLDEN (use --force to overwrite)" >&2
    exit 1
  fi

  if [ -f "$GOLDEN" ]; then
    chmod +w "$GOLDEN"
    rm -f "$GOLDEN"
  fi

  mkdir -p "$PROJ/vm"
  echo "snapshot.sh: flattening $from -> $GOLDEN" >&2
  "$QEMU_IMG" convert -O qcow2 "$from" "$GOLDEN"
  chmod -w "$GOLDEN"
  echo "snapshot.sh: golden created and marked read-only: $GOLDEN" >&2
}

cmd_new() {
  local out="$DEFAULT_DISK"
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "snapshot.sh new: unknown arg: $1" >&2; exit 2 ;;
    esac
  done

  require_golden
  case "$out" in
    /*) : ;;
    *) out="$PROJ/$out" ;;
  esac
  if [ -e "$out" ]; then
    echo "snapshot.sh: refusing to overwrite existing file: $out" >&2
    echo "snapshot.sh: use 'reset' to discard and recreate an overlay" >&2
    exit 1
  fi

  create_overlay "$out"
  echo "snapshot.sh: new overlay created: $out (backed by $GOLDEN)" >&2
}

cmd_reset() {
  local disk="$DEFAULT_DISK"
  local yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --disk) disk="$2"; shift 2 ;;
      --yes)  yes=1;     shift 1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "snapshot.sh reset: unknown arg: $1" >&2; exit 2 ;;
    esac
  done

  require_golden
  case "$disk" in
    /*) : ;;
    *) disk="$PROJ/$disk" ;;
  esac

  if [ "$yes" -ne 1 ]; then
    echo "snapshot.sh: this will DESTROY $disk and recreate it fresh from golden."
    read -r -p "Continue? [y/N] " reply
    case "$reply" in
      y|Y|yes|YES) : ;;
      *) echo "snapshot.sh: aborted." >&2; exit 1 ;;
    esac
  fi

  rm -f "$disk"
  create_overlay "$disk"
  echo "snapshot.sh: overlay reset: $disk (backed by $GOLDEN)" >&2
}

cmd_info() {
  local disk="$DEFAULT_DISK"
  while [ $# -gt 0 ]; do
    case "$1" in
      --disk) disk="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "snapshot.sh info: unknown arg: $1" >&2; exit 2 ;;
    esac
  done

  if [ -f "$GOLDEN" ]; then
    echo "=== golden: $GOLDEN ==="
    "$QEMU_IMG" info --backing-chain "$GOLDEN"
  else
    echo "=== golden: $GOLDEN (missing) ==="
  fi

  echo
  if [ -f "$disk" ]; then
    echo "=== overlay: $disk ==="
    "$QEMU_IMG" info --backing-chain "$disk"
  else
    echo "=== overlay: $disk (missing) ==="
  fi
}

if [ $# -eq 0 ]; then
  usage
  exit 2
fi

case "$1" in
  -h|--help) usage; exit 0 ;;
  golden) shift; cmd_golden "$@" ;;
  new)    shift; cmd_new "$@" ;;
  reset)  shift; cmd_reset "$@" ;;
  info)   shift; cmd_info "$@" ;;
  *) echo "snapshot.sh: unknown subcommand: $1" >&2; usage; exit 2 ;;
esac

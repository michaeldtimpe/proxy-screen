#!/usr/bin/env bash
#
# boot.sh - Parameterized QEMU launcher for the host-side VM screen-capture tool.
# Phase 1a: Apple Silicon macOS host, arm64 'virt' guest, HVF acceleration,
# headless + serial + QMP capture. No stealth hardening yet (see Phase 4 TODOs).
#
# All settings are env-var driven; a few also accept flags. Sane defaults below.
#
#   DISPLAY_BACKEND  none (default) | cocoa | spice   -> QEMU -display option
#   CAPTURE_DEV      virtio-gpu-pci (default) | ramfb  -> guest framebuffer device
#   MEM              guest RAM in MiB (default 4096)
#   CPUS             vCPU count (default 4)
#   DISK             path to guest qcow2 (default vm/guest.qcow2)
#   SEED             optional cloud-init NoCloud seed ISO (default vm/seed.iso if present)
#   QMP_SOCK         QMP unix socket path (default ./qmp.sock)
#   SERIAL           stdio (default) | none | <path> for a unix-socket serial console
#   ACPI_BATTERY     if set (non-empty), add -acpitable file=<proj>/acpi/battery.aml
#   VARS             per-VM writable EDK2 varstore (default vm/<disk-basename>-vars.fd)
#   EXTRA_ARGS       extra raw args appended to the qemu command line
#   PCAP             if set, dump all guest NIC traffic to this host pcap file
#                    (via -object filter-dump on netdev net0; invisible to guest)
#   EPHEMERAL        if set (1), boot a disposable qcow2 overlay of a golden/base
#                    image; all guest writes are discarded when qemu exits
#   GOLDEN           backing image for EPHEMERAL (default vm/golden.qcow2 if it
#                    exists, else DISK)
#   INGRESS_ISO      if set, attach this ISO as a removable read-only USB mass-
#                    storage device (a "sample delivery" vector)
#   LOWVIRTIO        EXPERIMENTAL: if set (1), shrink the virtio (1af4) surface —
#                    NIC virtio-net-pci -> e1000e, disk virtio-blk-pci -> nvme.
#                    May need guest driver support and may change the boot device
#                    path; validate that the guest still boots before relying on it.
#
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- defaults ----------------------------------------------------------------
DISPLAY_BACKEND="${DISPLAY_BACKEND:-none}"
CAPTURE_DEV="${CAPTURE_DEV:-virtio-gpu-pci}"
MEM="${MEM:-4096}"
CPUS="${CPUS:-4}"
DISK="${DISK:-$PROJ/vm/guest.qcow2}"
SEED="${SEED:-}"
QMP_SOCK="${QMP_SOCK:-$PROJ/qmp.sock}"
SERIAL="${SERIAL:-stdio}"
ACPI_BATTERY="${ACPI_BATTERY:-}"
VARS="${VARS:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
# Opt-in analysis features (each a no-op when unset).
PCAP="${PCAP:-}"
EPHEMERAL="${EPHEMERAL:-}"
INGRESS_ISO="${INGRESS_ISO:-}"
LOWVIRTIO="${LOWVIRTIO:-}"
# Phase 4A stealth hardening. Default ON; set STEALTH=0 for A/B baseline runs.
STEALTH="${STEALTH:-1}"

# ---- simple flag parsing (flags override env) --------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --display)  DISPLAY_BACKEND="$2"; shift 2 ;;
    --capture)  CAPTURE_DEV="$2";     shift 2 ;;
    --mem)      MEM="$2";             shift 2 ;;
    --cpus)     CPUS="$2";            shift 2 ;;
    --disk)     DISK="$2";            shift 2 ;;
    --seed)     SEED="$2";            shift 2 ;;
    --qmp)      QMP_SOCK="$2";        shift 2 ;;
    --serial)   SERIAL="$2";          shift 2 ;;
    --battery)  ACPI_BATTERY="1";     shift 1 ;;
    --stealth)     STEALTH="1";       shift 1 ;;
    --no-stealth)  STEALTH="0";       shift 1 ;;
    --vars)     VARS="$2";            shift 2 ;;
    --pcap)        PCAP="$2";         shift 2 ;;
    --ephemeral)   EPHEMERAL="1";     shift 1 ;;
    --ingress)     INGRESS_ISO="$2";  shift 2 ;;
    --low-virtio)  LOWVIRTIO="1";     shift 1 ;;
    --)         shift; EXTRA_ARGS="$EXTRA_ARGS $*"; break ;;
    *) echo "boot.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

QEMU="/opt/homebrew/bin/qemu-system-aarch64"
CODE_FD="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
VARS_TEMPLATE="/opt/homebrew/share/qemu/edk2-arm-vars.fd"

# Default seed ISO if one exists next to the disk and none was specified.
if [ -z "$SEED" ] && [ -f "$PROJ/vm/seed.iso" ]; then
  SEED="$PROJ/vm/seed.iso"
fi

# Per-VM writable varstore. EDK2 needs a 64MiB writable copy of the vars template.
if [ -z "$VARS" ]; then
  base="$(basename "$DISK")"
  VARS="$PROJ/vm/${base%.*}-vars.fd"
fi
if [ ! -f "$VARS" ]; then
  echo "boot.sh: creating writable EDK2 varstore: $VARS" >&2
  cp "$VARS_TEMPLATE" "$VARS"
fi

# ---- display backend ---------------------------------------------------------
case "$DISPLAY_BACKEND" in
  none)  DISPLAY_ARGS=(-display none) ;;
  cocoa) DISPLAY_ARGS=(-display cocoa) ;;
  spice) DISPLAY_ARGS=(-spice "unix=on,addr=$PROJ/spice.sock,disable-ticketing=on") ;;
  *) echo "boot.sh: unknown DISPLAY_BACKEND: $DISPLAY_BACKEND" >&2; exit 2 ;;
esac

# ---- capture / framebuffer device --------------------------------------------
case "$CAPTURE_DEV" in
  virtio-gpu-pci) CAPTURE_ARGS=(-device virtio-gpu-pci) ;;
  ramfb)          CAPTURE_ARGS=(-device ramfb) ;;
  *) echo "boot.sh: unknown CAPTURE_DEV: $CAPTURE_DEV" >&2; exit 2 ;;
esac

# ---- serial console ----------------------------------------------------------
# For the unix-socket case we route the console through a chardev with a
# logfile= so ALL guest serial output is captured to a file regardless of
# whether a client is connected. This avoids wedging the guest console when no
# reader is draining the socket, and gives a durable boot log.
SERIAL_LOG="${SERIAL_LOG:-$PROJ/serial.log}"
case "$SERIAL" in
  stdio) SERIAL_ARGS=(-serial mon:stdio) ;;
  none)  SERIAL_ARGS=(-serial none) ;;
  *)     SERIAL_ARGS=(-chardev "socket,id=ser0,path=$SERIAL,server=on,wait=off,logfile=$SERIAL_LOG"
                       -serial chardev:ser0) ;;
esac

# ---- disks -------------------------------------------------------------------
# When stealth is on we attach the main disk explicitly (if=none + virtio-blk-pci)
# so we can set a realistic drive serial= (shows up in the guest via
# /sys/block/vda/serial and lsblk -o SERIAL). Non-stealth keeps the simple
# auto-attached if=virtio form. Guest device name is /dev/vda either way.

# ---- EPHEMERAL disposable overlay --------------------------------------------
# When EPHEMERAL is set, boot a throwaway qcow2 overlay backed by a golden/base
# image instead of writing to the real disk. All guest writes land in the
# overlay, which is deleted when qemu exits, so every run starts from a clean
# known-good state. Must run BEFORE DISK_ARGS is built so DISK points at the
# overlay. qemu-img records the backing path literally, so it must be absolute.
if [ -n "$EPHEMERAL" ]; then
  GOLDEN_IMG="${GOLDEN:-$PROJ/vm/golden.qcow2}"
  if [ -f "$GOLDEN_IMG" ]; then
    BACKING="$GOLDEN_IMG"
  else
    BACKING="$DISK"
  fi
  case "$BACKING" in
    /*) : ;;                                                   # already absolute
    *)  BACKING="$(cd "$(dirname "$BACKING")" && pwd)/$(basename "$BACKING")" ;;
  esac
  OVERLAY="$(mktemp "${TMPDIR:-/tmp}/boot-ephemeral-XXXXXX")"
  trap 'rm -f "$OVERLAY"' EXIT
  qemu-img create -f qcow2 -b "$BACKING" -F qcow2 "$OVERLAY" >&2
  echo "EPHEMERAL: booting throwaway overlay of $BACKING, discarded on exit" >&2
  DISK="$OVERLAY"
fi

if [ "$STEALTH" = "1" ]; then
  DISK_SERIAL="${DISK_SERIAL:-S4EWNX0N612345}"   # realistic Samsung-style NVMe serial
  # bootindex=0 is REQUIRED here: moving off the auto-attached if=virtio form
  # changes the disk's PCI path, so the firmware's saved NVRAM boot entry no
  # longer matches and EDK2 drops to the UEFI shell. bootindex tells the
  # firmware to boot this device regardless of stale NVRAM BootOrder.
  if [ "$LOWVIRTIO" = "1" ]; then
    # EXPERIMENTAL: present the main disk as NVMe instead of virtio-blk to
    # shrink the virtio (1af4) PCI surface. Keeps serial= and bootindex=0.
    DISK_ARGS=(-drive "if=none,id=disk0,format=qcow2,file=$DISK"
               -device "nvme,drive=disk0,serial=$DISK_SERIAL,bootindex=0")
  else
    DISK_ARGS=(-drive "if=none,id=disk0,format=qcow2,file=$DISK"
               -device "virtio-blk-pci,drive=disk0,serial=$DISK_SERIAL,bootindex=0")
  fi
else
  DISK_ARGS=(-drive "if=virtio,format=qcow2,file=$DISK")
fi
if [ -n "$SEED" ] && [ "$STEALTH" != "1" ]; then
  # cloud-init NoCloud seed as a read-only raw cdrom-ish virtio disk.
  DISK_ARGS+=(-drive "if=virtio,format=raw,file=$SEED,readonly=on")
elif [ "$STEALTH" = "1" ] && [ -n "$SEED" ]; then
  # Phase 4A: with stealth on we DO NOT attach the CIDATA seed. cloud-init has
  # been purged from the guest, so the seed is unused, and leaving it off
  # removes the CIDATA-labeled block device (a NoCloud/VM tell) and the XFCE
  # desktop auto-mount icon it produced.
  echo "boot.sh: STEALTH=1 -> not attaching cloud-init seed ($SEED)" >&2
fi

# ---- ACPI fake battery -------------------------------------------------------
# VERIFIED FINDING (Phase 1a): `-acpitable` is NOT supported on the arm64 'virt'
# target (i386/x86_64 only). RESOLVED in Phase 4A a different way: the fake
# battery (acpi/battery.aml) is injected GUEST-SIDE via the early-initrd ACPI
# table override (CONFIG_ACPI_TABLE_UPGRADE) baked into the guest's initrd, so
# BAT0/ADP0 are already present at boot with NO host flag. The ACPI_BATTERY /
# --battery flag below is therefore vestigial: it must NOT add -acpitable (that
# aborts QEMU on this target). Kept as a safe, warned no-op for compatibility.
ACPI_ARGS=()
if [ -n "$ACPI_BATTERY" ]; then
  echo "boot.sh: ACPI_BATTERY/--battery is a no-op on arm64 — the battery is" >&2
  echo "         provided by the guest initrd (Phase 4A), not by -acpitable." >&2
fi

# ---- networking (user-mode) --------------------------------------------------
# Phase 4A: with stealth on, override the NIC MAC with a real-vendor OUI so the
# guest no longer advertises the default QEMU 52:54:00 OUI. e8:6a:64 is an
# LCFC/Lenovo-family OUI, matching the SMBIOS identity below. Non-stealth keeps
# QEMU's default (52:54:00...) for A/B comparison.
if [ "$STEALTH" = "1" ]; then
  NET_MAC="${NET_MAC:-e8:6a:64:1a:2b:3c}"
  if [ "$LOWVIRTIO" = "1" ]; then
    # EXPERIMENTAL: e1000e instead of virtio-net-pci to shrink the virtio surface.
    NET_ARGS=(-netdev "user,id=net0" -device "e1000e,netdev=net0,mac=$NET_MAC")
  else
    NET_ARGS=(-netdev "user,id=net0" -device "virtio-net-pci,netdev=net0,mac=$NET_MAC")
  fi
else
  if [ "$LOWVIRTIO" = "1" ]; then
    NET_ARGS=(-netdev "user,id=net0" -device "e1000e,netdev=net0")
  else
    NET_ARGS=(-netdev "user,id=net0" -device "virtio-net-pci,netdev=net0")
  fi
fi

# ---- PCAP host-side traffic capture ------------------------------------------
# When PCAP is set, attach a filter-dump to the existing netdev net0. This
# records every frame to a host pcap file with no guest-visible device.
PCAP_ARGS=()
if [ -n "$PCAP" ]; then
  PCAP_ARGS=(-object "filter-dump,id=pcap0,netdev=net0,file=$PCAP")
fi

# ---- INGRESS sample-delivery ISO ---------------------------------------------
# When INGRESS_ISO is set, attach it as a removable, read-only USB mass-storage
# device via an xHCI controller — a natural way to hand a sample to the guest.
INGRESS_ARGS=()
if [ -n "$INGRESS_ISO" ]; then
  INGRESS_ARGS=(-device "qemu-xhci,id=xhci"
                -drive "if=none,id=ingress0,file=$INGRESS_ISO,format=raw,readonly=on"
                -device "usb-storage,bus=xhci.0,drive=ingress0,removable=on")
fi

# virtio-rng: give the guest a fast entropy source so first-boot operations that
# need randomness never stall. Harmless and standard; not stealth-related.
RNG_ARGS=(-device "virtio-rng-pci")

# ---- SMBIOS / firmware identity (Phase 4A stealth) ---------------------------
# VERIFIED FINDING (QEMU 11.1.1, qemu-system-aarch64, machine 'virt'):
#   Unlike -acpitable, `-smbios type=N,...` IS accepted on the arm64 virt target.
#   The virt machine builds SMBIOS tables internally and honors these string
#   overrides, which Linux surfaces under /sys/class/dmi/id/*. We spoof a Lenovo
#   ThinkPad identity across type=0 (BIOS), 1 (system), 2 (baseboard), 3 (chassis)
#   so sys_vendor/product_name/board_vendor/chassis_vendor/bios_vendor stop
#   reporting QEMU/BOCHS. Identity is ThinkPad X13s Gen 1 (21BX/21BY,
#   Snapdragon 8cx Gen 3) so the SMBIOS model agrees with the arm64 guest CPU
#   (the prior X1 Carbon Gen 8 identity was Intel-only and arch-inconsistent).
#   UUID is a stable per-install value persisted at vm/smbios-uuid (see below),
#   not randomized per boot, matching real hardware.
# NOTE(GL pass): the virtio-gpu / virtio 1af4 PCI tell and llvmpipe renderer are
#   NOT addressed here; CAPTURE_DEV stays virtio-gpu-pci because QMP screendump
#   depends on it. Those vectors are the next (GL) pass's job.
SMBIOS_ARGS=()
if [ "$STEALTH" = "1" ]; then
  # Stable per-install SMBIOS UUID: a real machine's UUID does not change
  # every boot. Persist it once at vm/smbios-uuid; SM_UUID env still overrides.
  SM_UUID_FILE="${SM_UUID_FILE:-$PROJ/vm/smbios-uuid}"
  if [ -z "${SM_UUID:-}" ]; then
    [ -f "$SM_UUID_FILE" ] || { mkdir -p "$(dirname "$SM_UUID_FILE")"; uuidgen >"$SM_UUID_FILE"; }
    SM_UUID="$(cat "$SM_UUID_FILE")"
  fi
  SMBIOS_ARGS=(
    -smbios "type=0,vendor=LENOVO,version=N3HET76W (1.48),date=12/23/2022"
    -smbios "type=1,manufacturer=LENOVO,product=21BXCTO1WW,version=ThinkPad X13s Gen 1,serial=PF2ABCDE,uuid=$SM_UUID,sku=LENOVO_MT_21BX_BU_Think_FM_ThinkPad X13s Gen 1,family=ThinkPad X13s Gen 1"
    -smbios "type=2,manufacturer=LENOVO,product=21BXCTO1WW,version=SDK0T76463 WIN,serial=L1HF01234567"
    -smbios "type=3,manufacturer=LENOVO,version=None,serial=PF2ABCDE,asset=No Asset Information"
  )
fi

CMD=(
  "$QEMU"
  -machine "virt,accel=hvf"
  -cpu host
  -smp "$CPUS"
  -m "$MEM"
  -drive "if=pflash,format=raw,unit=0,file=$CODE_FD,readonly=on"
  -drive "if=pflash,format=raw,unit=1,file=$VARS"
  -qmp "unix:$QMP_SOCK,server=on,wait=off"
  "${DISPLAY_ARGS[@]}"
  "${CAPTURE_ARGS[@]}"
  "${SERIAL_ARGS[@]}"
  "${DISK_ARGS[@]}"
  ${ACPI_ARGS[@]+"${ACPI_ARGS[@]}"}
  ${SMBIOS_ARGS[@]+"${SMBIOS_ARGS[@]}"}
  "${NET_ARGS[@]}"
  ${PCAP_ARGS[@]+"${PCAP_ARGS[@]}"}
  "${RNG_ARGS[@]}"
  ${INGRESS_ARGS[@]+"${INGRESS_ARGS[@]}"}
)
if [ -n "$EXTRA_ARGS" ]; then
  # shellcheck disable=SC2206
  CMD+=($EXTRA_ARGS)
fi

echo "boot.sh: launching:" >&2
printf '  %q' "${CMD[@]}" >&2; echo >&2

if [ -n "$EPHEMERAL" ]; then
  # Do NOT exec: keep this shell alive so the EXIT trap can delete the throwaway
  # overlay after qemu terminates (exec would replace the shell and skip it).
  "${CMD[@]}"
else
  exec "${CMD[@]}"
fi

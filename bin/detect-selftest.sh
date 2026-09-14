#!/usr/bin/env bash
#
# detect-selftest.sh - Phase 4A VM-detection self-test.
#
# Probes a RUNNING guest over its unix-socket serial console (via
# bin/serialcmd.py), classifies each known VM-detection vector as OK/LEAK,
# and writes a timestamped per-vector report to sessions/selftest-<UTC>.txt.
# Re-runnable: each run is a fresh timestamped file. The guest is not modified
# and is left running.
#
# Usage:
#   ./bin/detect-selftest.sh --serial <serial.sock> [--label <text>]
#
#   --serial <sock>   Path to the guest's serial unix socket (required).
#                     Launch the guest with SERIAL=<sock> boot.sh ...
#   --label <text>    Free-text label recorded in the report header
#                     (e.g. "STEALTH=0 baseline" / "STEALTH=1 hardened").
#   --user / --pass   Guest login (default analyst/analyst).
#
# Vectors classified:
#   device-tree model, DMI ids, NIC MAC/OUI, power_supply (battery),
#   glxinfo renderer (GL pass - out of scope), lspci virtio 1af4 (GL pass -
#   out of scope), cloud-init presence, CIDATA seed datasource, hostname.

set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-python3}"

SERIAL=""
LABEL="(unlabeled)"
USER_="analyst"
PASS_="analyst"

while [ $# -gt 0 ]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --label)  LABEL="$2";  shift 2 ;;
    --user)   USER_="$2";  shift 2 ;;
    --pass)   PASS_="$2";  shift 2 ;;
    -h|--help) grep '^#' "$0" | sed -n '2,30p' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "detect-selftest.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SERIAL" ]; then
  echo "detect-selftest.sh: --serial <sock> is required" >&2; exit 2
fi
if [ ! -S "$SERIAL" ]; then
  echo "detect-selftest.sh: serial socket not found at $SERIAL (is the guest running?)" >&2; exit 1
fi

UTC_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$PROJ/sessions/selftest-${UTC_STAMP}.txt"
mkdir -p "$PROJ/sessions"
RAW="$(mktemp "${TMPDIR:-/tmp}/selftest-raw.XXXXXX")"
if [ -n "${SELFTEST_KEEP_RAW:-}" ]; then
  echo "detect-selftest.sh: keeping raw at $RAW" >&2
else
  trap 'rm -f "$RAW"' EXIT
fi

# ---- remote probes: one short command per vector ----------------------------
# Sending many short commands (rather than one huge line) avoids console line-
# wrap / bracketed-paste truncation. p() persists across commands in the same
# shell session and emits a single KEY::value line per probe.
PROBES=(
  'p(){ printf "%s::%s\n" "$1" "$(printf "%s" "$2" | tr "\n" " " | tr -d "\000")"; }'
  'p DT_MODEL "$(cat /proc/device-tree/model 2>/dev/null || echo NO_DEVICETREE)"'
  'p DMI_sys_vendor "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)"'
  'p DMI_product_name "$(cat /sys/class/dmi/id/product_name 2>/dev/null)"'
  'p DMI_board_vendor "$(cat /sys/class/dmi/id/board_vendor 2>/dev/null)"'
  'p DMI_chassis_vendor "$(cat /sys/class/dmi/id/chassis_vendor 2>/dev/null)"'
  'p DMI_bios_vendor "$(cat /sys/class/dmi/id/bios_vendor 2>/dev/null)"'
  'p MAC "$(for n in /sys/class/net/*; do case "$n" in */lo) ;; *) cat "$n/address" 2>/dev/null;; esac; done | grep -v "^00:00:00" | head -1)"'
  'p DISK_SERIAL "$(cat /sys/block/vda/serial 2>/dev/null || cat /sys/block/vda/device/serial 2>/dev/null)"'
  'p POWER "$(ls /sys/class/power_supply/ 2>/dev/null)"'
  'p GLXINFO "$(DISPLAY=:0 XAUTHORITY=/home/analyst/.Xauthority glxinfo -B 2>/dev/null | grep -i "OpenGL renderer" | head -1 || echo NO_GLXINFO)"'
  'p WEBGL_CFG "$(grep -h override-unmasked-renderer /home/analyst/.mozilla/firefox/*/user.js /usr/lib/firefox-esr/ff-stealth.cfg 2>/dev/null | head -1)"'
  'p LSPCI_VIRTIO "$(lspci -nn 2>/dev/null | grep -ci 1af4 || echo NO_LSPCI)"'
  'p CLOUDINIT "$(dpkg -l cloud-init 2>/dev/null | grep -c "^ii")"'
  'p CIDATA "$(lsblk -o LABEL 2>/dev/null | grep -c CIDATA)"'
  'p DATASOURCE "$(cat /run/cloud-init/cloud-id 2>/dev/null || echo none)"'
  'p HOSTNAME "$(hostname 2>/dev/null)"'
  'p MACHINE_ID "$(cat /etc/machine-id 2>/dev/null)"'
  'p TZ "$(cat /etc/timezone 2>/dev/null || readlink /etc/localtime 2>/dev/null)"'
)

echo "detect-selftest.sh: probing guest over $SERIAL (label: $LABEL) ..." >&2
"$PYTHON" "$PROJ/bin/serialcmd.py" "$SERIAL" --user "$USER_" --pass "$PASS_" \
  --timeout 240 -- "${PROBES[@]}" >"$RAW" 2>&1 || {
    echo "detect-selftest.sh: serialcmd failed; raw output:" >&2
    tail -30 "$RAW" >&2
    exit 1
  }

# ---- classify + format (embedded python) ------------------------------------
"$PYTHON" - "$RAW" "$REPORT" "$LABEL" "$UTC_STAMP" <<'PYEOF'
import sys, re
raw_path, report_path, label, stamp = sys.argv[1:5]
raw = open(raw_path, encoding="utf-8", errors="replace").read()

vals = {}
for line in raw.splitlines():
    m = re.match(r'^([A-Za-z0-9_]+)::(.*)$', line)
    if m:
        vals[m.group(1)] = m.group(2).strip()

def g(k): return vals.get(k, "")

rows = []  # (vector, value_shown, status, note)

def add(vec, val, status, note=""):
    rows.append((vec, val if val else "<empty>", status, note))

# device-tree (this guest boots UEFI+ACPI; /proc/device-tree may be absent)
dt = g("DT_MODEL")
if "dummy-virt" in dt:
    add("device-tree model", dt, "LEAK", "next pass (dt override)")
elif "NO_DEVICETREE" in dt or not dt:
    add("device-tree model", "not present (ACPI boot)", "N/A", "no DT exposed")
else:
    add("device-tree model", dt, "OK")

# DMI
for key, vec in [("DMI_sys_vendor","dmi sys_vendor"),
                 ("DMI_product_name","dmi product_name"),
                 ("DMI_board_vendor","dmi board_vendor"),
                 ("DMI_chassis_vendor","dmi chassis_vendor"),
                 ("DMI_bios_vendor","dmi bios_vendor")]:
    v = g(key)
    leak = (not v) or re.search(r'qemu|bochs|seabios', v, re.I)
    add(vec, v, "LEAK" if leak else "OK")

# MAC / OUI
mac = g("MAC")
oui = mac[:8].lower()
if not mac:
    add("nic mac / oui", mac, "LEAK", "no mac read")
elif oui == "52:54:00":
    add("nic mac / oui", mac, "LEAK", "default QEMU OUI 52:54:00")
else:
    add("nic mac / oui", mac, "OK", "oui "+oui)

# disk serial
ds = g("DISK_SERIAL")
add("disk serial", ds, "LEAK" if not ds else "OK")

# battery
pw = g("POWER")
add("power_supply / battery", pw, "OK" if re.search(r'BAT', pw) else "LEAK",
    "" if re.search(r'BAT', pw) else "no battery present")

# glx (out of scope)
gl = g("GLXINFO")
gl_leak = bool(re.search(r'llvmpipe|virgl|swrast|softpipe', gl, re.I))
add("glxinfo renderer", gl, "LEAK" if gl_leak else ("N/A" if "NO_GLXINFO" in gl or not gl else "OK"),
    "OUT OF SCOPE (GL pass)")

# webgl renderer spoof (Phase 4B). Browser JS reads UNMASKED_RENDERER_WEBGL;
# baseline Firefox on this guest reports the software renderer ("llvmpipe, or
# similar"), the strongest browser-facing VM tell. We deliver a locked override
# (webgl.override-unmasked-renderer) via profile user.js + AutoConfig cfg. This
# probe reads the *delivered* override value from those config files and
# classifies: empty => not spoofed (LEAK); software/VM keyword => LEAK;
# a plausible real GPU string => OK. (Config-delivery check; the live on-screen
# proof is webgl-proof.png, captured with Firefox pointed at webgl-info.html.)
wc = g("WEBGL_CFG")
m = re.search(r'override-unmasked-renderer"\s*,\s*"([^"]+)"', wc)
wval = m.group(1) if m else ""
if not wval:
    add("webgl renderer", "not configured", "LEAK", "no override pref delivered")
elif re.search(r'llvmpipe|swrast|softpipe|virgl|llvm', wval, re.I):
    add("webgl renderer", wval, "LEAK", "reports software/VM GL")
else:
    add("webgl renderer", wval, "OK", "spoofed to real-GPU string")

# lspci virtio (out of scope)
lv = g("LSPCI_VIRTIO")
try:
    n = int(lv)
    add("virtio pci (1af4)", "%s device(s)" % n, "LEAK" if n>0 else "OK", "OUT OF SCOPE (GL pass)")
except ValueError:
    add("virtio pci (1af4)", lv, "N/A", "OUT OF SCOPE (GL pass)")

# cloud-init
ci = g("CLOUDINIT")
add("cloud-init installed", ci, "LEAK" if ci not in ("0","") else "OK")

# CIDATA seed
cd = g("CIDATA").replace(" ", "")
add("CIDATA seed", g("CIDATA"), "LEAK" if re.search(r'[1-9]', cd) else "OK")

# datasource
add("cloud-init datasource", g("DATASOURCE"),
    "LEAK" if g("DATASOURCE") not in ("none","") else "OK")

# hostname (informational)
hn = g("HOSTNAME")
add("hostname", hn, "LEAK" if hn == "proxy-screen" else "OK")

# machine-id / tz (informational only)
add("machine-id", g("MACHINE_ID"), "INFO")
add("timezone", g("TZ"), "INFO")

# ---- render ----
leaks = sum(1 for r in rows if r[2] == "LEAK")
oks   = sum(1 for r in rows if r[2] == "OK")

out = []
out.append("=" * 72)
out.append("VM DETECTION SELF-TEST REPORT")
out.append("UTC:     %s" % stamp)
out.append("Label:   %s" % label)
out.append("Summary: %d LEAK, %d OK  (INFO/N/A rows excluded from counts)" % (leaks, oks))
out.append("=" * 72)
w1 = max(len(r[0]) for r in rows) + 2
w2 = min(38, max(len(r[1]) for r in rows) + 2)
hdr = "%-*s %-6s %-*s %s" % (w1, "VECTOR", "STATUS", w2, "VALUE", "NOTE")
out.append(hdr)
out.append("-" * len(hdr))
for vec, val, status, note in rows:
    v = val if len(val) <= w2-1 else val[:w2-2] + "…"
    out.append("%-*s %-6s %-*s %s" % (w1, vec, status, w2, v, note))
out.append("-" * len(hdr))
text = "\n".join(out) + "\n"

open(report_path, "w").write(text)
sys.stdout.write(text)
PYEOF

echo "" >&2
echo "detect-selftest.sh: report written to $REPORT" >&2
echo "$REPORT"

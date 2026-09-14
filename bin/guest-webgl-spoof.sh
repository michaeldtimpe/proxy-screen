#!/usr/bin/env bash
#
# guest-webgl-spoof.sh - Fix Firefox's WebGL UNMASKED_RENDERER_WEBGL /
# UNMASKED_VENDOR_WEBGL strings to match this VM's declared hardware
# identity: a Lenovo ThinkPad X13s Gen 1 (arm64, Qualcomm Snapdragon 8cx
# Gen 3 SoC, Adreno 690 GPU).
#
# The prior spoof reported "Mesa Intel(R) UHD Graphics (CML GT2)" /
# "Intel" -- an x86 desktop GPU vendor string on a machine that claims to
# be a Snapdragon arm64 laptop. That GPU-vendor/CPU-arch mismatch is a
# strong, cheap-to-check identity tell. This script replaces it with a
# renderer/vendor pair that is internally consistent with the declared
# hardware.
#
# Run INSIDE the guest as the analyst user (directly, or as root/sudo with
# --user analyst).
#
# ---------------------------------------------------------------------------
# WHY THESE STRINGS
#
# On real Debian/arm64 hardware, the Adreno 690 is driven by Mesa's
# open-source "freedreno" gallium driver (there is no proprietary Adreno
# Linux driver). freedreno's pipe_screen name/vendor callbacks are:
#
#   fd_screen_get_name(pscreen)   -> snprintf(buf, "FD%03d", device_id)
#   fd_screen_get_vendor(pscreen) -> "freedreno"
#
# (src/gallium/drivers/freedreno/freedreno_screen.c; verified against the
# Mesa source mirror below.) For device_id 690 that yields exactly:
#
#   GL_RENDERER = "FD690"
#   GL_VENDOR   = "freedreno"
#
# Unlike Intel's iris driver -- which bakes a verbose "Mesa Intel(R) ..."
# string into its own get_name() -- freedreno's get_name() returns only
# the bare "FD%03d" token; no "Mesa" prefix and no Mesa-version suffix
# belong in GL_RENDERER (the Mesa version lives in the separate GL_VERSION
# string). Firefox's WEBGL_debug_renderer_info extension surfaces
# GL_RENDERER/GL_VENDOR verbatim as UNMASKED_RENDERER_WEBGL/
# UNMASKED_VENDOR_WEBGL on Linux (native GL, no ANGLE remapping the way
# Windows/ChromeOS/Android builds do), so "FD690" / "freedreno" is what a
# real X13s running Firefox on Mesa would actually report.
#
# This was cross-checked against real captured glxinfo/glmark2 output
# using the same freedreno naming convention on sibling a6xx/a7xx Adreno
# parts ("FD650" for Adreno 650, "FD740" for Adreno 740), and the
# Adreno 690 <-> Snapdragon 8cx Gen 3 <-> ThinkPad X13s hardware mapping
# is confirmed by the Gentoo wiki's X13s hardware table and Phoronix's
# "Linux 6.5 Adding Qualcomm Adreno 690 Open-Source GPU Support".
#
# Sources:
#   https://github.com/intel/external-mesa/blob/master/src/gallium/drivers/freedreno/freedreno_screen.c
#   https://wiki.gentoo.org/wiki/Lenovo_ThinkPad_X13s
#   https://www.phoronix.com/news/Linux-6.5-MSM-Adreno-A690
#   https://docs.mesa3d.org/drivers/freedreno.html
# ---------------------------------------------------------------------------
#
# Usage:
#   ./bin/guest-webgl-spoof.sh [--user <name>] [--print]
#
#   --user <name>   System user whose Firefox profile gets patched
#                    (default: analyst). Their home dir is resolved via
#                    getent/~user, so this also works when invoked via
#                    sudo as root.
#   --print          Print the chosen renderer/vendor strings and the
#                    exact user.js pref lines, then exit. Does not touch
#                    any file or require a Firefox profile to exist.
#   -h, --help       Show this help.
#
# Firefox prefs written (Firefox 140esr-verified pref names -- do NOT
# substitute the older, nonexistent "*-string-override" names):
#   webgl.override-unmasked-renderer = "FD690"
#   webgl.override-unmasked-vendor   = "freedreno"
#   webgl.sanitize-unmasked-renderer = false
#
# These are written to user.js in the analyst's Firefox profile
# (~/.mozilla/firefox/*.default*/user.js). user.js is preferred over
# editing prefs.js directly: Firefox re-reads user.js on every startup and
# lets it clobber whatever is in prefs.js, whereas prefs.js is rewritten
# by Firefox itself on exit and a live hand-edit would just be lost.
#
# Verify: launch Firefox in the guest and open assets/webgl-info.html
# (file:// or served) -- RENDERER should read "FD690" and VENDOR should
# read "freedreno".

set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGET_USER="analyst"
PRINT_ONLY=0

RENDERER="FD690"
VENDOR="freedreno"

while [ $# -gt 0 ]; do
  case "$1" in
    --user)      TARGET_USER="$2"; shift 2 ;;
    --print)     PRINT_ONLY=1; shift ;;
    -h|--help)   grep '^#' "$0" | sed -n '2,80p' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "guest-webgl-spoof.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

PREF_LINES=$(cat <<EOF
user_pref("webgl.override-unmasked-renderer", "${RENDERER}");
user_pref("webgl.override-unmasked-vendor", "${VENDOR}");
user_pref("webgl.sanitize-unmasked-renderer", false);
EOF
)

if [ "$PRINT_ONLY" -eq 1 ]; then
  echo "renderer: ${RENDERER}"
  echo "vendor:   ${VENDOR}"
  echo
  echo "$PREF_LINES"
  exit 0
fi

# Resolve the target user's home directory (works whether invoked directly
# as that user, or via sudo/root with --user).
HOME_DIR=""
if command -v getent >/dev/null 2>&1; then
  HOME_DIR="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
fi
if [ -z "$HOME_DIR" ]; then
  HOME_DIR="$(eval echo "~${TARGET_USER}" 2>/dev/null || true)"
fi
if [ -z "$HOME_DIR" ] || [ ! -d "$HOME_DIR" ]; then
  echo "guest-webgl-spoof.sh: could not resolve a home directory for user '$TARGET_USER'" >&2
  exit 1
fi

FIREFOX_DIR="$HOME_DIR/.mozilla/firefox"
PROFILES=()
if [ -d "$FIREFOX_DIR" ]; then
  for d in "$FIREFOX_DIR"/*.default*/; do
    [ -d "$d" ] && PROFILES+=("${d%/}")
  done
fi

if [ "${#PROFILES[@]}" -eq 0 ]; then
  cat >&2 <<EOF
guest-webgl-spoof.sh: no Firefox profile found under $FIREFOX_DIR/*.default*/

Firefox creates its default profile on first launch. Start Firefox once
inside the guest as $TARGET_USER (it can be closed again immediately),
then re-run this script:

    su - $TARGET_USER -c 'firefox-esr &'
    # ...wait for the window, then close it...
    $0 --user $TARGET_USER

(Use --print to see the chosen strings/pref lines without needing a
profile.)
EOF
  exit 1
fi

for PROFILE in "${PROFILES[@]}"; do
  USER_JS="$PROFILE/user.js"
  touch "$USER_JS"
  TMP="$(mktemp "${TMPDIR:-/tmp}/user.js.XXXXXX")"
  # Drop any pre-existing lines for these three prefs (e.g. the old Intel
  # spoof, or a prior run of this script) so re-running stays idempotent
  # instead of accumulating duplicate/conflicting user_pref lines.
  grep -vE 'user_pref\("webgl\.(override-unmasked-renderer|override-unmasked-vendor|sanitize-unmasked-renderer)"' \
    "$USER_JS" > "$TMP" || true
  {
    cat "$TMP"
    echo "$PREF_LINES"
  } > "$USER_JS"
  rm -f "$TMP"
  echo "guest-webgl-spoof.sh: wrote WebGL spoof prefs to $USER_JS" >&2
done

echo >&2
echo "renderer: ${RENDERER}" >&2
echo "vendor:   ${VENDOR}" >&2
echo >&2
echo "Restart Firefox for the new prefs to take effect, then verify:" >&2
if [ -f "$PROJ/assets/webgl-info.html" ]; then
  echo "  open file://$PROJ/assets/webgl-info.html" >&2
else
  echo "  copy assets/webgl-info.html into the guest and open it in Firefox" >&2
  echo "  (file://<path>/webgl-info.html) -- confirm RENDERER=$RENDERER VENDOR=$VENDOR" >&2
fi

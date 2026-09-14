#!/usr/bin/env bash
# =============================================================================
#  guest-proxy-setup.sh  --  run INSIDE the arm64 Linux guest.
#
#  Points the system + Firefox at the host MITM proxy (10.0.2.2:PROXY_PORT) and
#  trusts the mitmproxy CA, so proxy.sh can log the FULL DECRYPTED redirect
#  chain. Delivered to the guest over the serial console or via the ingress ISO.
#
#  -------------------------------------------------------------------------
#  !!  DETECTABILITY TRADEOFF -- READ BEFORE USING  !!
#  -------------------------------------------------------------------------
#  Installing a MITM CA into the guest trust store AND exporting proxy env
#  vars (http_proxy/https_proxy) are THEMSELVES analysis/VM tells. Sophisticated
#  malware routinely fingerprints exactly these:
#     * an unexpected root CA named "mitmproxy" in the trust store,
#     * http_proxy/https_proxy pointing at a 10.0.2.x RFC1918 gateway,
#     * a Firefox enterprise policy pinning a proxy + custom cert.
#  Any of these can make a sample decide it is being watched and go dormant.
#
#  The UNDETECTABLE alternative is passive host-side packet capture: boot.sh's
#  PCAP= knob (tcpdump on the host tap, nothing installed in the guest). That
#  still yields the TLS SNI and destination IPs of every hop -- enough to see
#  the redirect chain's shape -- it just cannot decrypt the URLs/bodies.
#
#  RECOMMENDATION: reach for PCAP first. Use this MITM setup ONLY when you
#  specifically need the full decrypted chain (exact URLs, Location headers,
#  meta-refresh / JS redirect targets) and accept the added detectability.
#  -------------------------------------------------------------------------
#
#  Usage (inside guest, as root):
#     sudo PROXY_PORT=8080 bin/guest-proxy-setup.sh            # fetch CA via mitm.it
#     sudo bin/guest-proxy-setup.sh --cert /path/to/mitm.pem   # use a local CA
#     sudo bin/guest-proxy-setup.sh --off                      # remove everything
# =============================================================================
set -euo pipefail

PROXY_HOST="10.0.2.2"
PROXY_PORT="${PROXY_PORT:-8080}"
PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"

PROFILE_SNIPPET="/etc/profile.d/proxy.sh"
FF_POLICY_DIR="/etc/firefox-esr/policies"
FF_POLICY="${FF_POLICY_DIR}/policies.json"
CA_DEST="/usr/local/share/ca-certificates/mitmproxy.crt"

MODE="on"
CERT_SRC=""

usage() {
  cat <<EOF
guest-proxy-setup.sh - configure this guest to use the host MITM proxy.

Usage:
  sudo [PROXY_PORT=8080] bin/guest-proxy-setup.sh [--cert <pem>]
  sudo bin/guest-proxy-setup.sh --off
  bin/guest-proxy-setup.sh --help

Options:
  --cert <pem>   Install this local CA PEM instead of fetching from mitm.it.
  --off          Remove the proxy env, Firefox policy, and mitmproxy CA.
  --help         Show this help.

Env:
  PROXY_PORT     Host proxy port reached via ${PROXY_HOST} (default: 8080).

NOTE: installing a MITM CA + proxy env vars is itself a detectable VM tell.
Prefer boot.sh's passive PCAP= capture unless you need the decrypted chain.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --off) MODE="off" ;;
    --cert) shift; CERT_SRC="${1:-}"; [ -n "$CERT_SRC" ] || { echo "--cert needs a path" >&2; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    *) echo "guest-proxy-setup.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$(id -u)" -ne 0 ]; then
  echo "guest-proxy-setup.sh: must run as root (EUID 0). Try: sudo $0 ..." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# --off : tear everything down.
# ---------------------------------------------------------------------------
if [ "$MODE" = "off" ]; then
  removed=0
  for f in "$PROFILE_SNIPPET" "$FF_POLICY" "$CA_DEST"; do
    if [ -e "$f" ]; then
      rm -f "$f"
      echo "removed $f"
      removed=1
    fi
  done
  # Drop the now-empty Firefox policy dir if we created it.
  rmdir "$FF_POLICY_DIR" 2>/dev/null || true
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates --fresh >/dev/null 2>&1 || update-ca-certificates >/dev/null 2>&1 || true
  fi
  if [ "$removed" -eq 0 ]; then
    echo "guest-proxy-setup.sh: nothing to remove."
  else
    echo "guest-proxy-setup.sh: proxy configuration removed."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# on : 1) proxy env snippet
# ---------------------------------------------------------------------------
cat > "$PROFILE_SNIPPET" <<EOF
# Installed by guest-proxy-setup.sh -- host MITM proxy via QEMU user-net gateway.
export http_proxy="${PROXY_URL}"
export https_proxy="${PROXY_URL}"
export HTTP_PROXY="${PROXY_URL}"
export HTTPS_PROXY="${PROXY_URL}"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="localhost,127.0.0.1,::1"
EOF
chmod 0644 "$PROFILE_SNIPPET"
echo "wrote $PROFILE_SNIPPET"

# Make the current shell honor the proxy for the CA fetch below.
# shellcheck disable=SC1090
. "$PROFILE_SNIPPET"

# ---------------------------------------------------------------------------
# on : 2) obtain + install the mitmproxy CA
# ---------------------------------------------------------------------------
install -d -m 0755 "$(dirname "$CA_DEST")"

if [ -n "$CERT_SRC" ]; then
  [ -f "$CERT_SRC" ] || { echo "guest-proxy-setup.sh: --cert file not found: $CERT_SRC" >&2; exit 4; }
  cp "$CERT_SRC" "$CA_DEST"
  echo "installed CA from $CERT_SRC -> $CA_DEST"
else
  # mitm.it is a magic host served by mitmproxy while proxied.
  echo "fetching mitmproxy CA from http://mitm.it/cert/pem (via ${PROXY_URL}) ..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proxy "$PROXY_URL" http://mitm.it/cert/pem -o "$CA_DEST"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -e use_proxy=yes -e "http_proxy=$PROXY_URL" -O "$CA_DEST" http://mitm.it/cert/pem
  else
    echo "guest-proxy-setup.sh: neither curl nor wget available; pass --cert <pem>." >&2
    exit 4
  fi
  # Sanity: a real PEM starts with a BEGIN CERTIFICATE header.
  if ! grep -q "BEGIN CERTIFICATE" "$CA_DEST" 2>/dev/null; then
    echo "guest-proxy-setup.sh: fetched file is not a PEM certificate." >&2
    echo "  Is the proxy running and is the guest actually proxied?" >&2
    rm -f "$CA_DEST"
    exit 4
  fi
  echo "installed CA -> $CA_DEST"
fi
chmod 0644 "$CA_DEST"

if command -v update-ca-certificates >/dev/null 2>&1; then
  update-ca-certificates >/dev/null 2>&1 || true
  echo "updated system CA trust store"
else
  echo "warning: update-ca-certificates not found; system trust not refreshed." >&2
fi

# ---------------------------------------------------------------------------
# on : 3) Firefox enterprise policy (proxy + CA trust)
# ---------------------------------------------------------------------------
install -d -m 0755 "$FF_POLICY_DIR"
cat > "$FF_POLICY" <<EOF
{
  "policies": {
    "Proxy": {
      "Mode": "manual",
      "HTTPProxy": "${PROXY_HOST}:${PROXY_PORT}",
      "SSLProxy": "${PROXY_HOST}:${PROXY_PORT}",
      "UseHTTPProxyForAllProtocols": true,
      "Passthrough": "localhost, 127.0.0.1, ::1",
      "Locked": true
    },
    "Certificates": {
      "ImportEnterpriseRoots": true,
      "Install": ["${CA_DEST}"]
    }
  }
}
EOF
chmod 0644 "$FF_POLICY"
echo "wrote $FF_POLICY"

cat <<EOF

guest-proxy-setup.sh: done.
  Proxy       : ${PROXY_URL}
  Env snippet : ${PROFILE_SNIPPET}   (new logins; 'source' it for this shell)
  Firefox pol : ${FF_POLICY}
  CA cert     : ${CA_DEST}

Open a NEW shell / restart Firefox so the settings take effect.
Run 'sudo bin/guest-proxy-setup.sh --off' to remove everything.
EOF

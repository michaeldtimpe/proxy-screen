#!/usr/bin/env bash
#
# proxy.sh - Host-side launcher for the redirect-chain MITM proxy.
#
# Starts mitmdump on the macOS host with the redirect-log addon loaded. The
# arm64 Linux guest (booted by boot.sh under QEMU) reaches this proxy through
# the QEMU user-net gateway 10.0.2.2, so inside the guest the proxy address is
# 10.0.2.2:${PROXY_PORT}. Redirect events land under sessions/<session>/proxy/.
#
# Env:
#   SESSION      session name -> sessions/<name>/proxy  (default: adhoc)
#   PROXY_PORT   listen port on the host                 (default: 8080)
#
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION="${SESSION:-adhoc}"
PROXY_PORT="${PROXY_PORT:-8080}"
PROXY_DIR="sessions/${SESSION}/proxy"
LOG_JSONL="${PROXY_DIR}/redirects.jsonl"

usage() {
  cat <<EOF
proxy.sh - launch the redirect-chain MITM proxy on the host

Usage: ./proxy.sh [--help]

Environment:
  SESSION      session name (logs go to sessions/<name>/proxy)  [default: adhoc]
  PROXY_PORT   host listen port                                  [default: 8080]

Requires mitmproxy (mitmdump). If it is not installed:
    brew install mitmproxy

Logs:
  ${LOG_JSONL}   (JSONL, one event per hop)
  ${PROXY_DIR}/redirects.txt     (human-readable)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "proxy.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

# ---- require mitmdump; do NOT try to install it ------------------------------
if ! command -v mitmdump >/dev/null 2>&1; then
  cat >&2 <<EOF
proxy.sh: 'mitmdump' not found on this host.

mitmproxy is required to run the decrypted redirect-chain proxy, but it is not
installed here. Install it and re-run:

    brew install mitmproxy

(This launcher will not install anything for you.)
EOF
  exit 3
fi

cd "$PROJ"
mkdir -p "$PROXY_DIR"

# ---- clean shutdown: report where the logs went -----------------------------
on_exit() {
  echo ""
  echo "proxy.sh: stopped. Redirect logs written to:"
  echo "    $PROJ/${LOG_JSONL}"
  echo "    $PROJ/${PROXY_DIR}/redirects.txt"
}
trap on_exit EXIT

# ---- guest-side hint block ---------------------------------------------------
cat <<EOF
==============================================================================
 Redirect-chain proxy starting on the host.

   Host listen : 127.0.0.1:${PROXY_PORT}
   Guest proxy : 10.0.2.2:${PROXY_PORT}   (QEMU user-net gateway)
   Session     : ${SESSION}
   Logs        : ${LOG_JSONL}

 Inside the guest:
   1. Point the proxy at  10.0.2.2:${PROXY_PORT}  and configure trust by running:
          sudo PROXY_PORT=${PROXY_PORT} bin/guest-proxy-setup.sh
   2. The mitmproxy CA is fetched inside the guest from  http://mitm.it/
      while proxied (guest-proxy-setup.sh does this via http://mitm.it/cert/pem).

 Press Ctrl-C to stop.
==============================================================================
EOF

# ---- launch ------------------------------------------------------------------
REDIRECT_LOG="${LOG_JSONL}" mitmdump \
  -s bin/redirect-log.py \
  --listen-host 127.0.0.1 \
  --listen-port "${PROXY_PORT}" \
  --set stream_large_bodies=1m

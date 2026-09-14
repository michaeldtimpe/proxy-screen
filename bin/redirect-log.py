#!/usr/bin/env python3
"""
redirect-log.py - mitmproxy addon that records browser redirect chains.

Load with:  mitmdump -s bin/redirect-log.py

For every flow it emits, on `response`, one JSONL event capturing the
server-side hop (method, full URL, host/SNI, status, and the `Location`
header when the status is 3xx). It additionally best-effort scans HTML
response bodies for CLIENT-side redirects:

  * <meta http-equiv="refresh" ... url=...>   -> type "meta-refresh"
  * location.href= / location.replace( / window.location=  -> type "js-redirect"

Output:
  * JSONL  -> $REDIRECT_LOG            (default ./redirects.jsonl)
  * text   -> sibling <basename>.txt   (same directory + basename, .txt)

Parent directories are created as needed. Body scanning is wrapped in
try/except so a malformed page can never take the addon (or the proxy) down.

Purpose in this project: sandbox detonators tend to be served a plain landing
page, whereas a real host is walked further down the redirect chain -- so the
shape of the chain is itself the signal. stdlib + mitmproxy only.
"""

import datetime
import json
import os
import re
import sys

# ---------------------------------------------------------------------------
# Client-side redirect patterns (compiled once, case-insensitive).
# ---------------------------------------------------------------------------
_META_REFRESH_RE = re.compile(
    r"""<meta\b[^>]*?http-equiv\s*=\s*["']?\s*refresh\s*["']?[^>]*?"""
    r"""content\s*=\s*["']([^"']+)["']""",
    re.IGNORECASE | re.DOTALL,
)
# content attr looks like:  0; url=https://example/next   (quotes optional)
_META_URL_RE = re.compile(r"""url\s*=\s*['"]?([^'";>\s]+)""", re.IGNORECASE)

_JS_REDIRECT_RES = (
    re.compile(r"""location\s*\.\s*href\s*=\s*["']([^"']+)["']""", re.IGNORECASE),
    re.compile(r"""location\s*\.\s*replace\s*\(\s*["']([^"']+)["']""", re.IGNORECASE),
    re.compile(r"""window\s*\.\s*location\s*=\s*["']([^"']+)["']""", re.IGNORECASE),
)

# Cap how much body we scan; client-side redirects live in the <head>.
_MAX_SCAN_BYTES = 262144


def _utcnow_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


class RedirectLog:
    def __init__(self):
        self.jsonl_path = None
        self.txt_path = None

    # -- lifecycle ----------------------------------------------------------
    def load(self, loader):
        # Resolve paths once at startup; REDIRECT_LOG is set by proxy.sh.
        self._resolve_paths()

    def _resolve_paths(self):
        jsonl = os.environ.get("REDIRECT_LOG", "./redirects.jsonl")
        self.jsonl_path = jsonl
        # Sibling text file: same dir + basename, .txt extension.
        self.txt_path = os.path.splitext(jsonl)[0] + ".txt"
        parent = os.path.dirname(os.path.abspath(jsonl))
        try:
            if parent:
                os.makedirs(parent, exist_ok=True)
        except OSError as exc:  # pragma: no cover - fs edge case
            sys.stderr.write("redirect-log: cannot create %s: %s\n" % (parent, exc))

    # -- hooks --------------------------------------------------------------
    def request(self, flow):
        # No emit on request; hook present so the addon observes the full
        # exchange and stays a well-formed request/response addon.
        pass

    def response(self, flow):
        if self.jsonl_path is None:
            self._resolve_paths()

        base = self._base_event(flow)

        # 1) Server-side hop (always emitted).
        status = base.get("status_code")
        server_event = dict(base)
        server_event["type"] = "response"
        if isinstance(status, int) and 300 <= status < 400:
            try:
                server_event["location"] = flow.response.headers.get("Location")
            except Exception:
                server_event["location"] = None
        self._emit(server_event)

        # 2) Client-side redirects (best effort, never fatal).
        try:
            for ev in self._scan_client_redirects(flow, base):
                self._emit(ev)
        except Exception as exc:  # pragma: no cover - defensive
            sys.stderr.write("redirect-log: body scan failed: %s\n" % exc)

    # -- helpers ------------------------------------------------------------
    def _base_event(self, flow):
        req = flow.request
        resp = flow.response
        # SNI (TLS) when available, else the request host.
        sni = None
        try:
            sni = getattr(flow.client_conn, "sni", None)
        except Exception:
            sni = None
        host = None
        try:
            host = req.pretty_host
        except Exception:
            host = getattr(req, "host", None)
        status_code = None
        if resp is not None:
            try:
                status_code = int(resp.status_code)
            except Exception:
                status_code = None
        return {
            "ts": _utcnow_iso(),
            "flow_id": getattr(flow, "id", None),
            "method": getattr(req, "method", None),
            "url": self._pretty_url(req),
            "host": host,
            "sni": sni,
            "status_code": status_code,
        }

    @staticmethod
    def _pretty_url(req):
        try:
            return req.pretty_url
        except Exception:
            try:
                return req.url
            except Exception:
                return None

    def _scan_client_redirects(self, flow, base):
        resp = flow.response
        if resp is None:
            return []
        ctype = ""
        try:
            ctype = resp.headers.get("content-type", "") or ""
        except Exception:
            ctype = ""
        if "text/html" not in ctype.lower():
            return []

        # Decode body defensively; get_text handles content-encoding.
        html = None
        try:
            html = resp.get_text(strict=False)
        except Exception:
            try:
                raw = resp.raw_content or b""
                html = raw.decode("utf-8", "replace")
            except Exception:
                html = None
        if not html:
            return []
        if len(html) > _MAX_SCAN_BYTES:
            html = html[:_MAX_SCAN_BYTES]

        events = []

        # meta refresh
        try:
            m = _META_REFRESH_RE.search(html)
            if m:
                content = m.group(1)
                target = None
                um = _META_URL_RE.search(content)
                if um:
                    target = um.group(1).strip()
                ev = dict(base)
                ev["type"] = "meta-refresh"
                ev["target"] = target
                ev["raw"] = content.strip()[:256]
                events.append(ev)
        except Exception:
            pass

        # JS redirects
        try:
            for rex in _JS_REDIRECT_RES:
                jm = rex.search(html)
                if jm:
                    ev = dict(base)
                    ev["type"] = "js-redirect"
                    ev["target"] = jm.group(1).strip()
                    events.append(ev)
                    break  # one is enough to flag the page
        except Exception:
            pass

        return events

    def _emit(self, event):
        # JSONL line.
        try:
            with open(self.jsonl_path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(event, ensure_ascii=False, sort_keys=True) + "\n")
        except Exception as exc:  # pragma: no cover
            sys.stderr.write("redirect-log: jsonl write failed: %s\n" % exc)

        # Compact human-readable line.
        try:
            with open(self.txt_path, "a", encoding="utf-8") as fh:
                fh.write(self._human_line(event) + "\n")
        except Exception as exc:  # pragma: no cover
            sys.stderr.write("redirect-log: txt write failed: %s\n" % exc)

    @staticmethod
    def _human_line(ev):
        ts = ev.get("ts", "")
        etype = ev.get("type", "?")
        method = ev.get("method", "")
        url = ev.get("url", "")
        parts = ["%s [%s]" % (ts, etype)]
        if etype == "response":
            status = ev.get("status_code")
            line = "%s %s -> %s" % (method or "", url or "", status)
            if ev.get("location"):
                line += "  Location: %s" % ev["location"]
            parts.append(line)
        else:
            # meta-refresh / js-redirect
            parts.append("%s => %s" % (url or "", ev.get("target") or "?"))
        return " ".join(parts)


addons = [RedirectLog()]

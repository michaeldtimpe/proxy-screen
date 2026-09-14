#!/usr/bin/env python3
"""
capture.py - Phase 2 non-destructive QMP screendump.

Opens a fresh connection to a QMP unix socket, performs the greeting/
qmp_capabilities handshake, sends a single `screendump` (optionally targeting
a specific display device/head), then closes the connection WITHOUT sending
`quit`. The guest keeps running.

Usage: capture.py <qmp_sock_path> <out_png_abs_path> [device_id]

Prints on success:
    LATENCY_MS: <float>
and exits 0. On any QMP-level error (bad socket, screendump error return),
prints a clear message to stderr and exits nonzero.
"""
import socket
import json
import sys
import time


def recv_json(f):
    line = f.readline()
    if not line:
        return None
    return json.loads(line)


def send(s, f, obj):
    s.sendall((json.dumps(obj) + "\n").encode())
    return recv_json(f)


def main():
    if len(sys.argv) < 3:
        print("usage: capture.py <qmp_sock> <out_png_abs> [device_id]", file=sys.stderr)
        return 2

    sock_path = sys.argv[1]
    out_png = sys.argv[2]
    device_id = sys.argv[3] if len(sys.argv) > 3 else None

    if not out_png.startswith("/"):
        print("capture.py: out path must be absolute: %s" % out_png, file=sys.stderr)
        return 2

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect(sock_path)
    except OSError as e:
        print("capture.py: could not connect to QMP socket %s: %s" % (sock_path, e), file=sys.stderr)
        return 3

    try:
        f = s.makefile("r")

        greeting = recv_json(f)
        if not greeting:
            print("capture.py: no QMP greeting from %s (is a VM running?)" % sock_path, file=sys.stderr)
            return 4

        caps = send(s, f, {"execute": "qmp_capabilities"})
        if not caps or "return" not in caps:
            print("capture.py: qmp_capabilities failed: %s" % json.dumps(caps), file=sys.stderr)
            return 4

        args = {"filename": out_png, "format": "png"}
        if device_id:
            args["device"] = device_id

        t0 = time.time()
        r = send(s, f, {"execute": "screendump", "arguments": args})
        t1 = time.time()

        if not r or "return" not in r:
            print("capture.py: screendump QMP error: %s" % json.dumps(r), file=sys.stderr)
            return 5

        print("LATENCY_MS: %.1f" % ((t1 - t0) * 1000.0))
        return 0
    finally:
        # Deliberately NOT sending {"execute": "quit"}. Just close our fd;
        # the VM keeps running and the server,nowait socket accepts the
        # next connection independently.
        try:
            s.close()
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
serialcmd.py - drive a headless guest over a QEMU unix-socket serial console.

Usage:
  serialcmd.py <serial.sock> [--user U] [--pass P] [--timeout S] -- <cmd> [cmd...]

Logs in (if a login prompt appears), runs each command, and prints the output
between unique markers. Idempotent-ish: sends a newline first; if already at a
shell prompt it just runs the commands.
"""
import socket, sys, time, re, argparse

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sock")
    ap.add_argument("--user", default="analyst")
    ap.add_argument("--pass", dest="password", default="analyst")
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("cmds", nargs="+")
    args = ap.parse_args()

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(args.sock)
    s.setblocking(False)
    buf = ""

    def read(dur):
        nonlocal buf
        end = time.time() + dur
        while time.time() < end:
            try:
                d = s.recv(65536)
                if d:
                    buf += d.decode("utf-8", "replace")
            except BlockingIOError:
                time.sleep(0.1)
            except Exception:
                time.sleep(0.1)
        return buf

    def send(x):
        s.sendall(x.encode())

    deadline = time.time() + args.timeout
    logged_in = False
    # Nudge the console and figure out where we are.
    send("\n")
    while time.time() < deadline:
        read(2)
        tail = buf[-400:]
        if re.search(r"login:\s*$", tail):
            send(args.user + "\n"); read(2)
            send(args.password + "\n"); read(3)
            buf = ""
            send("\n")
            read(2)
            tail = buf[-400:]
        if ("PROMPT>" in tail or re.search(r"[\$#]\s*$", tail)
                or re.search(r"@[\w.-]+:.*[\$#]", tail)):
            logged_in = True
            break
        # Incorrect login / retry
        send("\n")

    if not logged_in:
        print("=== NOT_LOGGED_IN ===")
        print(buf[-1500:])
        s.close()
        sys.exit(3)

    # Set a stable, quiet prompt.
    send("export PS1='PROMPT> '\n")
    read(1)
    buf = ""

    for cmd in args.cmds:
        marker = "___END_%d___" % int(time.time() * 1000)
        buf = ""
        send("%s ; echo %s\n" % (cmd, marker))
        end = time.time() + 60
        while time.time() < end:
            read(1)
            if marker in buf:
                break
        out = buf
        # strip the echoed command line and the marker echo line
        out = out.replace(marker, "")
        print("### CMD: %s" % cmd)
        # remove first line (the echoed command) heuristically
        lines = out.splitlines()
        lines = [l for l in lines if "echo ___END_" not in l and l.strip() != cmd]
        print("\n".join(lines).strip())
        print("### END")
    s.close()

if __name__ == "__main__":
    main()

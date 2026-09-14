#!/usr/bin/env python3
"""
session-meta.py - write/update sessions/<name>/session.json provenance
metadata (stdlib only, no venv required).

Records who/what/when produced a session's frames: when it was created,
which host and QEMU build ran it, which git revision of this repo, an
optional free-text note, and the capture parameters (interval/duration)
that were used.

CLI:
    session-meta.py write --session <name> [--note "text"]
                           [--interval N] [--duration N]

Also importable as a library:
    from session_meta import write_session_meta  # if imported by path
    write_session_meta(proj_root, "my-session", note="...", interval=5)
"""

import argparse
import json
import platform
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

TOOL_NAME = "proxy-screen"


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _host_str() -> str:
    try:
        node = platform.node() or "unknown-host"
    except Exception:
        node = "unknown-host"
    try:
        plat = platform.platform()
    except Exception:
        plat = "unknown-platform"
    return f"{node} ({plat})"


def _qemu_version() -> "str | None":
    """Best-effort first line of `qemu-system-aarch64 --version`, else None."""
    try:
        proc = subprocess.run(
            ["qemu-system-aarch64", "--version"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    first_line = proc.stdout.strip().splitlines()[0] if proc.stdout.strip() else ""
    return first_line or None


def _git_rev(proj_root: Path) -> "str | None":
    """Best-effort `git rev-parse --short HEAD` run inside proj_root, else None."""
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=str(proj_root),
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    rev = proc.stdout.strip()
    return rev or None


def write_session_meta(
    proj_root: Path,
    session: str,
    note: "str | None" = None,
    interval: "int | None" = None,
    duration: "int | None" = None,
) -> dict:
    """Create or update sessions/<session>/session.json under proj_root.

    Preserves created_utc across repeated calls and merges: any of
    note/interval/duration left as None keeps the previously stored value
    (if any) instead of clobbering it.
    """
    session_dir = Path(proj_root) / "sessions" / session
    session_dir.mkdir(parents=True, exist_ok=True)
    meta_path = session_dir / "session.json"

    existing = {}
    if meta_path.is_file():
        try:
            existing = json.loads(meta_path.read_text())
        except (OSError, json.JSONDecodeError):
            existing = {}

    created_utc = existing.get("created_utc") or _utc_now_iso()

    data = {
        "session": session,
        "created_utc": created_utc,
        "host": _host_str(),
        "qemu_version": _qemu_version(),
        "git_rev": _git_rev(Path(proj_root)),
        "note": note if note is not None else existing.get("note"),
        "interval": interval if interval is not None else existing.get("interval"),
        "duration": duration if duration is not None else existing.get("duration"),
        "tool": TOOL_NAME,
    }

    meta_path.write_text(json.dumps(data, indent=2) + "\n")
    return data


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="session-meta.py",
        description="Write/update sessions/<name>/session.json provenance metadata.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_write = sub.add_parser("write", help="Create or update session.json for a session")
    p_write.add_argument("--session", required=True, help="Session directory name under ./sessions/")
    p_write.add_argument("--note", default=None, help="Free-text note to store")
    p_write.add_argument("--interval", type=int, default=None, help="Capture interval in seconds")
    p_write.add_argument("--duration", type=int, default=None, help="Planned total duration in seconds")

    args = parser.parse_args(argv)
    proj_root = Path(__file__).resolve().parent.parent

    if args.command == "write":
        data = write_session_meta(
            proj_root,
            args.session,
            note=args.note,
            interval=args.interval,
            duration=args.duration,
        )
        meta_path = proj_root / "sessions" / args.session / "session.json"
        print(f"wrote {meta_path}")
        json.dump(data, sys.stdout, indent=2)
        print()


if __name__ == "__main__":
    main()

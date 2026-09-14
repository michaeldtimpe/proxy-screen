#!/usr/bin/env python3
"""
Phase 3 offline review pipeline.

Given a session directory (sessions/<name>/), for every frame in
timestamp order:
  - normalize non-PNG frames to PNG (ImageMagick `convert`) as a safety step
  - OCR the frame with tesseract, writing a per-frame .txt sidecar
  - compute a perceptual hash (phash) and compare it to the previous KEPT
    frame's hash using Hamming distance; mark changed=true when the
    distance exceeds a small threshold (near-duplicate frames collapse
    to changed=false)
  - emit sessions/<name>/analysis/manifest.json describing every frame

This script never touches the VM. It only reads PNGs already on disk.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

try:
    import imagehash
    from PIL import Image
except ImportError:
    sys.stderr.write(
        "error: imagehash/pillow not importable. Run this via the project "
        "venv (.venv/bin/python3) after: .venv/bin/pip install imagehash pillow\n"
    )
    sys.exit(1)

HAMMING_CHANGE_THRESHOLD = 5
TIMESTAMP_RE = re.compile(r"frame_(\d{8}T\d{6}Z)_(\d+)\.\w+$")
OCR_TRIM_CHARS = 4000  # cap ocr_text stored in manifest to keep it readable


def parse_frame_name(path: Path):
    """Extract (timestamp_str, seq_int) from a frame filename, else fall
    back to lexical order so unexpected names don't crash the pipeline."""
    m = TIMESTAMP_RE.search(path.name)
    if m:
        return m.group(1), int(m.group(2))
    return path.name, 0


def ensure_png(path: Path) -> Path:
    """Convert non-PNG frames to PNG in place (safety step). Returns the
    path to the PNG file to use going forward."""
    if path.suffix.lower() == ".png":
        return path
    png_path = path.with_suffix(".png")
    subprocess.run(["convert", str(path), str(png_path)], check=True)
    return png_path


def run_ocr(png_path: Path) -> str:
    """Run tesseract on the frame, writing a sidecar <frame.png>.txt and
    returning the extracted text."""
    # tesseract's output-base argument gets ".txt" appended automatically,
    # so pass the full "frame.png" path as the base to land on "frame.png.txt".
    out_base = png_path  # tesseract will write str(png_path) + ".txt"
    subprocess.run(
        ["tesseract", str(png_path), str(out_base), "--psm", "6"],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    sidecar = Path(str(png_path) + ".txt")
    text = sidecar.read_text(encoding="utf-8", errors="replace")
    return text


def format_timestamp(ts_raw: str) -> str:
    """Turn 'YYYYMMDDTHHMMSSZ' into an ISO-8601-ish readable string."""
    m = re.match(r"(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z", ts_raw)
    if not m:
        return ts_raw
    y, mo, d, h, mi, s = m.groups()
    return f"{y}-{mo}-{d}T{h}:{mi}:{s}Z"


def build_manifest(session_dir: Path) -> list:
    frames_dir = session_dir / "frames"
    analysis_dir = session_dir / "analysis"
    analysis_dir.mkdir(parents=True, exist_ok=True)

    frame_paths = sorted(
        [p for p in frames_dir.iterdir() if p.suffix.lower() in (".png", ".ppm", ".bmp", ".jpg", ".jpeg")],
        key=lambda p: parse_frame_name(p),
    )

    manifest = []
    prev_hash = None
    for path in frame_paths:
        png_path = ensure_png(path)
        ts_raw, seq = parse_frame_name(png_path)
        timestamp = format_timestamp(ts_raw)

        phash = imagehash.phash(Image.open(png_path))
        if prev_hash is None:
            hamming = 0
            changed = True  # first frame is always a "change" (session start)
        else:
            hamming = int(phash - prev_hash)
            changed = hamming > HAMMING_CHANGE_THRESHOLD

        ocr_text = run_ocr(png_path)
        trimmed = ocr_text.strip()
        if len(trimmed) > OCR_TRIM_CHARS:
            trimmed = trimmed[:OCR_TRIM_CHARS] + "...(truncated)"

        manifest.append(
            {
                "seq": seq,
                "filename": png_path.name,
                "timestamp": timestamp,
                "phash": str(phash),
                "hamming_from_prev": hamming,
                "changed": changed,
                "ocr_text": trimmed,
                "ocr_charcount": len(ocr_text.strip()),
            }
        )

        # Only advance the "previous kept frame" pointer when the frame
        # actually changed (or it's the first frame) -- this is what makes
        # runs of near-identical frames dedup against the *last real
        # change* rather than drifting frame-to-frame.
        if changed:
            prev_hash = phash

    manifest_path = analysis_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2))
    return manifest


def main():
    parser = argparse.ArgumentParser(description="Build the review manifest for a capture session.")
    parser.add_argument("session_dir", help="Path to sessions/<name>")
    args = parser.parse_args()

    session_dir = Path(args.session_dir).resolve()
    if not (session_dir / "frames").is_dir():
        sys.stderr.write(f"error: no frames/ dir under {session_dir}\n")
        sys.exit(1)

    manifest = build_manifest(session_dir)
    print(f"wrote {len(manifest)} frame entries to {session_dir / 'analysis' / 'manifest.json'}")


if __name__ == "__main__":
    main()

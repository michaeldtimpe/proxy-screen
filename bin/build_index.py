#!/usr/bin/env python3
"""
Build sessions/<name>/analysis/index.html: a self-contained timeline view
of a session's frames, reading the manifest.json that pipeline.py produced.

No external CSS/JS -- everything is inlined so the file is viewable by
just opening it in a browser, no server needed.
"""

import argparse
import html
import json
import sys
from pathlib import Path

CSS = """
body { font-family: -apple-system, Helvetica, Arial, sans-serif; background: #1b1d21; color: #e8e8e8; margin: 0; padding: 24px; }
h1 { font-size: 20px; margin: 0 0 4px 0; }
.sub { color: #9aa0a6; font-size: 13px; margin-bottom: 20px; }
.frame { display: flex; gap: 16px; background: #24262b; border: 1px solid #34363b; border-radius: 8px; padding: 14px; margin-bottom: 14px; }
.frame img { width: 320px; height: 200px; object-fit: cover; border-radius: 4px; border: 1px solid #3a3d43; flex-shrink: 0; }
.meta { flex: 1; min-width: 0; }
.meta-row { display: flex; align-items: center; gap: 10px; margin-bottom: 6px; }
.seq { font-weight: 600; color: #cfd2d6; }
.ts { color: #9aa0a6; font-size: 13px; font-family: ui-monospace, monospace; }
.badge { display: inline-block; font-size: 11px; font-weight: 700; letter-spacing: .03em; padding: 2px 8px; border-radius: 999px; }
.badge.changed { background: #3a2e12; color: #f2b94b; border: 1px solid #6b4f14; }
.badge.same { background: #1c2a20; color: #6fbf7a; border: 1px solid #2c4a33; }
.hash { color: #6b6f76; font-size: 11px; font-family: ui-monospace, monospace; margin-bottom: 8px; }
.ocr { background: #1a1c20; border: 1px solid #303338; border-radius: 4px; padding: 8px 10px; font-family: ui-monospace, monospace; font-size: 12px; white-space: pre-wrap; max-height: 160px; overflow-y: auto; color: #c7cad0; }
.ocr.empty { color: #5c6067; font-style: italic; }
"""


def render(session_name: str, manifest: list) -> str:
    rows = []
    for entry in manifest:
        badge = (
            '<span class="badge changed">CHANGED</span>'
            if entry["changed"]
            else '<span class="badge same">same</span>'
        )
        ocr = html.escape(entry["ocr_text"]) if entry["ocr_text"] else ""
        ocr_class = "ocr" if entry["ocr_text"] else "ocr empty"
        ocr_display = ocr if entry["ocr_text"] else "(no OCR text detected)"
        rows.append(
            f"""
    <div class="frame">
      <img src="../frames/{html.escape(entry['filename'])}" loading="lazy" alt="frame {entry['seq']}">
      <div class="meta">
        <div class="meta-row">
          <span class="seq">#{entry['seq']:03d}</span>
          <span class="ts">{html.escape(entry['timestamp'])}</span>
          {badge}
        </div>
        <div class="hash">phash={html.escape(entry['phash'])} hamming_from_prev={entry['hamming_from_prev']} ocr_chars={entry['ocr_charcount']}</div>
        <div class="{ocr_class}">{ocr_display}</div>
      </div>
    </div>"""
        )

    changed_count = sum(1 for e in manifest if e["changed"])
    return f"""<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Session review: {html.escape(session_name)}</title>
<style>{CSS}</style>
</head>
<body>
  <h1>Session: {html.escape(session_name)}</h1>
  <div class="sub">{len(manifest)} frames captured, {changed_count} marked changed (dedup collapses the rest)</div>
  {''.join(rows)}
</body>
</html>
"""


def main():
    parser = argparse.ArgumentParser(description="Build the HTML timeline for a session's analysis.")
    parser.add_argument("session_dir", help="Path to sessions/<name>")
    args = parser.parse_args()

    session_dir = Path(args.session_dir).resolve()
    manifest_path = session_dir / "analysis" / "manifest.json"
    if not manifest_path.is_file():
        sys.stderr.write(f"error: {manifest_path} not found -- run pipeline.py first\n")
        sys.exit(1)

    manifest = json.loads(manifest_path.read_text())
    index_path = session_dir / "analysis" / "index.html"
    index_path.write_text(render(session_dir.name, manifest))
    print(f"wrote {index_path}")


if __name__ == "__main__":
    main()

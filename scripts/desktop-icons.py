#!/usr/bin/env python3
"""Renders the desktop icons from the Medut mark (design/icon/medut-icon.svg).

    scripts/desktop-icons.py

Writes:
  linux/tray/{online,offline,call,missed}.png    tray icon per state (Linux)
  windows/tray/{online,offline,call,missed}.ico  the same for Windows
  linux/medut.png                                 window and launcher icon
  windows/runner/resources/app_icon.ico           the .exe's icon

Needs ImageMagick 7 (`magick`) with an SVG delegate. The outputs are
committed; run this again only when the mark changes. The tray icons are
installed into the bundle's data/tray (each CMakeLists.txt), not Flutter
assets, so the phone apps do not carry them.
"""
import os
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MARK = """
  <g fill="none" stroke="#FFFFFF" stroke-linecap="round" stroke-linejoin="round" transform="translate(-0.15 -1)">
    <path d="M34 78 V33 a9 9 0 0 1 9 -9 h3" stroke-width="8"/>
    <path d="M52 41 a13 13 0 0 1 0 18" stroke-width="6.5"/>
    <path d="M60 33 a24 24 0 0 1 0 34" stroke-width="6.5"/>
  </g>"""

# Brand cyan when registered, grey when no account is, the call green during
# a call; missed calls add a red dot.
STATES = {
    "online": ("#0F8EB8", False),
    "offline": ("#7A8794", False),
    "call": ("#16A34A", False),
    "missed": ("#0F8EB8", True),
}


def svg(fill, dot):
    badge = '<circle cx="80" cy="20" r="17" fill="#DC2626" stroke="#FFFFFF" stroke-width="5"/>' if dot else ""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="512" height="512">
  <rect width="100" height="100" rx="22.5" fill="{fill}"/>{MARK}
  {badge}
</svg>"""


def render(src, out, size):
    subprocess.run(["magick", "-background", "none", "-density", "384", src, "-resize", f"{size}x{size}", out], check=True)


def ico(src, out, sizes=(16, 20, 24, 32, 40, 48, 64)):
    with tempfile.TemporaryDirectory() as tmp:
        pngs = []
        for s in sizes:
            p = os.path.join(tmp, f"{s}.png")
            render(src, p, s)
            pngs.append(p)
        subprocess.run(["magick", *pngs, out], check=True)


def main():
    png_dir = os.path.join(ROOT, "linux", "tray")
    ico_dir = os.path.join(ROOT, "windows", "tray")
    os.makedirs(png_dir, exist_ok=True)
    os.makedirs(ico_dir, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name, (fill, dot) in STATES.items():
            src = os.path.join(tmp, f"{name}.svg")
            with open(src, "w") as f:
                f.write(svg(fill, dot))
            render(src, os.path.join(png_dir, f"{name}.png"), 64)
            ico(src, os.path.join(ico_dir, f"{name}.ico"))
            if name == "online":
                render(src, os.path.join(ROOT, "linux", "medut.png"), 512)
                # Explorer shows the .exe up to 256 px; a tray icon is never above 64.
                ico(src, os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico"),
                    (16, 20, 24, 32, 40, 48, 64, 256))


if __name__ == "__main__":
    main()

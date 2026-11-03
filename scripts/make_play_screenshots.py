"""Crop the iOS screenshots down to Google Play's 2:1 aspect limit.

Play requires 320..3840 px and an aspect ratio no taller than 2:1. The iPhone
6.5" screenshots are 1284x2778 (1:2.16), so they are rejected as-is. Cropping
the status bar and the home indicator off the top and bottom lands on
1284x2568, which is exactly 2:1 and keeps every piece of app UI.

Output: store/play/screenshots/NN-name.png  (24-bit RGB, no alpha)
"""

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = Path(r"C:\H3\APP\APP截图\asc")
OUT = ROOT / "store" / "play" / "screenshots"
OUT.mkdir(parents=True, exist_ok=True)

STATUS_BAR = 110
HOME_INDICATOR = 100

for path in sorted(SRC.glob("*.jpg")):
    img = Image.open(path).convert("RGB")
    w, h = img.size
    top, bottom = STATUS_BAR, h - HOME_INDICATOR
    cropped = img.crop((0, top, w, bottom))
    ratio = cropped.size[1] / cropped.size[0]
    assert ratio <= 2.0, f"{path.name}: ratio {ratio:.3f} still over 2:1"
    dst = OUT / (path.stem.replace("-", "_") + ".png")
    cropped.save(dst, "PNG", optimize=True)
    print(f"{path.name:34s} {img.size} -> {cropped.size}  ratio 1:{ratio:.2f}  "
          f"{(dst.stat().st_size / 1e6):.2f} MB")

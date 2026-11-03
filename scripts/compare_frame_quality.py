"""Compare a WebP frame against the PNG it replaced, at native resolution."""

import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
TMP = Path(r"C:\H3\APP\_macops")
TMP.mkdir(exist_ok=True)


def png_from_git(dir_rel: str, name: str) -> Image.Image:
    out = TMP / ("orig_" + name)
    data = subprocess.run(
        ["git", "show", f"HEAD:{dir_rel}/{name}"],
        cwd=ROOT, capture_output=True, check=True,
    ).stdout
    out.write_bytes(data)
    return Image.open(out).convert("RGBA")


def main(name: str, dir_rel: str = "assets/frames"):
    a = png_from_git(dir_rel, name)
    b = Image.open(ROOT / dir_rel / name.replace(".png", ".webp")).convert("RGBA")
    assert a.size == b.size, (a.size, b.size)

    na = np.asarray(a, dtype=np.float32)
    nb = np.asarray(b, dtype=np.float32)

    # RGB error only where the frame actually paints something.
    mask = na[:, :, 3] > 8
    d = np.abs(na[:, :, :3] - nb[:, :, :3])[mask]
    mse = float((d ** 2).mean())
    psnr = 99.0 if mse == 0 else 10 * np.log10(255.0 ** 2 / mse)
    alpha_diff = float(np.abs(na[:, :, 3] - nb[:, :, 3]).max())
    print(f"{name}: size {a.size}, painted {mask.mean()*100:.1f}% of pixels")
    print(f"  RGB PSNR {psnr:.2f} dB, mean abs err {d.mean():.2f}/255, max {d.max():.0f}")
    print(f"  max alpha error {alpha_diff:.0f}/255")

    # Side-by-side 1:1 crop from the densest painted band. Frames are border
    # overlays, so the median painted pixel can sit inside the transparent hole;
    # the row with the most painted pixels is guaranteed to be on the artwork.
    ys, xs = np.where(mask)
    top, bottom = int(ys.min()), int(ys.max())
    left, right = int(xs.min()), int(xs.max())
    row_counts = mask.sum(axis=1)
    band = int(np.argmax(row_counts))
    band = min(max(band, top), bottom)
    half = 320
    cx = (left + right) // 2
    box = (max(cx - half, 0), max(band - half // 2, 0),
           min(cx + half, a.width), min(band + half // 2, a.height))
    ca, cb = a.crop(box), b.crop(box)
    w, h = ca.size
    canvas = Image.new("RGB", (w * 2 + 12, h), (30, 30, 30))
    for img, x in ((ca, 0), (cb, w + 12)):
        bg = Image.new("RGBA", img.size, (240, 240, 240, 255))
        canvas.paste(Image.alpha_composite(bg, img).convert("RGB"), (x, 0))
    out = TMP / "frame_compare.png"
    canvas.save(out)
    print("  comparison (left PNG, right WebP):", out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "frame_22.png",
         sys.argv[2] if len(sys.argv) > 2 else "assets/frames")

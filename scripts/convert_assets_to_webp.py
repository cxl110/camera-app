"""Re-encode PNG asset folders to WebP.

assets/frames/ was 87 MB of PNG and dominated the install size; these are RGBA
overlays that are 64-94% fully transparent, exactly what WebP handles far better
than PNG. assets/film_presets/ is the same story at a smaller scale.

Usage:
    python scripts/convert_assets_to_webp.py --dir assets/frames --dry-run
    python scripts/convert_assets_to_webp.py --dir assets/frames --apply
    python scripts/convert_assets_to_webp.py --dir assets/film_presets --apply --quality 88

After running, the PNGs still exist: compare quality with
scripts/compare_frame_quality.py, then `git rm` the PNGs and update the asset
paths in lib/ (and frames_meta.json for the border frames).
"""

import argparse
import io
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent


def convert(folder: Path, quality: int, dry_run: bool):
    pngs = sorted(folder.glob("*.png"))
    if not pngs:
        raise SystemExit(f"no PNGs in {folder}")

    before = after = 0
    for src in pngs:
        before += src.stat().st_size
        img = Image.open(src).convert("RGBA")

        if dry_run:
            buf = io.BytesIO()
            img.save(buf, "WEBP", quality=quality, method=6, alpha_quality=100)
            new_size = buf.tell()
        else:
            dst = src.with_suffix(".webp")
            img.save(dst, "WEBP", quality=quality, method=6, alpha_quality=100)
            # Read the file back: prove what we just wrote actually decodes.
            with Image.open(dst) as check:
                if check.size != img.size:
                    raise SystemExit(f"{dst.name}: size changed on write")
                check.load()
            new_size = dst.stat().st_size
        after += new_size
        pct = 100 * (1 - new_size / src.stat().st_size)
        print(f"{src.name:22s} {src.stat().st_size/1e6:6.2f} MB -> {new_size/1e6:6.2f} MB  (-{pct:.0f}%)")

    print(f"\n{folder.relative_to(ROOT)}: {before/1e6:.1f} MB -> {after/1e6:.1f} MB "
          f"(-{100*(1-after/before):.1f}%, saved {(before-after)/1e6:.1f} MB)")
    if dry_run:
        print("dry run: nothing written")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="assets/frames")
    ap.add_argument("--quality", type=int, default=90)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if not args.apply and not args.dry_run:
        raise SystemExit("pass --dry-run or --apply")
    convert(ROOT / args.dir, args.quality, dry_run=not args.apply)

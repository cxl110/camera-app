#!/usr/bin/env python3
"""Generate the EFFECTS-page film preset thumbnails.

Source images live in C:\\H3\\APP\\filmCan (the washed / filtered results) and
are exported to camera_app/assets/film_presets/<snake_case_name>.png, which
`lib/widgets/film_presets.dart` references by path.

The preset card in the app is 72 pt wide, so anything above ~600 px is more
than enough; images are downscaled to that range and never upscaled (an
upscaled 300 px source would just be blur).

Usage:  python scripts/make_film_presets.py
"""

import os

from PIL import Image

FILMCAN = r'C:\H3\APP\filmCan'
OUT_DIR = r'C:\H3\APP\camera_app\assets\film_presets'

# preset name -> (source file in filmCan, output file, target edge length)
# A target of 0 keeps the source resolution.
PRESETS = {
    'CLASSIC CHROME': ('CLASSIC-CHROME-1200.png', 'classic_chrome.png', 707),
    'CLASSIC Neg.':   ('classic-neg.png',         'classic_neg.png',   0),
    'PRO Neg.Hi':     ('PRO-NEG-HI-1200.png',     'pro_neg_hi.png',    707),
}

# The three Fuji simulation cards are square by design — cropping them to the
# portrait shape of the film-box photos would cut the wordmark in half.
CENTER_CROP_ASPECT = None  # keep the whole card


def build(name, src_name, out_name, target):
    src_path = os.path.join(FILMCAN, src_name)
    out_path = os.path.join(OUT_DIR, out_name)
    if not os.path.exists(src_path):
        print(f'SKIP  {name}: source not found -> {src_path}')
        return False

    im = Image.open(src_path)
    if im.mode != 'RGB':
        im = im.convert('RGB')
    before = im.size

    if target and max(im.size) > target:
        scale = target / max(im.size)
        new = (max(1, round(im.width * scale)), max(1, round(im.height * scale)))
        im = im.resize(new, Image.LANCZOS)

    os.makedirs(OUT_DIR, exist_ok=True)
    im.save(out_path, 'PNG', optimize=True)
    after = Image.open(out_path).size
    print(f'OK    {name:16s} {src_name} {before} -> {out_name} {after} '
          f'({os.path.getsize(out_path) // 1024} KB)')
    return True


def main():
    for name, (src, out, target) in PRESETS.items():
        build(name, src, out, target)


if __name__ == '__main__':
    main()

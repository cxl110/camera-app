"""Generate the Google Play store graphics that the console asks for.

Outputs (store/play/):
  icon-512.png                  512x512, 32-bit PNG, no transparency
  feature-graphic-1024x500.png  1024x500, used at the top of the listing

Both are derived from assets/icon.png so the store and the launcher agree.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "icon.png"
OUT = ROOT / "store" / "play"
OUT.mkdir(parents=True, exist_ok=True)

FONT_BOLD = "C:/Windows/Fonts/segoeuib.ttf"
FONT_REG = "C:/Windows/Fonts/segoeui.ttf"

INK = (38, 36, 33)
MUTED = (110, 105, 96)


def studio_background(size, top=(246, 244, 239), bottom=(214, 210, 201)):
    """Vertical gradient that matches the artwork's own studio backdrop."""
    w, h = size
    img = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        img.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img.resize((w, h), Image.BILINEAR)


def make_icon():
    icon = Image.open(SRC).convert("RGB")
    icon = icon.resize((512, 512), Image.LANCZOS)
    icon.save(OUT / "icon-512.png", "PNG", optimize=True)
    print("wrote", (OUT / "icon-512.png").relative_to(ROOT), icon.size)


def make_feature_graphic():
    W, H = 1024, 500
    canvas = studio_background((W, H))

    # The square artwork fills the full height on the left; its own backdrop is
    # the same studio gradient, so it reads as part of the background.
    art = Image.open(SRC).convert("RGB").resize((H, H), Image.LANCZOS)
    canvas.paste(art, (0, 0))

    # Soft seam killer: fade the artwork's right edge into the flat background.
    seam = 120
    bg_right = studio_background((seam, H))
    fade = Image.new("L", (seam, 1))
    for x in range(seam):
        fade.putpixel((x, 0), round(255 * x / (seam - 1)))
    fade = fade.resize((seam, H))
    canvas.paste(bg_right, (H - seam, 0), fade)

    draw = ImageDraw.Draw(canvas)
    title = ImageFont.truetype(FONT_BOLD, 92)
    sub = ImageFont.truetype(FONT_REG, 34)
    tag = ImageFont.truetype(FONT_BOLD, 25)

    x = H + 40
    draw.text((x, 150), "SQ Cam", font=title, fill=INK)
    draw.text((x, 262), "Film looks for your", font=sub, fill=MUTED)
    draw.text((x, 302), "ZIVIGo camera", font=sub, fill=MUTED)
    draw.text((x, 372), "WiFi transfer  ·  Filters run in the app", font=tag, fill=(150, 96, 60))

    canvas.save(OUT / "feature-graphic-1024x500.png", "PNG", optimize=True)
    print("wrote", (OUT / "feature-graphic-1024x500.png").relative_to(ROOT), canvas.size)


if __name__ == "__main__":
    make_icon()
    make_feature_graphic()

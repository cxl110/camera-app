"""Build the Android adaptive-icon foreground from assets/icon.png.

The iOS icon is a full-bleed square: a titanium camera body on a cream studio
backdrop. Android's adaptive icons crop the outer third of the 108dp canvas.

flutter_launcher_icons already wraps the foreground drawable in an <inset>
of 16%, which scales the artwork to 68% of the canvas -- just outside the
visible 66% circle. So the foreground file is simply the full-bleed artwork:
nothing important is cropped, and since the outer third is plain backdrop the
circle mask has nothing to cut. The backdrop colour is sampled from the
artwork so the flat background layer matches if a launcher shows more of it.

Writes:
  assets/icon_foreground.png       (full-bleed artwork, what Android consumes)
  assets/icon_adaptive_preview.png (what the launcher circle mask will show)
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "icon.png"
FG = ROOT / "assets" / "icon_foreground.png"
PREVIEW = ROOT / "assets" / "icon_adaptive_preview.png"

CANVAS = 1024
TOOL_INSET = 0.16  # flutter_launcher_icons <inset android:inset="16%">
SAFE = int(CANVAS * 2 / 3)  # 72dp safe zone of the 108dp canvas

src = Image.open(SRC).convert("RGBA")
if src.size != (CANVAS, CANVAS):
    src = src.resize((CANVAS, CANVAS), Image.LANCZOS)

# Sample the studio backdrop near the four corners (10px inset, clear of the
# rounded highlight right at the edge).
inset = 10
samples = [
    src.getpixel(p)
    for p in (
        (inset, inset),
        (CANVAS - inset - 1, inset),
        (inset, CANVAS - inset - 1),
        (CANVAS - inset - 1, CANVAS - inset - 1),
    )
]
bg = tuple(sum(c[i] for c in samples) // len(samples) for i in range(3))
print("background sampled from corners: #%02X%02X%02X" % bg, samples)

src.save(FG)
print("wrote", FG.relative_to(ROOT), f"{CANVAS}px, full bleed")

# Preview: flat background + artwork scaled by the tool's inset, circle-masked.
art_size = round(CANVAS * (1 - 2 * TOOL_INSET))
art = src.resize((art_size, art_size), Image.LANCZOS)
off = (CANVAS - art_size) // 2
preview = Image.new("RGBA", (CANVAS, CANVAS), bg + (255,))
preview.paste(art, (off, off), art)
mask = Image.new("L", (CANVAS, CANVAS), 0)
ImageDraw.Draw(mask).ellipse(
    ((CANVAS - SAFE) // 2, (CANVAS - SAFE) // 2,
     (CANVAS + SAFE) // 2, (CANVAS + SAFE) // 2),
    fill=255,
)
preview.putalpha(mask)
preview.save(PREVIEW)
print("wrote", PREVIEW.relative_to(ROOT))

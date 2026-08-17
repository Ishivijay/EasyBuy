#!/usr/bin/env python3
"""
Generates the EasyBuy launcher icon at every density Android needs.

The mark is a price tag with a checkmark knocked out of it: the tag says
shopping, the check says "this one is a yes" — which is exactly what the app
produces, a decision rather than just a render. Everything is drawn rather than
shipped as a binary so the icon can be tweaked and regenerated in one command:

    python3 tool/generate_icon.py
"""

from pathlib import Path
from PIL import Image, ImageDraw

RES = Path(__file__).resolve().parent.parent / "android/app/src/main/res"

# Matches ClosetTheme.coral and its darker partner in the app theme.
GRADIENT_TOP = (255, 138, 92)
GRADIENT_BOTTOM = (224, 74, 38)

# Legacy square launcher icon, per density.
LAUNCHER_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# Adaptive icons are 108dp; the inner 66dp is the guaranteed-visible safe zone.
ADAPTIVE_SIZES = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}

MASTER = 1024


def gradient(size):
    """
    Diagonal coral gradient: a vertical ramp, rotated, then centre-cropped.

    The ramp is built oversized on purpose — rotating a square exactly the
    target size leaves empty wedges in the corners once it turns.
    """
    over = int(size * 1.8)
    ramp = Image.new("RGB", (1, over))
    for y in range(over):
        t = y / max(over - 1, 1)
        ramp.putpixel(
            (0, y),
            tuple(round(a + (b - a) * t) for a, b in zip(GRADIENT_TOP, GRADIENT_BOTTOM)),
        )

    rotated = ramp.resize((over, over)).rotate(-20, resample=Image.BICUBIC, expand=False)
    inset = (over - size) // 2
    return rotated.crop((inset, inset, inset + size, inset + size))


def tag_mask(size, scale=0.62):
    """
    White-on-black mask of the tag glyph, with the string hole and the
    checkmark punched back out to transparent.
    """
    # Supersample so the diagonal edges and the check come out clean.
    ss = 4
    canvas = size * ss
    mask = Image.new("L", (canvas, canvas), 0)
    draw = ImageDraw.Draw(mask)

    box = canvas * scale
    left = (canvas - box) / 2
    top = (canvas - box) / 2

    def point(nx, ny):
        return (left + nx * box, top + ny * box)

    # Tag body: a rounded rectangle with a triangular point on the left.
    body = [point(0.34, 0.10), point(0.98, 0.90)]
    draw.rounded_rectangle(
        [body[0][0], body[0][1], body[1][0], body[1][1]],
        radius=box * 0.11,
        fill=255,
    )
    draw.polygon([point(0.42, 0.12), point(0.42, 0.88), point(0.02, 0.50)], fill=255)

    # String hole.
    hole_c = point(0.40, 0.50)
    hole_r = box * 0.052
    draw.ellipse(
        [hole_c[0] - hole_r, hole_c[1] - hole_r, hole_c[0] + hole_r, hole_c[1] + hole_r],
        fill=0,
    )

    # Checkmark, knocked out so the gradient shows through the tag.
    draw.line(
        [point(0.57, 0.52), point(0.66, 0.64), point(0.86, 0.34)],
        fill=0,
        width=round(box * 0.10),
        joint="curve",
    )

    return mask.resize((size, size), Image.LANCZOS)


def launcher_icon(size):
    """Full-bleed rounded-square icon for pre-adaptive launchers."""
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    ss = 4
    corner = Image.new("L", (size * ss, size * ss), 0)
    ImageDraw.Draw(corner).rounded_rectangle(
        [0, 0, size * ss - 1, size * ss - 1], radius=size * ss * 0.22, fill=255
    )
    corner = corner.resize((size, size), Image.LANCZOS)

    background = gradient(size).convert("RGBA")
    background.putalpha(corner)
    icon.alpha_composite(background)

    glyph = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    glyph.putalpha(tag_mask(size, scale=0.62))
    icon.alpha_composite(glyph)
    return icon


def adaptive_foreground(size):
    """Glyph only, sized to sit inside the adaptive safe zone."""
    layer = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    glyph = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    glyph.putalpha(tag_mask(size, scale=0.42))
    layer.alpha_composite(glyph)
    return layer


def adaptive_background(size):
    return gradient(size).convert("RGBA")


def main():
    for folder, size in LAUNCHER_SIZES.items():
        target = RES / folder
        target.mkdir(parents=True, exist_ok=True)
        launcher_icon(size).save(target / "ic_launcher.png")

    for folder, size in ADAPTIVE_SIZES.items():
        target = RES / folder
        target.mkdir(parents=True, exist_ok=True)
        adaptive_foreground(size).save(target / "ic_launcher_foreground.png")
        adaptive_background(size).save(target / "ic_launcher_background.png")

    # Adaptive icon descriptor, used on Android 8 and newer.
    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    descriptor = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@mipmap/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        "</adaptive-icon>\n"
    )
    (anydpi / "ic_launcher.xml").write_text(descriptor)
    (anydpi / "ic_launcher_round.xml").write_text(descriptor)

    # A large version for the README and the Devpost submission.
    preview = Path(__file__).resolve().parent.parent / "icon.png"
    launcher_icon(MASTER).save(preview)
    print(f"wrote icons into {RES} and a {MASTER}px preview at {preview}")


if __name__ == "__main__":
    main()

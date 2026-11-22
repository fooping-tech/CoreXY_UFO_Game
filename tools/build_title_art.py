#!/usr/bin/env python3
"""The title screen's pixel art (#283): turn the pictures made with Codex's image generation
into the game's assets.

    uv run --with pillow python tools/build_title_art.py            # reads assets/source/title/
    uv run --with pillow python tools/build_title_art.py --src DIR  # another folder of pictures

The source pictures (assets/source/title/, as Codex saved them; the prompts are in
assets/source/title/PROMPTS.md) are big and drawn on a fine grid. This brings them to the
game's grid (one picture pixel = SCALE screen pixels on the 720 x 1280 screen) and keeps the
pixels hard:

    bg.png                         the meadow: cut to 9:16 and shrunk to BG_SIZE
    logo.png                       the logo: pixel-art neon letters (no board) on green; the green
                                   made clear, cut to the logo, LOGO_W wide, with a one-pixel dark
                                   rim so the white letters read over the bright sky
    cow / pig / sheep / chick /    the animals: 4 walk frames in a row facing right on magenta;
    bird.png                       each frame made clear, cut and set on its feet (the bird: its
                                   middle), every frame the same size, HEIGHTS[kind] tall

Writes game/assets/title/. Colours are cut down to a small palette per picture, and alpha is
either clear or solid (no soft edges), so the pictures stay pixel art when the game scales them.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "assets" / "source" / "title"
OUT = ROOT / "game" / "assets" / "title"
SCALE = 4
BG_SIZE = (720 // SCALE, 1280 // SCALE)  # 180 x 320
LOGO_W = 660 // SCALE  # the logo is shown 660 px wide (title_screen.gd LOGO_W)
RIM = (18, 10, 58, 255)  # the logo's dark rim
FRAMES = 4
## each animal's height in picture pixels (x SCALE on the screen)
HEIGHTS = {"cow": 30, "pig": 24, "sheep": 26, "chick": 18, "bird": 16}
COLOURS = {"bg": 64, "logo": 32, "animal": 24}


def is_key(p: tuple[int, int, int]) -> bool:
    """The magenta backdrop (and its soft fringe): red and blue high, green low."""
    r, g, b = p[:3]
    return r > 150 and b > 150 and g < 110 and abs(r - b) < 90


def key_out(img: Image.Image) -> Image.Image:
    img = img.convert("RGBA")
    px = img.load()
    for y in range(img.height):
        for x in range(img.width):
            if is_key(px[x, y]):
                px[x, y] = (0, 0, 0, 0)
    return img


def is_green(p: tuple[int, int, int]) -> bool:
    """The logo's green backdrop (the neon is pink, violet and blue, so magenta would not do)."""
    r, g, b = p[:3]
    return g > 150 and r < 130 and b < 130


def rim(img: Image.Image) -> Image.Image:
    """A one-pixel dark rim round everything solid (4 neighbours)."""
    out = img.copy()
    src, dst = img.load(), out.load()
    for y in range(img.height):
        for x in range(img.width):
            if src[x, y][3]:
                continue
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if 0 <= nx < img.width and 0 <= ny < img.height and src[nx, ny][3]:
                    dst[x, y] = RIM
                    break
    return out


def hard(img: Image.Image, colours: int) -> Image.Image:
    """Solid-or-clear alpha and a small palette."""
    img = img.convert("RGBA")
    alpha = img.getchannel("A").point(lambda a: 255 if a >= 128 else 0)
    rgb = img.convert("RGB").quantize(colours, method=Image.Quantize.MEDIANCUT).convert("RGB")
    out = rgb.convert("RGBA")
    out.putalpha(alpha)
    return out


def shrink(img: Image.Image, size: tuple[int, int]) -> Image.Image:
    return img.resize(size, Image.Resampling.BOX)


def cover(img: Image.Image, aspect: float) -> Image.Image:
    """The middle of the picture with this width / height."""
    w, h = img.size
    if w / h > aspect:
        nw = round(h * aspect)
        return img.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
    nh = round(w / aspect)
    return img.crop((0, (h - nh) // 2, w, (h - nh) // 2 + nh))


def build_bg(src: Path) -> Image.Image:
    img = Image.open(src).convert("RGB")
    img = cover(img, BG_SIZE[0] / BG_SIZE[1])
    return hard(shrink(img, BG_SIZE), COLOURS["bg"])


def build_logo(src: Path) -> Image.Image:
    img = Image.open(src).convert("RGBA")
    px = img.load()
    for y in range(img.height):
        for x in range(img.width):
            if is_green(px[x, y]):
                px[x, y] = (0, 0, 0, 0)
    img = img.crop(img.getbbox())
    w = LOGO_W - 2  # the rim adds one pixel each side
    small = hard(shrink(img, (w, round(img.height * w / img.width))), COLOURS["logo"])
    framed = Image.new("RGBA", (small.width + 2, small.height + 2), (0, 0, 0, 0))
    framed.alpha_composite(small, (1, 1))
    return rim(framed)


def build_strip(src: Path, kind: str) -> Image.Image:
    img = key_out(Image.open(src))
    fw = img.width / FRAMES
    frames = []
    for i in range(FRAMES):
        f = img.crop((round(i * fw), 0, round((i + 1) * fw), img.height))
        box = f.getbbox()
        frames.append(f.crop(box) if box else f)
    # one scale for every frame (the tallest frame becomes HEIGHTS[kind])
    tall = max(f.height for f in frames)
    k = HEIGHTS[kind] / tall
    small = [shrink(f, (max(1, round(f.width * k)), max(1, round(f.height * k)))) for f in frames]
    cw = max(f.width for f in small)
    ch = HEIGHTS[kind]
    strip = Image.new("RGBA", (cw * FRAMES, ch), (0, 0, 0, 0))
    fly = kind == "bird"
    for i, f in enumerate(small):
        x = i * cw + (cw - f.width) // 2
        y = (ch - f.height) // 2 if fly else ch - f.height  # the feet on the bottom line
        strip.alpha_composite(f, (x, y))
    return hard(strip, COLOURS["animal"])


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--src", type=Path, default=SRC)
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    build_bg(args.src / "bg.png").save(OUT / "bg.png")
    build_logo(args.src / "logo.png").save(OUT / "logo.png")
    for kind in HEIGHTS:
        path = args.src / f"{kind}.png"
        if path.exists():
            build_strip(path, kind).save(OUT / f"{kind}.png")
    for p in sorted(OUT.glob("*.png")):
        with Image.open(p) as im:
            print(f"{p.relative_to(ROOT)}  {im.width} x {im.height}")


if __name__ == "__main__":
    main()

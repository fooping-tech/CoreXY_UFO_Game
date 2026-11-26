#!/usr/bin/env python3
"""The capsule kinds' pixel-art animations (#266): one sprite sheet per kind.

    python3 tools/build_capsule_sprites.py            # writes game/assets/capsules/
    python3 tools/build_capsule_sprites.py --preview  # also a 4x preview strip of all kinds

Each sheet is FRAMES frames of SIZE x SIZE pixels in a row, two rows (RGBA PNG): the capsule
(the game turns it with the ball) and the kind's own part (drawn over it, kept upright), and a
JSON beside it
({"frame_w", "frame_h", "frames", "fps", "body_r"}). The capsule is a toy-vending capsule: a dark
rim, a coloured lid with a lighter band and a shine, a see-through bottom of tinted plastic, in
the kind's colours, with what makes the kind:

    fire   a crown of flames licking up, embers; a turning bright stripe
    water  a wave running round its middle, droplets circling it
    green  a sprout swaying on top, sparkles blinking round it
    thunder  a lightning bolt flashing up out of the top, sparks crackling round it (#320)
    dark   a purple haze curling up from it, dark motes orbiting it (#320)

Made from code (no drawing program, no outside files), the same every run: change the
numbers here and run it again. Only the standard library (zlib, struct) is used.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "game" / "assets" / "capsules"
SIZE = 32
FRAMES = 8
FPS = 10
CX, CY = 16, 18  # the capsule's centre in a frame
R = 10  # its radius inside the rim (the rim is one more)

Rgba = tuple[int, int, int, int]


def hexc(h: str, a: int = 255) -> Rgba:
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)


INK = hexc("050818")
PURE = hexc("ffffff")

PALETTES = {
    # top / band / stripe: the coloured lid; clear / clear_shade: the see-through bottom (tinted
    # plastic); seam: the ring where they meet
    "fire": {"top": hexc("ff3b1f"), "band": hexc("ff8a4a"), "stripe": hexc("ffd0a0"),
             "clear": hexc("ffd8c8"), "clear_shade": hexc("f0a890"), "seam": hexc("a01808"),
             "fx": [hexc("ff3b1f"), hexc("ff8a1f"), hexc("ffe03c"), hexc("fff6c0")]},
    "water": {"top": hexc("2f6cff"), "band": hexc("6fa8ff"), "stripe": hexc("c8e4ff"),
              "clear": hexc("d4e6ff"), "clear_shade": hexc("a0c0f0"), "seam": hexc("1a3c9a"),
              "fx": [hexc("2f6cff"), hexc("6fc8ff"), hexc("c8f0ff"), PURE]},
    "green": {"top": hexc("1fb84a"), "band": hexc("5ae07a"), "stripe": hexc("d0ffd8"),
              "clear": hexc("d4f8dc"), "clear_shade": hexc("98dca8"), "seam": hexc("0e6a28"),
              "fx": [hexc("1fb84a"), hexc("7dff6a"), hexc("d8ff9a"), PURE]},
    "thunder": {"top": hexc("ffc81f"), "band": hexc("ffe46a"), "stripe": hexc("fff6c0"),
                "clear": hexc("fff4cc"), "clear_shade": hexc("f0d890"), "seam": hexc("a07808"),
                "fx": [hexc("ffb000"), hexc("ffe83a"), hexc("fffbd0"), PURE]},
    "dark": {"top": hexc("6a1fc8"), "band": hexc("a24bff"), "stripe": hexc("dcb8ff"),
             "clear": hexc("e4d4ff"), "clear_shade": hexc("b8a0e8"), "seam": hexc("3a0a78"),
             "fx": [hexc("3a0a78"), hexc("7a2ee0"), hexc("c890ff"), hexc("f0e0ff")]},
}


class Frame:
    def __init__(self) -> None:
        self.px: list[list[Rgba]] = [[(0, 0, 0, 0)] * SIZE for _ in range(SIZE)]

    def put(self, x: float, y: float, c: Rgba) -> None:
        xi, yi = int(round(x)), int(round(y))
        if 0 <= xi < SIZE and 0 <= yi < SIZE:
            self.px[yi][xi] = c

    def get(self, x: int, y: int) -> Rgba:
        return self.px[y][x]


def inside(x: int, y: int, r: float) -> bool:
    dx, dy = x + 0.5 - (CX + 0.5), y + 0.5 - (CY + 0.5)
    return dx * dx + dy * dy <= r * r


def capsule(f: Frame, pal: dict, n: int) -> None:
    """The capsule itself, its top half turning (a bright stripe moving across)."""
    for y in range(SIZE):
        for x in range(SIZE):
            if inside(x, y, R + 1.4) and not inside(x, y, R + 0.4):
                f.put(x, y, INK)
            elif inside(x, y, R + 0.4):
                if y < CY:
                    c = pal["band"] if inside(x, y, R * 0.62) and y < CY - 1 else pal["top"]
                    # the turning stripe: two columns sweeping across the top half
                    s = (x - (CX - R) - n * 3) % 10
                    if s in (0, 1) and y < CY - 1:
                        c = pal["stripe"]
                    f.put(x, y, c)
                elif y == CY:
                    f.put(x, y, pal["seam"])  # the ring where lid and bottom meet
                else:
                    # the see-through bottom: tinted plastic, a shade on its far side and a
                    # glint of light through it
                    shade = (x - CX) + (y - CY) > R * 0.55
                    c = pal["clear_shade"] if shade else pal["clear"]
                    if (x - CX, y - CY) in ((-5, 3), (-4, 4), (-3, 5)):
                        c = PURE
                    f.put(x, y, c)
    # the shine, top left
    for dx, dy in ((-6, -6), (-5, -6), (-4, -6), (-6, -5), (-5, -5), (-6, -4)):
        f.put(CX + dx, CY + dy, PURE)


def fire(f: Frame, pal: dict, n: int) -> None:
    fx = pal["fx"]
    t = n / FRAMES * math.tau
    # flames: a crown over the top half, each column licking up by its own phase
    for x in range(CX - R, CX + R + 1):
        dx = x - CX
        edge = CY - math.sqrt(max(0.0, (R + 1.4) ** 2 - dx * dx))  # the rim's top at this column
        h = 3.0 + 3.5 * abs(math.sin(dx * 0.75 + t)) + 1.5 * abs(math.sin(dx * 1.9 - 2 * t))
        h *= 1.0 - (abs(dx) / (R + 2)) ** 2 * 0.6
        for k in range(int(h)):
            y = edge - 1 - k
            u = k / max(h, 1.0)
            c = fx[2] if u < 0.35 else (fx[1] if u < 0.7 else fx[0])
            if abs(dx) <= 2 and u < 0.2:
                c = fx[3]
            f.put(x, y, c)
    # embers flying up beside it
    for i in range(3):
        a = (n + i * 3) % FRAMES
        x = CX + (-12, 12, 8)[i] + (1 if a % 2 else 0)
        y = CY + 4 - a * 2.5
        f.put(x, y, fx[2] if a < 4 else fx[1])
    # a warm glow along the bottom rim
    for x in range(CX - 6, CX + 7):
        if f.get(x, CY + R + 2)[3] == 0 and (x + n) % 3 == 0:
            f.put(x, CY + R + 2, fx[1])


def water(f: Frame, pal: dict, n: int) -> None:
    fx = pal["fx"]
    t = n / FRAMES * math.tau
    # a wave round its middle, running sideways
    for x in range(CX - R + 1, CX + R):
        y = CY - 2 + round(1.2 * math.sin((x - CX) * 0.9 + t))
        if inside(x, y, R - 0.2):
            f.put(x, y, fx[2])
            if inside(x, y + 1, R - 0.2) and y + 1 < CY:
                f.put(x, y + 1, fx[1])
    # three droplets circling it
    for i in range(3):
        a = t + i * math.tau / 3
        x = CX + math.cos(a) * (R + 4)
        y = CY + math.sin(a) * (R + 2) * 0.55 - 1
        f.put(x, y - 1, fx[2])
        f.put(x, y, fx[1])
        f.put(x, y + 1, fx[0])
    # a bubble rising out of the top
    k = n % FRAMES
    bx, by = CX + 3 + (k % 2), CY - R - 2 - k
    if by >= 0:
        for dx, dy in ((0, -1), (-1, 0), (1, 0), (0, 1)):
            f.put(bx + dx, by + dy, fx[2])


def green(f: Frame, pal: dict, n: int) -> None:
    fx = pal["fx"]
    t = n / FRAMES * math.tau
    sway = round(1.5 * math.sin(t))
    top = CY - R - 1
    # the stem
    for k in range(5):
        f.put(CX + (sway if k > 2 else 0), top - 1 - k, fx[0])
    # two leaves, opening and closing with the sway
    tip_x, tip_y = CX + sway, top - 5
    for k in range(1, 5):
        lift = 1 if k in (2, 3) else 0
        f.put(tip_x - k, tip_y + 1 - lift - (1 if sway < 0 else 0), fx[1] if k < 4 else fx[0])
        f.put(tip_x + k, tip_y + 1 - lift - (1 if sway > 0 else 0), fx[1] if k < 4 else fx[0])
    f.put(tip_x - 2, tip_y - 1, fx[2])
    f.put(tip_x + 2, tip_y - 1, fx[2])
    # sparkles blinking round it (a small plus, its middle white)
    spots = ((-13, -3), (12, 0), (-10, 9), (11, 10))
    for i, (dx, dy) in enumerate(spots):
        if (n + i * 2) % FRAMES < 3:
            x, y = CX + dx, CY + dy
            f.put(x, y, fx[3])
            for ox, oy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                f.put(x + ox, y + oy, fx[1])


def thunder(f: Frame, pal: dict, n: int) -> None:
    fx = pal["fx"]
    top = CY - R - 1
    # a zigzag bolt over the top, flashing: drawn on most frames, brightest on the flash
    if n % FRAMES not in (3, 7):
        flash = n % FRAMES in (0, 4)
        side = -1 if (n // 4) % 2 else 1
        path = [(0, 0), (1 * side, -1), (2 * side, -2), (0, -3), (-1 * side, -4), (1 * side, -5), (2 * side, -6), (0, -7)]
        for dx, dy in path:  # an orange outline first, the bolt over it
            x, y = CX + dx, top + dy
            for ox in (-1, 2):
                f.put(x + ox, y, fx[0])
        for dx, dy in path:
            x, y = CX + dx, top + dy
            f.put(x, y, fx[3] if flash else fx[2])
            f.put(x + 1, y, fx[2] if flash else fx[1])
    # sparks crackling round it: short dashes that jump place every frame
    spots = ((-13, -2), (12, -4), (-11, 8), (12, 9), (-6, -12), (7, -11))
    for i, (dx, dy) in enumerate(spots):
        if (n + i) % 3 == 0:
            x, y = CX + dx, CY + dy
            f.put(x, y, fx[3])
            f.put(x + (1 if i % 2 else -1), y + 1, fx[1])
            f.put(x + (2 if i % 2 else -2), y + 1, fx[0])


def dark(f: Frame, pal: dict, n: int) -> None:
    fx = pal["fx"]
    t = n / FRAMES * math.tau
    top = CY - R - 1
    # a haze curling up from the top: two wisps winding round each other
    for k in range(7):
        y = top - 1 - k
        for w, ph in ((0, 0.0), (1, math.pi)):
            x = CX + round(2.2 * math.sin(k * 0.9 - t + ph))
            f.put(x, y, fx[1] if k < 4 else fx[2])
            if k < 3:
                f.put(x + (1 if w else -1), y, fx[0])
    # dark motes orbiting it on a tilted ring, the near ones light
    for i in range(4):
        a = t + i * math.tau / 4
        x = CX + math.cos(a) * (R + 4)
        y = CY + math.sin(a) * (R + 1) * 0.5 + 2
        near = math.sin(a) > 0
        f.put(x, y, fx[3] if near else fx[0])
        f.put(x + 1, y, fx[2] if near else fx[1])


EXTRA = {"fire": fire, "water": water, "green": green, "thunder": thunder, "dark": dark}


def sheet(kind: str) -> tuple[list[Frame], list[Frame]]:
    """The capsule's frames and the kind's own (flames, drops, sprout) apart: the game turns
    the capsule with the ball and keeps the kind's part upright on it."""
    pal = PALETTES[kind]
    bodies, extras = [], []
    for n in range(FRAMES):
        b = Frame()
        capsule(b, pal, n)
        e = Frame()
        EXTRA[kind](e, pal, n)
        bodies.append(b)
        extras.append(e)
    return bodies, extras


def merged(bodies: list[Frame], extras: list[Frame]) -> list[Frame]:
    out = []
    for b, e in zip(bodies, extras):
        f = Frame()
        for y in range(SIZE):
            for x in range(SIZE):
                f.px[y][x] = e.px[y][x] if e.px[y][x][3] else b.px[y][x]
        out.append(f)
    return out


def png(path: Path, width: int, height: int, rows: list[list[Rgba]]) -> None:
    raw = b"".join(b"\x00" + b"".join(bytes(c) for c in row) for row in rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.write_bytes(data)


def strip(frames: list[Frame], scale: int = 1) -> list[list[Rgba]]:
    rows = []
    for y in range(SIZE * scale):
        row: list[Rgba] = []
        for f in frames:
            for x in range(SIZE * scale):
                row.append(f.px[y // scale][x // scale])
        rows.append(row)
    return rows


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--preview", action="store_true", help="also write preview.png (all kinds, 4x; keep it out of the assets: --out elsewhere or delete it)")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    all_rows: list[list[Rgba]] = []
    for kind in PALETTES:
        bodies, extras = sheet(kind)
        png(args.out / f"{kind}.png", SIZE * FRAMES, SIZE * 2, strip(bodies) + strip(extras))
        meta = {"frame_w": SIZE, "frame_h": SIZE, "frames": FRAMES, "fps": FPS, "body_r": R + 1,
                "centre": [CX, CY], "rows": ["capsule (turns with the ball)", "the kind's own (kept upright)"],
                "made_by": "tools/build_capsule_sprites.py"}
        (args.out / f"{kind}.json").write_text(json.dumps(meta, indent=1) + "\n")
        all_rows += strip(merged(bodies, extras), 4)
        print(f"{kind}: {args.out / (kind + '.png')}")
    if args.preview:
        png(args.out / "preview.png", SIZE * FRAMES * 4, len(all_rows), all_rows)
        print(f"preview: {args.out / 'preview.png'}")


if __name__ == "__main__":
    main()

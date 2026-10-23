#!/usr/bin/env python3
"""Build Godot-ready CoreXY_UFO sprite sheets from the generated master sheet."""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
GAME_ASSETS = ROOT / "game" / "assets"
CELL = 64


def tile(master: Image.Image, col: int, row: int) -> Image.Image:
    """Crop the regular 5x2 master grid and resample without smoothing."""
    x0 = round(col * master.width / 5)
    x1 = round((col + 1) * master.width / 5)
    y0 = round(row * master.height / 2)
    y1 = round((row + 1) * master.height / 2)
    frame = master.crop((x0, y0, x1, y1)).resize((CELL, CELL), Image.Resampling.NEAREST)
    # Grid rounding in the generated master can shift a row by a pixel. Register
    # every frame from the top of the connector, which is the physical anchor.
    bbox = frame.getchannel("A").getbbox()
    if bbox:
        frame = offset(frame, dy=5 - bbox[1])
    return frame


def sheet(frames: list[Image.Image], columns: int) -> Image.Image:
    rows = (len(frames) + columns - 1) // columns
    out = Image.new("RGBA", (columns * CELL, rows * CELL), (0, 0, 0, 0))
    for index, frame in enumerate(frames):
        out.alpha_composite(frame, ((index % columns) * CELL, (index // columns) * CELL))
    return out


def grid_tile(master: Image.Image, col: int, row: int, columns: int, rows: int) -> Image.Image:
    """Crop any regularly spaced generated sprite grid without pose normalization."""
    x0 = round(col * master.width / columns)
    x1 = round((col + 1) * master.width / columns)
    y0 = round(row * master.height / rows)
    y1 = round((row + 1) * master.height / rows)
    return master.crop((x0, y0, x1, y1)).resize((CELL, CELL), Image.Resampling.NEAREST)


def top_attachment(frame: Image.Image) -> dict[str, int]:
    """Return the top of the UFO's largest connected alpha component.

    Detached sweat and motion pixels must not be mistaken for the connector.
    """
    alpha = frame.getchannel("A")
    opaque = {(x, y) for y in range(CELL) for x in range(CELL) if alpha.getpixel((x, y))}
    components: list[set[tuple[int, int]]] = []
    while opaque:
        seed = opaque.pop()
        component = {seed}
        stack = [seed]
        while stack:
            x, y = stack.pop()
            for ny in range(max(0, y - 1), min(CELL, y + 2)):
                for nx in range(max(0, x - 1), min(CELL, x + 2)):
                    point = (nx, ny)
                    if point in opaque:
                        opaque.remove(point)
                        component.add(point)
                        stack.append(point)
        components.append(component)
    if not components:
        return {"x": CELL // 2, "y": 0}
    body = max(components, key=len)
    y = min(point[1] for point in body)
    xs = [x for x, py in body if py == y]
    return {"x": round((min(xs) + max(xs)) / 2), "y": y}


def largest_component_bbox(frame: Image.Image) -> tuple[int, int, int, int]:
    """Measure the UFO body while ignoring detached motion/sweat pixels."""
    alpha = frame.getchannel("A")
    opaque = {(x, y) for y in range(CELL) for x in range(CELL) if alpha.getpixel((x, y))}
    components: list[set[tuple[int, int]]] = []
    while opaque:
        seed = opaque.pop()
        component = {seed}
        stack = [seed]
        while stack:
            x, y = stack.pop()
            for ny in range(max(0, y - 1), min(CELL, y + 2)):
                for nx in range(max(0, x - 1), min(CELL, x + 2)):
                    point = (nx, ny)
                    if point in opaque:
                        opaque.remove(point)
                        component.add(point)
                        stack.append(point)
        components.append(component)
    if not components:
        return (0, 0, CELL, CELL)
    body = max(components, key=len)
    xs = [p[0] for p in body]
    ys = [p[1] for p in body]
    return (min(xs), min(ys), max(xs) + 1, max(ys) + 1)


def normalize_action_pose(frame: Image.Image, target_long_edge: int = 60) -> Image.Image:
    """Enlarge action art so its UFO body matches the expression sprites."""
    x0, y0, x1, y1 = largest_component_bbox(frame)
    body_w, body_h = x1 - x0, y1 - y0
    scale = target_long_edge / max(body_w, body_h)
    scaled_size = max(1, round(CELL * scale))
    scaled = frame.resize((scaled_size, scaled_size), Image.Resampling.NEAREST)
    body_cx = ((x0 + x1) / 2) * scale
    body_cy = ((y0 + y1) / 2) * scale
    out = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    out.alpha_composite(scaled, (round(CELL / 2 - body_cx), round(CELL / 2 - body_cy)))
    return out


def offset(frame: Image.Image, dx: int = 0, dy: int = 0) -> Image.Image:
    out = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    out.alpha_composite(frame, (dx, dy))
    return out


def rope_assets() -> None:
    rope_dir = ASSETS / "rope"
    rope_dir.mkdir(parents=True, exist_ok=True)

    rope = Image.new("RGBA", (8, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(rope)
    d.rectangle((2, 0, 5, 15), fill="#071a4e")
    d.rectangle((3, 0, 5, 15), fill="#188bd1")
    d.point([(3, y) for y in range(1, 16, 4)], fill="#8cecff")
    rope.save(rope_dir / "rope_texture.png")

    connector = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(connector)
    d.rectangle((5, 1, 10, 3), fill="#071a4e")
    d.rectangle((4, 4, 11, 11), fill="#071a4e")
    d.rectangle((6, 5, 9, 9), fill="#299de0")
    d.rectangle((6, 5, 8, 6), fill="#9cf4ff")
    d.rectangle((3, 10, 12, 13), fill="#071a4e")
    d.rectangle((5, 10, 10, 11), fill="#188bd1")
    connector.save(rope_dir / "rope_connector.png")


def effect_assets() -> None:
    effects = ASSETS / "effects"
    effects.mkdir(parents=True, exist_ok=True)

    sparkles = Image.new("RGBA", (64, 16), (0, 0, 0, 0))
    for i, size in enumerate((2, 3, 4, 3)):
        d = ImageDraw.Draw(sparkles)
        cx = i * 16 + 8
        color = (255, 224, 48, 255)
        d.polygon([(cx, 8-size), (cx+1, 7), (cx+size, 8), (cx+1, 9),
                   (cx, 8+size), (cx-1, 9), (cx-size, 8), (cx-1, 7)], fill=color)
        d.point((cx, 8), fill=(255, 255, 220, 255))
    sparkles.save(effects / "sparkles.png")

    stars = Image.new("RGBA", (64, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(stars)
    for i in range(4):
        cx = i * 16 + 8
        d.polygon([(cx, 2), (cx+2, 6), (cx+6, 6), (cx+3, 9), (cx+4, 14),
                   (cx, 11), (cx-4, 14), (cx-3, 9), (cx-6, 6), (cx-2, 6)],
                  fill="#ffd83d", outline="#0b2667")
    stars.save(effects / "stars.png")

    lines = Image.new("RGBA", (64, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(lines)
    for i in range(4):
        x = i * 16
        d.line((x+2, 4, x+13, 4), fill="#a7f5ff", width=2)
        d.line((x+5, 8, x+14, 8), fill="#38bceb", width=2)
        d.line((x+1, 12, x+10, 12), fill="#176bb1", width=2)
    lines.save(effects / "motion_lines.png")


def action_effect_frames() -> list[Image.Image]:
    """Effects aligned 1:1 with the eight action-pose cells."""
    frames = [Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0)) for _ in range(8)]
    cyan, light, navy = "#28c9f1", "#a7f5ff", "#143f91"

    def speed(draw: ImageDraw.ImageDraw, side: str, frantic: bool = False) -> None:
        spans = [(5, 19, 6), (1, 25, 10), (7, 31, 15), (2, 38, 11)]
        if side == "right":
            spans = [(CELL - 1 - b, y, CELL - 1 - a) for a, y, b in spans]
        for i, (a, y, b) in enumerate(spans):
            draw.line((a, y, b, y), fill=light if i % 2 == 0 else cyan, width=2)
        if frantic:
            draw.line((4 if side == "left" else 58, 44, 11 if side == "left" else 51, 44), fill=navy, width=2)

    speed(ImageDraw.Draw(frames[0]), "left")
    speed(ImageDraw.Draw(frames[1]), "right")
    speed(ImageDraw.Draw(frames[2]), "left", True)
    speed(ImageDraw.Draw(frames[3]), "right", True)

    # Sweat drops are independent from the face and can be toggled separately.
    for idx, x in ((2, 52), (3, 12)):
        d = ImageDraw.Draw(frames[idx])
        d.polygon([(x, 8), (x + 4, 15), (x, 18), (x - 4, 15)], fill=cyan, outline=navy)
        d.point((x - 1, 13), fill=light)

    d = ImageDraw.Draw(frames[4])
    for x in (10, 54):
        d.line((x, 11, x, 20), fill=light, width=2)
        d.line((x - 3, 14, x - 6, 9), fill=cyan, width=2)
        d.line((x + 3, 14, x + 6, 9), fill=cyan, width=2)

    d = ImageDraw.Draw(frames[5])
    d.line((3, 20, 12, 23), fill=cyan, width=2)
    d.line((2, 31, 11, 31), fill=light, width=2)
    d.line((52, 15, 61, 10), fill=cyan, width=2)
    d.line((54, 24, 63, 22), fill=light, width=2)

    d = ImageDraw.Draw(frames[6])
    for x in (20, 32, 44):
        d.line((x, 3, x, 12), fill=light, width=2)
        d.line((x - 2, 7, x, 3, x + 2, 7), fill=cyan, width=1)

    d = ImageDraw.Draw(frames[7])
    for x, y, size in ((8, 20, 3), (55, 15, 4), (58, 34, 2)):
        d.ellipse((x - size, y - size, x + size, y + size), fill=light, outline=navy)
    return frames


def build(source: Path, action_source: Path | None = None) -> None:
    master = Image.open(source).convert("RGBA")
    ufo_dir = ASSETS / "ufo"
    preview_dir = ASSETS / "preview"
    ufo_dir.mkdir(parents=True, exist_ok=True)
    preview_dir.mkdir(parents=True, exist_ok=True)

    expressions = [tile(master, i % 5, i // 5) for i in range(10)]
    expression_names = [
        "normal", "blink", "happy", "surprised", "straining",
        "worried", "sad", "wink", "sleepy", "excited",
    ]

    expression_sheet = sheet(expressions, 5)
    expression_sheet.save(ufo_dir / "ufo_expressions.png")

    # Four economical Idle frames: breathing is a one-pixel vertical shift;
    # the blink uses the same registered master character.
    idle_frames = [expressions[0], expressions[0], expressions[1], expressions[0]]
    sheet(idle_frames, 4).save(ufo_dir / "ufo_idle.png")

    # Two image frames per action. Rotation and translation remain Godot-side.
    action_defs = [
        ("swing", expressions[0], expressions[9]),
        ("pull", expressions[4], expressions[4]),
        ("release", expressions[7], expressions[1]),
        ("move", expressions[0], expressions[8]),
        ("success", expressions[9], expressions[2]),
        ("failure", expressions[6], expressions[6]),
        ("recover", expressions[5], expressions[0]),
    ]
    action_frames = [frame for _, a, b in action_defs for frame in (a, b)]
    sheet(action_frames, 7).save(ufo_dir / "ufo_actions.png")

    action_pose_metadata = None
    if action_source is not None:
        action_master = Image.open(action_source).convert("RGBA")
        action_pose_names = [
            "move_right", "move_left", "panic_right", "panic_left",
            "strain_up", "resist_side", "release_stretch", "exhausted",
        ]
        raw_action_poses = [grid_tile(action_master, i % 4, i // 4, 4, 2) for i in range(8)]
        action_poses = [normalize_action_pose(frame) for frame in raw_action_poses]
        action_pose_sheet = sheet(action_poses, 4)
        action_pose_sheet.save(ufo_dir / "ufo_action_poses.png")
        action_pose_sheet.resize((512, 256), Image.Resampling.NEAREST).save(preview_dir / "action_sheet.png")

        action_fx = action_effect_frames()
        action_fx_sheet = sheet(action_fx, 4)
        (ASSETS / "effects").mkdir(parents=True, exist_ok=True)
        action_fx_sheet.save(ASSETS / "effects" / "ufo_action_effects.png")
        action_fx_sheet.resize((512, 256), Image.Resampling.NEAREST).save(preview_dir / "action_effects_sheet.png")

        # One importable atlas containing all ten expressions followed by all
        # eight normalized action poses. Empty cells stay transparent.
        all_frames = expressions + action_poses
        all_sheet = sheet(all_frames, 6)
        all_sheet.save(ufo_dir / "ufo_all_sprites.png")
        all_sheet.resize((768, 384), Image.Resampling.NEAREST).save(preview_dir / "all_sprites_sheet.png")
        action_pose_metadata = {
            "file": "res://assets/ufo/ufo_action_poses.png",
            "columns": 4,
            "rows": 2,
            "frame_count": 8,
            "fps": 0.0,
            "loop": False,
            "frames": [
                {
                    "index": i,
                    "x": (i % 4) * CELL,
                    "y": (i // 4) * CELL,
                    "name": name,
                    "rope_attachment_local": top_attachment(action_poses[i]),
                }
                for i, name in enumerate(action_pose_names)
            ],
        }

    # Transparent master preview at 2x nearest-neighbor scale.
    expression_sheet.resize((640, 256), Image.Resampling.NEAREST).save(preview_dir / "character_sheet.png")

    metadata = {
        "format_version": 1,
        "character": "CoreXY_UFO",
        "pixel_art": True,
        "texture_filter": "nearest",
        "frame_size": {"width": CELL, "height": CELL},
        "rope_attachment_local": {"x": 32, "y": 5},
        "origin_local": {"x": 32, "y": 32},
        "sheets": {
            "idle": {
                "file": "res://assets/ufo/ufo_idle.png", "columns": 4, "rows": 1,
                "frame_count": 4, "fps": 3.0, "loop": True,
                "frames": [
                    {"index": i, "x": i * CELL, "y": 0, "expression": e}
                    for i, e in enumerate(["normal", "normal_breathe", "blink", "normal_breathe"])
                ],
            },
            "expressions": {
                "file": "res://assets/ufo/ufo_expressions.png", "columns": 5, "rows": 2,
                "frame_count": 10, "fps": 0.0, "loop": False,
                "frames": [
                    {"index": i, "x": (i % 5) * CELL, "y": (i // 5) * CELL, "name": name}
                    for i, name in enumerate(expression_names)
                ],
            },
            "actions": {
                "file": "res://assets/ufo/ufo_actions.png", "columns": 7, "rows": 2,
                "frame_count": 14,
                "animations": {
                    name: {"frames": [2 * i, 2 * i + 1], "fps": 4.0 if name not in ("success", "failure") else 6.0, "loop": name in ("swing", "pull", "move")}
                    for i, (name, _, _) in enumerate(action_defs)
                },
                "layout": [
                    {"index": i, "x": (i % 7) * CELL, "y": (i // 7) * CELL}
                    for i in range(14)
                ],
            },
        },
        "effects": {
            "sparkles": {"file": "res://assets/effects/sparkles.png", "frame_size": [16, 16], "frames": 4, "fps": 10.0},
            "stars": {"file": "res://assets/effects/stars.png", "frame_size": [16, 16], "frames": 4, "fps": 8.0},
            "motion_lines": {"file": "res://assets/effects/motion_lines.png", "frame_size": [16, 16], "frames": 4, "fps": 12.0},
        },
        "rope": {
            "texture": "res://assets/rope/rope_texture.png",
            "texture_size": [8, 16],
            "connector": "res://assets/rope/rope_connector.png",
            "connector_size": [16, 16],
            "connector_anchor_local": [8, 13],
        },
    }
    if action_pose_metadata is not None:
        metadata["sheets"]["action_poses"] = action_pose_metadata
        metadata["sheets"]["action_effects"] = {
            "file": "res://assets/effects/ufo_action_effects.png",
            "columns": 4,
            "rows": 2,
            "frame_count": 8,
            "frame_size": {"width": CELL, "height": CELL},
            "alignment": "overlay matching action_poses frame index",
            "frames": [
                {"index": i, "x": (i % 4) * CELL, "y": (i // 4) * CELL, "name": name}
                for i, name in enumerate([
                    "move_right_lines", "move_left_lines", "panic_right_fx", "panic_left_fx",
                    "strain_up_lines", "resist_side_lines", "release_lines", "exhausted_bubbles",
                ])
            ],
        }
        unified_names = expression_names + [
            "move_right", "move_left", "panic_right", "panic_left",
            "strain_up", "resist_side", "release_stretch", "exhausted",
        ]
        unified_attachments = ([{"x": 32, "y": 5}] * len(expression_names)) + [
            frame["rope_attachment_local"] for frame in action_pose_metadata["frames"]
        ]
        metadata["sheets"]["all_sprites"] = {
            "file": "res://assets/ufo/ufo_all_sprites.png",
            "columns": 6,
            "rows": 3,
            "frame_count": 18,
            "frame_order": "expressions_then_actions",
            "frames": [
                {
                    "index": i,
                    "x": (i % 6) * CELL,
                    "y": (i // 6) * CELL,
                    "name": name,
                    "category": "expression" if i < 10 else "action",
                    "rope_attachment_local": unified_attachments[i],
                }
                for i, name in enumerate(unified_names)
            ],
        }
    (ufo_dir / "ufo_metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    rope_assets()
    effect_assets()


def sync_game_assets() -> None:
    """Copy the runtime sheets into the Godot project, which only reads game/assets."""
    for sub in ("ufo", "rope", "effects"):
        dst = GAME_ASSETS / sub
        dst.mkdir(parents=True, exist_ok=True)
        for src in sorted((ASSETS / sub).iterdir()):
            if src.suffix in (".png", ".json"):
                shutil.copy2(src, dst / src.name)
    print(f"synced assets/{{ufo,rope,effects}} -> {GAME_ASSETS.relative_to(ROOT)} "
          "(run `godot --headless --path game --import` for new files)")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--no-sync"]
    if len(args) not in (1, 2):
        raise SystemExit(
            "usage: build_ufo_assets.py EXPRESSION_MASTER.png [ACTION_CHARACTER_MASTER.png] [--no-sync]\n"
            "  current sources: assets/source/ufo_expression_master.png "
            "assets/source/ufo_action_character_master.png")
    build(Path(args[0]), Path(args[1]) if len(args) == 2 else None)
    if "--no-sync" not in sys.argv:
        sync_game_assets()

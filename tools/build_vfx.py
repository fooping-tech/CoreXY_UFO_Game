#!/usr/bin/env python3
"""Bake the pixelfx effects listed in game/assets/vfx/catalog.json into sprite sheets.

    git clone https://github.com/patch-gg/pixelfx /path/to/pixelfx   # once, outside this repo
    python3 tools/build_vfx.py --pixelfx /path/to/pixelfx [id ...]

For each entry it runs `node tools/render.mjs <source> --sheet --no-actor --opts <opts>`
in the pixelfx checkout and copies the PNG (frames in a grid) and the Aseprite-style
JSON (frame rects, durations, meta.pixelfx: fps, loop, frameSize, pivot) to
game/assets/vfx/<id>.png / <id>.json. Node is needed only here; the game reads
the PNG and JSON. Checks that the checkout is the version named in the catalog.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VFX_DIR = ROOT / "game" / "assets" / "vfx"
CATALOG = VFX_DIR / "catalog.json"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pixelfx", required=True, type=Path, help="a pixelfx checkout")
    ap.add_argument("ids", nargs="*", help="catalog ids to bake (default: all)")
    args = ap.parse_args()
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    pfx = args.pixelfx.resolve()
    pkg = json.loads((pfx / "package.json").read_text(encoding="utf-8"))
    want = catalog["pixelfx"]["version"]
    if pkg.get("version") != want:
        print(f"pixelfx {pkg.get('version')} found, catalog expects {want}", file=sys.stderr)
        return 1
    effects = catalog["effects"]
    ids = args.ids or list(effects)
    unknown = [i for i in ids if i not in effects]
    if unknown:
        print(f"not in the catalog: {unknown}", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        for vid in ids:
            e = effects[vid]
            src = e["source"]
            cmd = ["node", "tools/render.mjs", src, "--sheet", "--no-actor", "--out", tmp,
                   "--opts", json.dumps(e.get("opts", {}))]
            subprocess.run(cmd, cwd=pfx, check=True, stdout=subprocess.DEVNULL)
            name = src.split("/")[1]
            out = Path(tmp) / src
            shutil.copyfile(out / f"{name}.png", VFX_DIR / f"{vid}.png")
            sheet = json.loads((out / f"{name}.json").read_text(encoding="utf-8"))
            sheet["meta"]["image"] = f"{vid}.png"
            (VFX_DIR / f"{vid}.json").write_text(json.dumps(sheet, indent=1) + "\n", encoding="utf-8")
            m = sheet["meta"]["pixelfx"]
            print(f"{vid:18s} <- {src:24s} {m['frames']:3d} frames {m['frameSize']} pivot {m['pivot']} "
                  f"{'loop' if m['loop'] else 'once'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

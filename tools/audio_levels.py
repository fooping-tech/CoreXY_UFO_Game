#!/usr/bin/env python3
"""Measure how loud each of the game's sounds is, to level them (#304).

    python3 tools/audio_levels.py            # the files in game/assets/audio (+ bgm/)
    python3 tools/audio_levels.py --synth    # also the synthesised sounds (runs Godot headless)

Needs ffmpeg (EBU R128 meter). Two numbers:

- effects: the loudest momentary loudness (400 ms window, the file padded with 0.6 s of
  silence so a click is measured too), in LUFS
- music (bgm/): the integrated loudness of the whole file, in LUFS

The levels the game aims at (dB after every gain, with audio.volume_db = -8):

- effects: big moments (GO, TIME UP, result, jackpot, stop...) -22, ordinary ones -24,
  small or rapid ones lower (pin -34). The gain to put in the manifest's gain_db (or the
  GAIN_DB tables in the scripts) is   target + 8 - measured.
- music: every file to -18 LUFS with game_mode.sounds.bgm.gain_db (or study_mode.bgm.gain_db)
  = -18 - measured; GameModeSounds.BGM_DB puts the music about 6 dB under the big effects.

Only reads the files; writes nothing in the repository.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AUDIO = ROOT / "game" / "assets" / "audio"
EXTS = {".mp3", ".ogg", ".wav"}


def _ebur128(path: Path, pad: bool) -> str:
    af = "apad=pad_dur=0.6,ebur128" if pad else "ebur128"
    r = subprocess.run(
        ["ffmpeg", "-nostats", "-hide_banner", "-i", str(path), "-af", af, "-f", "null", "-"],
        capture_output=True,
        text=True,
        check=False,
    )
    return r.stderr


def momentary_max(path: Path) -> float | None:
    vals = [float(x) for x in re.findall(r" M:\s*(-?[\d.]+)", _ebur128(path, True))]
    return max(vals) if vals else None


def integrated(path: Path) -> float | None:
    vals = re.findall(r"I:\s*(-?[\d.]+) LUFS", _ebur128(path, False))
    return float(vals[-1]) if vals else None


def manifest_gains() -> dict[str, tuple[str, float]]:
    """file (relative to assets/audio) -> (key, gain_db) from manifest.json."""
    data = json.loads((AUDIO / "manifest.json").read_text(encoding="utf-8"))
    return {v["file"]: (k, float(v.get("gain_db", 0))) for k, v in data["sounds"].items()}


def _fmt(v: float | None) -> str:
    return "   n/a" if v is None else f"{v:6.1f}"


def report_effects(files: list[Path], base: Path, gains: dict[str, tuple[str, float]]) -> None:
    print(f"{'effect':40s} {'maxM':>6s} {'gain':>5s} {'=> at -8':>8s}  key")
    for f in files:
        rel = f.relative_to(base).as_posix()
        level = momentary_max(f)
        key, gain = gains.get(rel, ("", 0.0))
        eff = None if level is None else level + gain - 8.0
        print(f"{rel:40s} {_fmt(level)} {gain:5.1f} {_fmt(eff):>8s}  {key}")


def report_music(files: list[Path]) -> None:
    print(f"\n{'music':40s} {'LUFS':>6s}  gain_db for -18")
    for f in files:
        level = integrated(f)
        need = "" if level is None else f"{-18.0 - level:+.1f}"
        print(f"{f.relative_to(AUDIO).as_posix():40s} {_fmt(level)}  {need}")


def dump_synth(out: Path) -> bool:
    godot = shutil.which("godot")
    if godot is None:
        print("godot not found: no synthesised sounds", file=sys.stderr)
        return False
    script = ROOT / "tools" / "audio_dump_synth.gd"
    r = subprocess.run(
        [godot, "--headless", "--path", str(ROOT / "game"), "--script", str(script)],
        env={**os.environ, "OUT": str(out)},
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    if "done" not in r.stdout:
        print(r.stdout[-2000:], r.stderr[-2000:], file=sys.stderr)
        return False
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--synth", action="store_true", help="also the synthesised sounds (Godot headless)")
    args = ap.parse_args()
    if shutil.which("ffmpeg") is None:
        print("ffmpeg is needed (brew install ffmpeg)", file=sys.stderr)
        return 1
    files = sorted(p for p in AUDIO.rglob("*") if p.suffix.lower() in EXTS)
    music = [p for p in files if p.parent.name == "bgm"]
    effects = [p for p in files if p.parent.name != "bgm"]
    report_effects(effects, AUDIO, manifest_gains())
    report_music(music)
    if args.synth:
        with tempfile.TemporaryDirectory() as tmp:
            if dump_synth(Path(tmp)):
                print("\nsynthesised (gain = the script's own table, not shown)")
                report_effects(sorted(Path(tmp).glob("*.wav")), Path(tmp), {})
    return 0


if __name__ == "__main__":
    sys.exit(main())

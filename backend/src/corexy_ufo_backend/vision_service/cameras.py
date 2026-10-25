"""Find an OpenCV camera index by (part of) the camera's name.

OpenCV opens cameras by index only. On macOS its AVFoundation backend numbers
the cameras in the order of their unique IDs (checked with a C270, an
Innomaker U20CAM and the built-in camera: 0x1112... < 0x1120... < 6C70...),
and `system_profiler SPCameraDataType` lists both names and unique IDs, so the
index of a named camera is its position in that sorted list.
"""

from __future__ import annotations

import json
import subprocess
import sys


def list_cameras_macos() -> list[dict[str, str]]:
    """[{name, unique_id}] in OpenCV AVFoundation index order ([] elsewhere / on error)."""
    if sys.platform != "darwin":
        return []
    try:
        out = subprocess.run(["system_profiler", "SPCameraDataType", "-json"], capture_output=True, text=True,
                             timeout=10, check=True).stdout
        cams = json.loads(out).get("SPCameraDataType", [])
    except (OSError, subprocess.SubprocessError, ValueError):
        return []
    return order_by_unique_id([{"name": str(c.get("_name", "")), "unique_id": str(c.get("spcamera_unique-id", ""))}
                               for c in cams])


def order_by_unique_id(cams: list[dict[str, str]]) -> list[dict[str, str]]:
    return sorted(cams, key=lambda c: c["unique_id"])


def index_by_name(cams: list[dict[str, str]], pattern: str) -> int | None:
    p = pattern.strip().lower()
    if not p:
        return None
    for i, c in enumerate(cams):
        if p in c["name"].lower():
            return i
    return None


def resolve_camera(spec: str) -> int:
    """`spec` is an index ("1") or part of a camera name ("C270")."""
    s = spec.strip()
    if s.lstrip("-").isdigit():
        return int(s)
    idx = index_by_name(list_cameras_macos(), s)
    if idx is None:
        raise ValueError(f"no camera named like {spec!r} (cameras: {[c['name'] for c in list_cameras_macos()]})")
    return idx

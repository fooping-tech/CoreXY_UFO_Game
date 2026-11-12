"""All values measured on this desk / this machine in one file: config/calibration.json (#96).
Not in Git: the values differ from machine to machine, so each one measures its own.

Sections: ``z`` (Z servo counts per unit and sign), ``claw`` (the claw's open / closed
angles), ``homework_spot`` (where the arm's camera looks at the worksheet) and
``camera_xy`` (overview image -> CoreXY XY). Each was a file of its own before
(z_calibration.json, arm_calibration.json, homework_spot.json,
camera_xy_calibration.json); those are still read when the section is missing.

A ``CalibrationSection`` stands where a path stood: the loaders only call ``exists``,
``read_text``, ``write_text`` and ``unlink`` (so their tests can still pass a plain Path).

- Writing one section keeps the others (read, change, write to a temporary file, replace).
- A calibration.json that cannot be read is never written over (the error goes up): the
  other sections would be lost.
- Deleting a section also deletes its earlier file, so a cleared calibration (z_reset)
  does not come back from it.
"""

from __future__ import annotations

import json
import os
import threading
from pathlib import Path
from typing import Any

CALIBRATION_FILE = "calibration.json"
LEGACY_FILES = {
    "z": "z_calibration.json",
    "claw": "arm_calibration.json",
    "homework_spot": "homework_spot.json",
    "camera_xy": "camera_xy_calibration.json",
}
NOTE = ("Values measured on this desk / this machine (#96), written by the backend when they are "
        "recorded (the debug panel). z = Z servo counts per unit and sign (z_set top / bottom), claw = "
        "the claw's open / closed angles, homework_spot = where the arm's camera looks at the worksheet, "
        "camera_xy = overview image -> CoreXY XY. Per machine: not in Git (every machine measures its own).")

_lock = threading.Lock()


class CalibrationSection:
    """One section of calibration.json, used like the file it replaces."""

    def __init__(self, file: Path, name: str, legacy: Path | None = None) -> None:
        self.file = file
        self.name = name
        self.legacy = legacy

    def __repr__(self) -> str:
        return f"{self.file}#{self.name}"

    __str__ = __repr__

    def _read_all(self) -> dict[str, Any]:
        """The whole file ({} when missing). Raises ValueError when it cannot be read."""
        if not self.file.exists():
            return {}
        try:
            d = json.loads(self.file.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            raise ValueError(f"{self.file} cannot be read: {e}") from e
        if not isinstance(d, dict):
            raise ValueError(f"{self.file} is not a JSON object")
        return d

    def exists(self) -> bool:
        try:
            if self.name in self._read_all():
                return True
        except ValueError:
            return True  # let read_text raise, so the loader logs it
        return self.legacy is not None and self.legacy.exists()

    def read_text(self, encoding: str = "utf-8") -> str:
        d = self._read_all()
        if self.name in d:
            return json.dumps(d[self.name])
        if self.legacy is not None and self.legacy.exists():
            return self.legacy.read_text(encoding=encoding)
        raise FileNotFoundError(str(self))

    def write_text(self, text: str, encoding: str = "utf-8") -> int:
        value = json.loads(text)
        with _lock:
            d = self._read_all()
            if "_note" not in d:
                d = {"_note": NOTE, **d}
            d[self.name] = value
            self._write_all(d, encoding)
        return len(text)

    def unlink(self, missing_ok: bool = False) -> None:
        with _lock:
            d = self._read_all()
            had = self.name in d
            if had:
                del d[self.name]
                self._write_all(d, "utf-8")
            if self.legacy is not None and self.legacy.exists():
                self.legacy.unlink()
                had = True
        if not had and not missing_ok:
            raise FileNotFoundError(str(self))

    def _write_all(self, d: dict[str, Any], encoding: str) -> None:
        tmp = self.file.with_name(self.file.name + ".tmp")
        tmp.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n", encoding=encoding)
        os.replace(tmp, self.file)


def section(config_dir: Path, name: str) -> CalibrationSection:
    return CalibrationSection(config_dir / CALIBRATION_FILE, name, config_dir / LEGACY_FILES[name])

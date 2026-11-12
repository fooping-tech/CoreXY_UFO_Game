"""config/calibration.json (#96): every measured value in one file, a section each."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from corexy_ufo_backend.calibration_store import CALIBRATION_FILE, LEGACY_FILES, section
from corexy_ufo_backend.config import DEFAULT_CONFIG_PATH, load_config
from corexy_ufo_backend.homework.approach import HomeworkSpot
from corexy_ufo_backend.robot.claw import ClawCalibration
from corexy_ufo_backend.robot.z_calibration import ZCalibration


def read(d: Path) -> dict:
    return json.loads((d / CALIBRATION_FILE).read_text(encoding="utf-8"))


def test_the_repository_file_has_the_measured_values() -> None:
    d = json.loads((DEFAULT_CONFIG_PATH.parent / CALIBRATION_FILE).read_text(encoding="utf-8"))
    assert d["z"] == {"counts_per_unit": 80.42, "sign": 1, "span_counts": 8042}  # #72, unchanged
    assert d["claw"]["open_deg"] == 61.875 and d["claw"]["closed_deg"] == 292.060546875
    for old in LEGACY_FILES.values():
        assert not (DEFAULT_CONFIG_PATH.parent / old).exists(), old
    cfg = load_config()
    assert ZCalibration.load(cfg.z_calibration_path).counts_per_unit == 80.42
    assert ClawCalibration.load(cfg.arm_calibration_path).open_deg == 61.875


def test_a_section_is_written_without_losing_the_others(tmp_path: Path) -> None:
    ZCalibration(counts_per_unit=80.0, sign=-1, span_counts=8000).save(section(tmp_path, "z"))
    HomeworkSpot(10.0, 20.0, 30.0).save(section(tmp_path, "homework_spot"))
    ClawCalibration(closed_deg=1.0, open_deg=2.0, span_deg=3.0).save(section(tmp_path, "claw"))
    d = read(tmp_path)
    assert set(d) == {"_note", "z", "homework_spot", "claw"}
    assert ZCalibration.load(section(tmp_path, "z")).sign == -1
    assert HomeworkSpot.load(section(tmp_path, "homework_spot")) == HomeworkSpot(10.0, 20.0, 30.0)
    assert not (tmp_path / "calibration.json.tmp").exists()


def test_an_earlier_file_is_read_until_the_section_exists(tmp_path: Path) -> None:
    (tmp_path / "homework_spot.json").write_text(json.dumps({"x": 1, "y": 2, "z": 3}))
    s = section(tmp_path, "homework_spot")
    assert s.exists() and HomeworkSpot.load(s) == HomeworkSpot(1.0, 2.0, 3.0)
    HomeworkSpot(4.0, 5.0, 6.0).save(s)
    assert HomeworkSpot.load(s) == HomeworkSpot(4.0, 5.0, 6.0)  # the new file wins
    assert not section(tmp_path, "camera_xy").exists()


def test_deleting_the_z_calibration_deletes_the_earlier_file_too(tmp_path: Path) -> None:
    (tmp_path / "z_calibration.json").write_text(json.dumps({"counts_per_unit": 80.0, "sign": 1}))
    ZCalibration(counts_per_unit=90.0, sign=1).save(section(tmp_path, "z"))
    ZCalibration.delete(section(tmp_path, "z"))
    assert not (tmp_path / "z_calibration.json").exists() and "z" not in read(tmp_path)
    assert ZCalibration.load(section(tmp_path, "z")).counts_per_unit is None  # it does not come back
    ZCalibration.delete(section(tmp_path, "z"))  # nothing left: fine


def test_a_broken_file_is_never_written_over(tmp_path: Path) -> None:
    (tmp_path / CALIBRATION_FILE).write_text("{broken")
    assert ZCalibration.load(section(tmp_path, "z")).counts_per_unit is None  # logged, not used
    with pytest.raises(ValueError):
        ZCalibration(counts_per_unit=90.0, sign=1).save(section(tmp_path, "z"))
    assert (tmp_path / CALIBRATION_FILE).read_text() == "{broken"

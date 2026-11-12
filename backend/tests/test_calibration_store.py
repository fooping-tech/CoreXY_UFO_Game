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


def test_the_config_points_at_calibration_json(tmp_path: Path) -> None:
    p = tmp_path / "game_config.json"
    p.write_text(json.dumps({}))
    cfg = load_config(p)
    for s, name in ((cfg.z_calibration_path, "z"), (cfg.arm_calibration_path, "claw"),
                    (cfg.homework_spot_path, "homework_spot"), (cfg.camera_xy_path, "camera_xy")):
        assert str(s) == f"{tmp_path / CALIBRATION_FILE}#{name}" and s.legacy == tmp_path / LEGACY_FILES[name]
    # a machine that has measured nothing yet: nothing is used
    assert ZCalibration.load(cfg.z_calibration_path).counts_per_unit is None
    assert ClawCalibration.load(cfg.arm_calibration_path).open_deg is None


def test_calibration_json_stays_out_of_git() -> None:
    ignored = (DEFAULT_CONFIG_PATH.parents[1] / ".gitignore").read_text(encoding="utf-8").splitlines()
    assert "config/calibration.json" in ignored and "config/local_settings.json" in ignored


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

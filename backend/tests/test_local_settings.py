"""config/local_settings.json (the settings screen, #93): read over game_config.json, only
the keys and values game_config.json's settings_screen section allows."""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest

from corexy_ufo_backend import config as config_mod
from corexy_ufo_backend.config import DEFAULT_CONFIG_PATH, load_config, local_overrides, schema_items

REPO_CONFIG = DEFAULT_CONFIG_PATH.parent


@pytest.fixture()
def cfg_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.delenv("CXUFO_NO_LOCAL_SETTINGS", raising=False)
    shutil.copy(REPO_CONFIG / "game_config.json", tmp_path / "game_config.json")
    return tmp_path


def write_local(d: Path, data: object) -> None:
    (d / "local_settings.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")


def test_every_schema_key_is_in_game_config() -> None:
    base = json.loads(DEFAULT_CONFIG_PATH.read_text(encoding="utf-8"))
    schema = json.loads(DEFAULT_CONFIG_PATH.read_text(encoding="utf-8"))["settings_screen"]
    items = schema_items(schema)
    assert len(items) >= 15
    for key in items:
        cur = base
        for part in key.split("."):
            assert isinstance(cur, dict) and part in cur, key
            cur = cur[part]


def test_every_item_says_when_it_applies() -> None:
    schema = json.loads(DEFAULT_CONFIG_PATH.read_text(encoding="utf-8"))["settings_screen"]
    for key, item in schema_items(schema).items():
        assert item.get("apply") in ("now", "restart", "backend"), key
        # what the backend reads at start can never be "now"
        if key.startswith(("backend.", "study.")) or key in ("gesture.camera", "homework.speech.enabled"):
            assert item["apply"] == "backend", key


def test_no_calibration_or_safety_key_in_the_schema() -> None:
    schema = json.loads(DEFAULT_CONFIG_PATH.read_text(encoding="utf-8"))["settings_screen"]
    keys = set(schema_items(schema))
    for banned in ("robot.", "backend.z_", "backend.arm_open_turns", "backend.home_", "auto_catch.",
                   "study_mode.height.", "study_mode.cleanup.", "gesture.allow_real_robot", "network."):
        assert not any(k.startswith(banned) for k in keys), banned


def test_local_settings_override_allowed_keys(cfg_dir: Path) -> None:
    write_local(cfg_dir, {"backend": {"serial_port": "/dev/cu.test"}, "study": {"enabled": True, "provider": "codex"},
                          "study_mode": {"demo": {"source": "camera"}}, "audio": {"volume_db": -20}})
    cfg = load_config(cfg_dir / "game_config.json")
    assert cfg.serial_port == "/dev/cu.test"
    assert cfg.raw["study"]["enabled"] is True and cfg.raw["study"]["provider"] == "codex"
    assert cfg.raw["study"]["timeout_s"] == 90.0  # the rest of the section stays
    assert cfg.raw["study_mode"]["demo"]["source"] == "camera"
    assert cfg.raw["study_mode"]["demo"]["worksheet_wait_s"] == 4.0
    assert cfg.raw["audio"]["volume_db"] == -20.0


def test_local_settings_cannot_reach_calibration_or_bad_values(cfg_dir: Path, caplog: pytest.LogCaptureFixture) -> None:
    base = load_config(cfg_dir / "game_config.json")
    write_local(cfg_dir, {"backend": {"z_sign": -1, "z_counts_per_unit": 1.0, "serial_port": "a\nb"},
                          "robot": {"x_max_mm": 999}, "study": {"enabled": "yes", "provider": "other"},
                          "audio": {"volume_db": 50}, "auto_catch": {"real": {"confirmed": True}}})
    cfg = load_config(cfg_dir / "game_config.json")
    assert cfg.z_sign == base.z_sign and cfg.z_counts_per_unit == base.z_counts_per_unit
    assert cfg.limits.x_max == base.limits.x_max and cfg.serial_port == base.serial_port
    assert cfg.raw["study"] == base.raw["study"] and cfg.raw["audio"] == base.raw["audio"]
    assert cfg.raw["auto_catch"] == base.raw["auto_catch"]
    overrides, warnings = local_overrides(cfg_dir, json.loads((cfg_dir / "game_config.json").read_text(encoding="utf-8")))
    assert overrides == {} and len(warnings) == 8


def test_broken_local_file_is_ignored(cfg_dir: Path) -> None:
    (cfg_dir / "local_settings.json").write_text("{not json", encoding="utf-8")
    cfg = load_config(cfg_dir / "game_config.json")
    assert cfg.raw["study"]["enabled"] is False
    write_local(cfg_dir, ["not", "an", "object"])
    assert local_overrides(cfg_dir, json.loads((cfg_dir / "game_config.json").read_text(encoding="utf-8")))[0] == {}


def test_tests_and_local_false_skip_the_file(cfg_dir: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    write_local(cfg_dir, {"backend": {"serial_port": "/dev/cu.test"}})
    assert load_config(cfg_dir / "game_config.json", local=False).serial_port == ""
    monkeypatch.setenv("CXUFO_NO_LOCAL_SETTINGS", "1")
    assert load_config(cfg_dir / "game_config.json").serial_port == ""
    assert config_mod.LOCAL_FILE == "local_settings.json"

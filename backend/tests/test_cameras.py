"""cameras.resolve_camera / list_cameras: a camera by name on macOS and on Windows (DirectShow order)."""
from __future__ import annotations

import sys

import pytest

from corexy_ufo_backend.vision_service import cameras


def test_an_index_needs_no_listing(monkeypatch):
    monkeypatch.setattr(cameras, "list_cameras", lambda: pytest.fail("listed for an index"))
    assert cameras.resolve_camera(" 2 ") == 2


def test_a_name_is_its_position_in_the_listing(monkeypatch):
    # the order of the Windows machine of #82: DirectShow numbers them as OpenCV CAP_DSHOW does
    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.setattr(cameras, "list_cameras", lambda: [
        {"name": "FHD Webcam", "unique_id": "a"}, {"name": "Logi C270 HD WebCam", "unique_id": "b"},
        {"name": "Innomaker-U20CAM-1080p-S1", "unique_id": "c"}])
    assert cameras.resolve_camera("C270") == 1 and cameras.resolve_camera("innomaker") == 2
    with pytest.raises(ValueError, match="no camera named like 'Brio'.*C270"):
        cameras.resolve_camera("Brio")


def test_list_cameras_by_platform(monkeypatch):
    monkeypatch.setattr(cameras, "list_cameras_macos", lambda: [{"name": "mac", "unique_id": ""}])
    monkeypatch.setattr(cameras, "list_cameras_windows", lambda: [{"name": "win", "unique_id": ""}])
    monkeypatch.setattr(sys, "platform", "darwin")
    assert cameras.list_cameras()[0]["name"] == "mac"
    monkeypatch.setattr(sys, "platform", "win32")
    assert cameras.list_cameras()[0]["name"] == "win"


def test_a_name_elsewhere_says_to_use_an_index(monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    with pytest.raises(ValueError, match="as an index"):
        cameras.resolve_camera("C270")


@pytest.mark.skipif(sys.platform != "win32", reason="DirectShow is Windows only")
def test_directshow_listing_runs():
    """No camera is needed: the listing is a list (maybe empty), never a crash."""
    cams = cameras.list_cameras_windows()
    assert isinstance(cams, list) and all(set(c) == {"name", "unique_id"} for c in cams)
    assert cameras.list_cameras_windows() == cams  # COM set up and torn down cleanly: the same again

import pytest

from corexy_ufo_backend.vision_service.base import Detection, DetectionResult, classify_gesture
from corexy_ufo_backend.vision_service.cloudflare_detector import CloudflareDetector


def test_detection_center_and_dict():
    d = Detection("pen", 0.9, (0.1, 0.2, 0.2, 0.2))
    assert d.center == pytest.approx((0.2, 0.3))
    r = DetectionResult([d], (640, 480), "test", 3.0)
    assert r.to_dict()["objects"][0]["label"] == "pen"


def test_gesture_rules():
    wrist = (0.5, 0.9, 0.0)
    def hand(extended):
        pts = [wrist] + [(0.5, 0.8, 0.0)] * 20
        for tip, pip, ext in zip([8, 12, 16, 20], [6, 10, 14, 18], extended):
            pts[pip] = (0.5, 0.6, 0.0)
            pts[tip] = (0.5, 0.2 if ext else 0.65, 0.0)
        return pts
    assert classify_gesture(hand([1, 1, 1, 1])) == "open"
    assert classify_gesture(hand([0, 0, 0, 0])) == "fist"
    assert classify_gesture(hand([1, 0, 0, 0])) == "point"
    assert classify_gesture([]) == "none"


def test_cloudflare_is_interface_only():
    d = CloudflareDetector()
    with pytest.raises(NotImplementedError):
        d.detect(None)

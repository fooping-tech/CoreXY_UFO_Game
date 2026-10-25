"""CLI entry point.

  uv run corexy-ufo-backend --mock              # no hardware
  uv run corexy-ufo-backend --port /dev/cu.usbserial-XXXX
  uv run corexy-ufo-backend --list-ports
  uv run corexy-ufo-backend --mock --camera 0:objects,hands --detector yolo
  uv run corexy-ufo-backend --mock --gesture            # hand joystick (needs: uv sync --extra vision --extra hands)
  uv run corexy-ufo-backend --list-cameras
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import signal
import sys

from .config import load_config
from .robot import MockRobot, RealRobot
from .serial_service.transport import list_serial_ports
from .vision_service import CameraConfig, VisionService
from .vision_service.cameras import list_cameras_macos, resolve_camera
from .vision_service.hand_control import HandControl, HandControlConfig
from .websocket import GameServer

log = logging.getLogger("corexy_ufo_backend")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="corexy-ufo-backend")
    p.add_argument("--mock", action="store_true", help="use the simulated robot (no serial)")
    p.add_argument("--port", help="serial port (default: config / auto-detect)")
    p.add_argument("--baud", type=int)
    p.add_argument("--ws-host")
    p.add_argument("--ws-port", type=int)
    p.add_argument("--state-hz", type=float, default=30.0)
    p.add_argument("--list-ports", action="store_true")
    p.add_argument("--camera", action="append", default=[], metavar="INDEX[:roles]",
                   help="camera index with roles, e.g. 0:objects or 1:hands or 0:objects,hands (repeatable, max 2)")
    p.add_argument("--detector", choices=["none", "yolo", "cloudflare"], default="none")
    p.add_argument("--yolo-model", default="yolov8n.pt")
    p.add_argument("--hands", action="store_true", help="enable MediaPipe hand tracking on cameras with the hands role")
    p.add_argument("--gesture", nargs="?", const="", default=None, metavar="CAMERA",
                   help="hand joystick: pinch events (hand_control) from CAMERA (index or part of its name; "
                        "default config gesture.camera)")
    p.add_argument("--gesture-landmarks", action="store_true", help="include the 21 landmarks in hand_control (debug)")
    p.add_argument("--list-cameras", action="store_true", help="list cameras with their OpenCV index (macOS)")
    p.add_argument("-v", "--verbose", action="store_true")
    return p


def make_vision(args: argparse.Namespace, gesture_cfg: dict | None = None) -> VisionService | None:
    gesture = getattr(args, "gesture", None)
    if not args.camera and gesture is None:
        return None
    cams: list[CameraConfig] = []
    for i, spec in enumerate(args.camera[:2]):
        idx, _, roles = spec.partition(":")
        role_t = tuple(r.strip() for r in roles.split(",") if r.strip()) or ("objects",)
        cams.append(CameraConfig(index=resolve_camera(idx), roles=role_t, name="AB"[i]))
    if gesture is not None:
        g = gesture_cfg or {}
        spec = gesture or str(g.get("camera", "0"))
        cams.append(CameraConfig(index=resolve_camera(spec), width=int(g.get("frame_width", 640)),
                                 height=int(g.get("frame_height", 480)), fps=float(g.get("fps", 30.0)),
                                 roles=("hands",), name="G", control=HandControl(HandControlConfig.from_dict(g)),
                                 debug_landmarks=bool(getattr(args, "gesture_landmarks", False))))
        log.info("hand joystick on camera %s (index %d)", spec, cams[-1].index)
    detector = None
    if args.detector == "yolo":
        from .vision_service.yolo_detector import YoloDetector
        detector = YoloDetector(args.yolo_model)
    elif args.detector == "cloudflare":
        from .vision_service.cloudflare_detector import CloudflareDetector
        detector = CloudflareDetector()
    hands = None
    if args.hands or gesture is not None:
        from .vision_service.mediapipe_hands import MediaPipeHandTracker
        hands = MediaPipeHandTracker(delegate=str((gesture_cfg or {}).get("delegate", "gpu")))
    return VisionService(cams, detector, hands)


async def run(args: argparse.Namespace) -> int:
    cfg = load_config()
    if args.port:
        cfg.serial_port = args.port
    if args.baud:
        cfg.baudrate = args.baud
    if args.ws_host:
        cfg.websocket_host = args.ws_host
    if args.ws_port:
        cfg.websocket_port = args.ws_port
    robot = MockRobot(cfg.limits) if args.mock else RealRobot(cfg)
    vision = make_vision(args, cfg.raw.get("gesture", {}))
    server = GameServer(robot, cfg.websocket_host, cfg.websocket_port, state_hz=args.state_hz, vision=vision)
    try:
        await robot.connect()
    except Exception as e:
        log.error("robot connect failed: %s (server keeps running; Godot will show DISCONNECTED)", e)
    await server.start()
    if vision:
        vision.start()
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    log.info("running: robot=%s  ws://%s:%d  (Ctrl-C to stop)", robot.name, cfg.websocket_host, cfg.websocket_port)
    await stop.wait()
    log.info("shutting down")
    if vision:
        vision.stop()
    await server.stop()
    await robot.disconnect()
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if args.list_ports:
        for p in list_serial_ports():
            print(f"{p['device']}\t{p['description']}\t{p['hwid']}")
        return 0
    if args.list_cameras:
        for i, c in enumerate(list_cameras_macos()):
            print(f"{i}\t{c['name']}\t{c['unique_id']}")
        return 0
    try:
        return asyncio.run(run(args))
    except KeyboardInterrupt:  # pragma: no cover
        return 130


if __name__ == "__main__":
    sys.exit(main())

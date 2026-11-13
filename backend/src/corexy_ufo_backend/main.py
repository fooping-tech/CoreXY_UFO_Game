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
import os
import signal
import sys
import threading

from .config import load_config
from .sequence import AutoCatchConfig
from .robot import RealRobot
from .sequence import Phase
from .sequence.dry_run import known_faults, make_dry_run_robot, run_dry
from .serial_service.transport import list_serial_ports
from .vision_service import CameraConfig, VisionService
from .vision_service.cameras import list_cameras, resolve_camera
from .vision_service.hand_control import HandControl, HandControlConfig
from .websocket import GameServer
from .config import REPO_ROOT
from .homework import HomeworkConfig, HomeworkService, LocateParams, SpeechConfig, SpeechService
from .homework.approach import ApproachParams
from .homework.camera_map import CameraMapParams
from .study import StudyConfig, StudyService, make_adapter
from .study_mode import WorksheetCatalog, WorksheetError

log = logging.getLogger("corexy_ufo_backend")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="corexy-ufo-backend")
    p.add_argument("--mock", action="store_true", help="use the simulated robot (no serial; the auto catch runs as a dry run)")
    p.add_argument("--auto-catch-dry-run", nargs="?", const="", default=None, metavar="FAULT",
                   help="run the auto catch once against the virtual crane and exit (nothing is sent to hardware); "
                        "FAULT: stall_xy, stall_z, claw_stall, claw_fail, z_glitch, disconnect, estop, limit_x, limit_y")
    p.add_argument("--fault-at", default="LOWER_TO_CATCH", help="state in which --auto-catch-dry-run injects FAULT")
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
    p.add_argument("--list-cameras", action="store_true", help="list cameras with their OpenCV index (macOS / Windows)")
    p.add_argument("--study", action="store_true",
                   help="enable the optional camera study assistant (also requires study.enabled in config)")
    p.add_argument("--stop-on-stdin-close", action="store_true",
                   help="stop cleanly (as on Ctrl-C) when stdin reaches EOF: start.ps1 closes it to end the backend")
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
        g = gesture_cfg or {}
        hands = MediaPipeHandTracker(delegate=str(g.get("delegate", "gpu")), recreate_s=float(g.get("gpu_recreate_s", 10.0)),
                                     min_confidence=float(g.get("detection_confidence", 0.5)),
                                     tracking_confidence=float(g.get("tracking_confidence", 0.3)))
    return VisionService(cams, detector, hands)


def install_stop_handlers(loop: asyncio.AbstractEventLoop, stop: asyncio.Event) -> None:
    """Ctrl-C / SIGTERM set `stop`, so run() shuts the server and the robot down in order."""
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:  # Windows: the event loop has no signal handlers
            signal.signal(sig, lambda *_: loop.call_soon_threadsafe(stop.set))


def stop_when_closed(loop: asyncio.AbstractEventLoop, stop: asyncio.Event, fd: int | None) -> None:
    """Set `stop` when the pipe `fd` reaches EOF. Windows has no SIGTERM for start.ps1 to send, so it
    closes the backend's stdin instead; run() then stops the server and the robot (ABORT if busy)
    as on Ctrl-C. The pipe also closes if start.ps1 itself dies. The raw fd, not sys.stdin: a
    daemon thread blocked in a buffered read would hold its lock at interpreter shutdown."""
    if fd is None:  # no stdin (e.g. pythonw): nothing to watch, Ctrl-C still works
        log.warning("--stop-on-stdin-close ignored: there is no stdin")
        return

    def wait() -> None:
        try:
            while os.read(fd, 4096):
                pass
        except OSError:
            pass
        try:
            loop.call_soon_threadsafe(stop.set)
        except RuntimeError:  # the loop is already closed: run() has ended
            pass
    threading.Thread(target=wait, name="stdin-close", daemon=True).start()


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
    auto_cfg = AutoCatchConfig.from_raw(cfg.raw)
    if args.mock:
        # the mock's own speeds (the game's manual controls stay as they were) plus the
        # dry run's virtual claw / inputs for the auto catch
        robot = make_dry_run_robot(auto_cfg.dry_run, cfg.limits, speed_model=False)
    else:
        robot = RealRobot(cfg)
    vision = make_vision(args, cfg.raw.get("gesture", {}))
    study_cfg = StudyConfig.from_raw(cfg.raw)
    study = None
    if args.study and study_cfg.enabled:
        try:
            study = StudyService(study_cfg, make_adapter(study_cfg))
            log.info("study assistant enabled: %s (starts on the first session)", study_cfg.provider)
        except ValueError as e:
            log.error("study assistant disabled: %s", e)
    elif args.study:
        log.warning("--study ignored because study.enabled is false in config")
    hw_cfg = HomeworkConfig.from_raw(cfg.raw, env_path=REPO_ROOT / ".env")
    # the study mode (#86) needs the homework service for its voice, the per-problem watch and
    # the explanation, even with the F1 panel's homework watch off
    study_mode_on = bool((cfg.raw.get("study_mode") or {}).get("enabled", False))
    worksheets = None
    try:
        worksheets = WorksheetCatalog.load()
    except WorksheetError as e:
        log.warning("study mode worksheets unavailable: %s", e)
    # the advice uses the study assistant's provider (Claude Code / Codex) without needing --study
    homework = HomeworkService(hw_cfg, advice_factory=lambda: make_adapter(study_cfg),
                               locate=LocateParams.from_raw(cfg.raw),
                               speech=SpeechService(SpeechConfig.from_raw(cfg.raw)),
                               worksheets=worksheets) if (hw_cfg.enabled or study_mode_on) else None
    if homework is not None:
        log.info("homework watch enabled (Jev; key from the environment or %s)", hw_cfg.env_path)
    server = GameServer(robot, cfg.websocket_host, cfg.websocket_port, state_hz=args.state_hz, vision=vision,
                        auto_catch=auto_cfg, backend_cfg=cfg, study=study, homework=homework, approach=ApproachParams.from_raw(cfg.raw),
                        camera_map=CameraMapParams.from_raw(cfg.raw))
    try:
        await robot.connect()
    except Exception as e:
        log.error("robot connect failed: %s (server keeps running; Godot will show DISCONNECTED)", e)
    await server.start()
    if vision:
        vision.start()
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    install_stop_handlers(loop, stop)
    if args.stop_on_stdin_close:
        stop_when_closed(loop, stop, sys.stdin.fileno() if sys.stdin else None)
    log.info("running: robot=%s  ws://%s:%d  (Ctrl-C to stop)", robot.name, cfg.websocket_host, cfg.websocket_port)
    await stop.wait()
    log.info("shutting down")
    if vision:
        vision.stop()
    await server.stop()
    await robot.disconnect()
    return 0


async def auto_catch_dry_run(fault: str, fault_at: str) -> int:
    """--auto-catch-dry-run: 0 = the run ended as expected (done, or FAULT when a fault was injected)."""
    cfg = load_config()
    params = AutoCatchConfig.from_raw(cfg.raw).dry_run
    if fault and fault not in known_faults():
        print(f"unknown fault {fault!r}; one of: {', '.join(known_faults())}")
        return 2
    seq = await run_dry(params, cfg.limits, cfg, fault=fault or None, fault_at=Phase(fault_at))
    expected = "fault" if fault else "done"
    print(f"expected {expected}: {'OK' if seq.last_result == expected else 'UNEXPECTED'}")
    return 0 if seq.last_result == expected else 1


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if args.list_ports:
        for p in list_serial_ports():
            print(f"{p['device']}\t{p['description']}\t{p['hwid']}")
        return 0
    if args.list_cameras:
        for i, c in enumerate(list_cameras()):
            print(f"{i}\t{c['name']}\t{c['unique_id']}")
        return 0
    if args.auto_catch_dry_run is not None:
        return asyncio.run(auto_catch_dry_run(args.auto_catch_dry_run, args.fault_at))
    try:
        return asyncio.run(run(args))
    except KeyboardInterrupt:  # pragma: no cover
        return 130


if __name__ == "__main__":
    sys.exit(main())

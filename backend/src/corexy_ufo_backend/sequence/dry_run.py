"""Dry run of the auto catch: the whole sequence against DryRunRobot, nothing sent to hardware.

    uv run corexy-ufo-backend --auto-catch-dry-run            # normal run
    uv run corexy-ufo-backend --auto-catch-dry-run stall_z    # with a fault injected mid-way
    uv run corexy-ufo-backend --auto-catch-dry-run estop      # the virtual E-stop input
    uv run corexy-ufo-backend --auto-catch-dry-run limit_x    # a limit switch away from home
"""

from __future__ import annotations

import asyncio
import contextlib

from ..config import BackendConfig, RobotLimits
from ..robot.dry_run import FAULTS, DryRunRobot
from .auto_catch import AutoCatchSequencer, Phase
from .params import AutoCatchParams

INPUT_FAULTS = ("estop", "limit_x", "limit_y")


def make_dry_run_robot(params: AutoCatchParams, limits: RobotLimits, *, speed_model: bool = True) -> DryRunRobot:
    """DryRunRobot driven by the dry_run profile (virtual claw, input polarity, and with
    speed_model the profile's XY feed / accelerations / Z speed instead of the mock's)."""
    p, pol = params, params.polarity
    kw = {}
    if speed_model and p.xy_accel_mm_s2 and p.z_speed_units_s and p.z_accel_units_s2 and p.xy_feed_mm_min:
        kw = dict(speed_xy=p.xy_feed_mm_min / 60.0, accel_xy=p.xy_accel_mm_s2,
                  speed_z=p.z_speed_units_s, accel_z=p.z_accel_units_s2)
    return DryRunRobot(
        limits,
        claw_closed_deg=p.virtual_claw_closed_deg if p.virtual_claw_closed_deg is not None else 0.0,
        claw_open_deg=p.virtual_claw_open_deg if p.virtual_claw_open_deg is not None else -120.0,
        claw_move_s=p.virtual_claw_move_s if p.virtual_claw_move_s is not None else 0.4,
        limit_active_high=bool(pol.limit_active_high), estop_active_high=bool(pol.estop_active_high),
        **kw)


async def _ticker(robot: DryRunRobot) -> None:
    while True:
        await robot.tick()
        await asyncio.sleep(0.005)


async def run_dry(params: AutoCatchParams, limits: RobotLimits, backend: BackendConfig | None = None,
                  fault: str | None = None, fault_at: Phase = Phase.LOWER_TO_CATCH,
                  start_xy: tuple[float, float] = (120.0, 100.0), echo=print) -> AutoCatchSequencer:
    """Arm + home the virtual crane, move to start_xy, run the sequence; inject `fault`
    when the sequence enters `fault_at`. Returns the finished sequencer."""
    robot = make_dry_run_robot(params, limits)
    await robot.connect()
    tick = asyncio.get_running_loop().create_task(_ticker(robot))
    injected = False
    shown = 0

    def on_change(st: dict) -> None:
        nonlocal injected, shown
        if seq.history and len(seq.history) != shown:
            shown = len(seq.history)
            h = seq.history[-1]
            echo(f"  {h['from']:>17} -> {h['to']:<17} {h['note']}")
        if fault and not injected and st["phase"] == str(fault_at):
            injected = True
            echo(f"  !! inject {fault}")
            if fault in INPUT_FAULTS:
                robot.press_input(fault)
            else:
                robot.inject(fault)

    seq = AutoCatchSequencer(robot, params, limits, backend, on_change=on_change)
    try:
        await robot.enable_motors(True)
        await robot.home()
        await robot.move_xy(*start_xy)
        while robot.snapshot().state != "IDLE" or abs(robot.pos[0] - start_xy[0]) > 0.01:
            await asyncio.sleep(0.01)
        echo(f"dry run: profile={params.profile} start XY={start_xy} fault={fault or '-'}")
        await seq.start()
        await seq.wait()
        echo(f"result: {seq.last_result} phase={seq.phase} error={seq.error or '-'}")
        echo("virtual commands (not sent): " + " | ".join(robot.commands))
    finally:
        tick.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await tick
    return seq


def known_faults() -> tuple[str, ...]:
    return FAULTS + INPUT_FAULTS

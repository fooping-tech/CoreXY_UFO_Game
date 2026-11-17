"""#161: the reading side of the USB link dies (a hub's transaction error) while the port
stays open and writes still reach the firmware. The backend notices, stops what it can,
drops the link and reopens the port."""

from __future__ import annotations

import asyncio
import time

import pytest

from conftest import FakeFirmware
from corexy_ufo_backend.config import BackendConfig, RobotLimits
from corexy_ufo_backend.robot import RealRobot
from corexy_ufo_backend.robot.state import MachineState
from corexy_ufo_backend.serial_service.service import SERIAL_SILENT_MSG, CommandTimeout, SerialError, SerialService
from corexy_ufo_backend.serial_service.transport import link_report


@pytest.fixture
async def svc():
    s = SerialService("fake", transport_factory=FakeFirmware)
    await s.connect(startup_delay=0, drain_s=0.01)
    yield s
    await s.disconnect()


class Ports:
    """A transport factory that keeps every FakeFirmware it opens; `fail` refuses to open."""

    def __init__(self) -> None:
        self.opened: list[FakeFirmware] = []
        self.fail = False

    def __call__(self, port, baud, **kw) -> FakeFirmware:
        if self.fail:
            raise OSError("could not open port")
        fw = FakeFirmware(port, baud, **kw)
        self.opened.append(fw)
        return fw


@pytest.fixture
async def rig():
    cfg = BackendConfig(limits=RobotLimits(z_max=100.0, z_up_is_positive=True), z_counts_per_unit=122.88, z_sign=1,
                        serial_rx_stall_s=0.5, serial_reopen_s=0.2)
    ports = Ports()
    svc = SerialService("fake", transport_factory=ports)
    r = RealRobot(cfg, svc)
    await r.connect()
    yield r, ports
    await r.disconnect()


def _went_silent(r: RealRobot, s_ago: float = 10.0) -> FakeFirmware:
    fw = r.serial.transport
    fw.rx_dead = True
    r.serial._unanswered_since = time.monotonic() - s_ago  # a command sent that long ago, unanswered
    return fw


async def test_answered_commands_are_not_silence(svc):
    await svc.query_pos()
    assert svc.rx_stalled_for() == 0.0


async def test_a_command_without_any_reply_counts_as_silence(svc):
    svc.transport.rx_dead = True
    with pytest.raises(CommandTimeout):
        await svc.send("POS", timeout=0.1)  # the ACK wait is 3 s, the command's 0.1 s is not reached
    assert svc.rx_stalled_for() >= 3.0
    svc.transport.rx_dead = False
    await svc.query_pos()  # any line read ends the silence
    assert svc.rx_stalled_for() == 0.0


async def test_written_lines_alone_are_not_silence(svc):
    svc.transport.rx_dead = True
    svc.write_raw("JOG 0.0 0.0")  # a zero JOG while not jogging gets no reply from the firmware
    assert svc.rx_stalled_for(time.monotonic() + 60) == 0.0


async def test_dropping_the_link_fails_a_waiting_command_with_the_reason(svc):
    svc.transport.rx_dead = True
    lost: list[bool] = []
    svc.set_disconnect_callback(lambda: lost.append(True))
    waiting = asyncio.create_task(svc.send("POS", timeout=5))
    await asyncio.sleep(0.05)
    await svc.drop_link(SERIAL_SILENT_MSG)
    with pytest.raises(SerialError, match="no reply from the robot"):
        await waiting
    assert not svc.connected and svc.last_error == SERIAL_SILENT_MSG and lost == [True]


async def test_a_silent_link_is_dropped_after_a_blind_stop(rig):
    r, ports = rig
    await r.enable_motors(True)
    await r.jog(0.0, 0.0, 10.0)
    fw = _went_silent(r)
    await r.tick()
    assert fw.sent[-1] == "JOG 0.0 0.0"  # the writes may still reach the firmware
    s = r.snapshot()
    assert not s.connected and not s.motors_enabled and s.state == MachineState.UNKNOWN
    assert r.error.startswith(SERIAL_SILENT_MSG)
    assert not r._jogging and not r._jog_requested


async def test_a_silent_link_during_a_command_sends_abort(rig):
    r, _ = rig
    fw = _went_silent(r)
    r._busy = True  # a move / home / grab is waiting on the line
    await r.tick()
    r._busy = False
    assert "ABORT" in fw.sent and not r.serial.connected


async def test_a_short_silence_is_not_dropped(rig):
    r, _ = rig
    _went_silent(r, s_ago=0.1).rx_dead = False  # (so the tick's POS poll is answered at once)
    await r.tick()
    assert r.serial.connected


async def test_the_port_is_reopened_after_a_drop(rig):
    r, ports = rig
    _went_silent(r)
    await r.tick()
    assert not r.serial.connected
    await r.tick()  # too early: the reopen waits serial_reopen_s
    assert len(ports.opened) == 1
    r._reopen_at = 0.0
    await r.tick()
    s = r.snapshot()
    assert len(ports.opened) == 2 and s.connected and r.error == ""
    assert not s.motors_enabled  # enable_motors again, as after a start


async def test_a_failed_reopen_keeps_the_reason_and_tries_again(rig):
    r, ports = rig
    _went_silent(r)
    await r.tick()
    ports.fail = True
    r._reopen_at = 0.0
    await r.tick()
    assert not r.serial.connected and r.error.startswith(SERIAL_SILENT_MSG)
    assert r._reopen_wanted and r._reopen_at > time.monotonic()
    ports.fail = False
    r._reopen_at = 0.0
    await r.tick()
    assert r.serial.connected


async def test_a_link_lost_again_while_reopening_is_tried_again(rig):
    r, ports = rig
    r.serial._on_transport_lost(OSError("device disconnected"))

    class Flaky(FakeFirmware):
        async def open(self) -> None:
            await super().open()
            self._loop.call_soon(self.on_disconnect, OSError("gone again"))  # during the start's drain

    ports_open = ports.__call__
    r.serial._transport_factory = lambda port, baud, **kw: Flaky(port, baud, **kw)
    r._reopen_at = 0.0
    await r.tick()
    assert not r.serial.connected and r._reopen_wanted and "gone again" in r.error
    r.serial._transport_factory = ports_open
    r._reopen_at = 0.0
    await r.tick()
    assert r.serial.connected and not r._reopen_wanted


async def test_no_reopen_when_turned_off(rig):
    r, ports = rig
    r.cfg.serial_reopen_s = 0.0
    _went_silent(r)
    await r.tick()
    r._reopen_at = 0.0
    await r.tick()
    assert not r.serial.connected and len(ports.opened) == 1


async def test_an_unplugged_cable_is_reopened_too(rig):
    r, ports = rig
    r.serial._on_transport_lost(OSError("device disconnected"))
    assert not r.serial.connected and r._reopen_wanted
    r._reopen_at = 0.0
    await r.tick()
    assert r.serial.connected and len(ports.opened) == 2


def test_link_report_says_the_link_went_silent():
    port = "/dev/cu.usbserial-AAAA"
    rep = link_report([port], port, [port], False, SERIAL_SILENT_MSG + " (5 s without a reply)")
    assert rep["problem"] == "silent"

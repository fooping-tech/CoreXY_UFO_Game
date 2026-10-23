import asyncio

import pytest

from conftest import FakeFirmware
from corexy_ufo_backend.serial_service.service import CommandRejected, CommandTimeout, SerialService


@pytest.fixture
async def svc():
    s = SerialService("fake", transport_factory=FakeFirmware)
    await s.connect(startup_delay=0, drain_s=0.01)
    yield s
    await s.disconnect()


async def test_pos_roundtrip(svc):
    pos = await svc.query_pos()
    assert pos.x == 0.0 and not pos.homed


async def test_home_then_xy(svc):
    r = await svc.send("HOME", timeout=2)
    assert r.completion.startswith("HOME complete")
    r = await svc.send("XY 10 20 900", timeout=2)
    assert r.completion.startswith("ACK_XY")
    assert svc.transport.sent[-1] == "XY 10 20 900"


async def test_xy_not_homed_is_nack(svc):
    r = await svc.send("XY 10 20 900", timeout=2)
    assert r.completion.startswith("NACK_XY")
    assert r.failed


async def test_queue_full_retry(svc):
    svc.transport.queue_full_once = True
    r = await svc.send("POS", timeout=2)
    assert r.completion.startswith("POS")
    assert svc.transport.sent.count("POS") == 2


async def test_unknown_command_rejected(svc):
    with pytest.raises(CommandRejected):
        await svc.send("FOO", timeout=1)


async def test_timeout(svc):
    svc.transport.move_delay = 5.0
    await svc.send("HOME", timeout=10) if False else None
    svc.transport.homed = True
    with pytest.raises(CommandTimeout):
        await svc.send("XY 1 1 900", timeout=0.2)


async def test_commands_are_serialised(svc):
    svc.transport.homed = True
    svc.transport.move_delay = 0.05
    results = await asyncio.gather(svc.send("XY 1 1 900", timeout=2), svc.send("XY 2 2 900", timeout=2))
    assert all(r.completion.startswith("ACK_XY") for r in results)
    assert svc.transport.sent == ["XY 1 1 900", "XY 2 2 900"]


async def test_abort_and_clear(svc):
    await svc.abort()
    pos = await svc.query_pos()
    assert pos.alarm and pos.alarm_reason == "abort requested" and not pos.homed
    r = await svc.send("ALARM_CLEAR", timeout=1)
    assert r.completion == "ALARM_CLEAR complete"


async def test_disconnect_fails_pending():
    s = SerialService("fake", transport_factory=FakeFirmware)
    await s.connect(startup_delay=0, drain_s=0.01)
    s.transport.homed = True
    s.transport.move_delay = 5.0
    task = asyncio.create_task(s.send("XY 1 1 900", timeout=10))
    await asyncio.sleep(0.05)
    await s.disconnect()
    with pytest.raises(Exception):
        await task

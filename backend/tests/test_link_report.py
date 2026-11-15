"""Why the robot's serial link is down (#124): the answer of list_ports for the 校正 tab."""

from __future__ import annotations

from corexy_ufo_backend.config import BackendConfig
from corexy_ufo_backend.robot.mock_robot import MockRobot
from corexy_ufo_backend.serial_service.transport import link_report
from corexy_ufo_backend.websocket.server import GameServer

A = "/dev/cu.usbserial-AAAA"
B = "/dev/cu.usbserial-BBBB"
C = "/dev/cu.usbserial-CCCC"
NOISE = ["/dev/cu.Bluetooth-Incoming-Port", "/dev/cu.debug-console"]


def test_connected_is_no_problem():
    r = link_report([A], A, [A, *NOISE], True)
    assert r["problem"] == "" and r["connected"] and r["others"] == []


def test_another_board_is_plugged_in():
    r = link_report([A, ""], A, [C, *NOISE], False, "could not open port")
    assert r["problem"] == "port_missing"
    assert r["registered"] == [A] and r["others"] == [C] and r["port"] == A and r["error"] == "could not open port"


def test_the_hubs_port_is_not_offered_as_another_board():
    hub = "/dev/cu.usbmodem1101"
    r = link_report([A], A, [C, hub], False, not_robot=(hub,))
    assert r["problem"] == "port_missing" and r["others"] == [C]


def test_registered_board_unplugged_and_nothing_else():
    r = link_report([A, B], A, NOISE, False)
    assert r["problem"] == "port_missing" and r["others"] == []


def test_no_port_at_all_with_nothing_registered():
    r = link_report(["", ""], None, NOISE, False, "no serial port found")
    assert r["problem"] == "no_port" and r["registered"] == []


def test_port_is_there_but_the_link_is_down():
    assert link_report([A], A, [A], False, "Resource busy")["problem"] == "open_failed"
    # nothing registered: the guessed port was tried
    assert link_report([], C, [C], False, "no POS reply")["problem"] == "open_failed"
    # the second registered board is plugged in, the link dropped later
    assert link_report([A, B], B, [B], False, "serial lost: device removed")["problem"] == "open_failed"


class DownReal(MockRobot):
    """A robot named "real" whose link never came up."""
    name = "real"

    def snapshot(self):
        s = super().snapshot()
        s.connected = False
        return s


async def test_list_ports_says_why_the_real_robot_is_not_connected(monkeypatch):
    import corexy_ufo_backend.serial_service.transport as transport
    monkeypatch.setattr(transport, "list_serial_ports", lambda: [{"device": C, "description": "", "hwid": ""}])
    cfg = BackendConfig()
    cfg.serial_port, cfg.serial_port_2 = A, ""
    robot = DownReal()
    srv = GameServer(robot, "127.0.0.1", 0, backend_cfg=cfg)
    srv.connect_error = "could not open port"
    reply = await srv.execute("list_ports", {})
    link = reply["data"]["robot"]
    assert reply["type"] == "ack" and reply["data"]["ports"][0]["device"] == C
    assert link["kind"] == "real" and link["problem"] == "port_missing"
    assert link["registered"] == [A] and link["others"] == [C] and link["error"] == "could not open port"


async def test_list_ports_for_the_mock_has_no_problem():
    srv = GameServer(MockRobot(), "127.0.0.1", 0)
    await srv.robot.connect()
    link = (await srv.execute("list_ports", {}))["data"]["robot"]
    assert link == {"kind": "mock", "connected": True, "problem": ""}

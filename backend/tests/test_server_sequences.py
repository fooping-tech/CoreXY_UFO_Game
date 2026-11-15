"""The server's list of automatic sequences (#122): what is done to one is done to all.

A new sequence that is not in GameServer.sequences would not be aborted by stop: the
first test fails for it."""

from __future__ import annotations

from corexy_ufo_backend.robot.mock_robot import MockRobot
from corexy_ufo_backend.robot.real_robot import RealRobot
from corexy_ufo_backend.websocket.server import GameServer


class Recorder:
    """Stands in for a sequencer: records the aborts."""

    def __init__(self, active: bool = True) -> None:
        self.active = active
        self.aborts: list[tuple[str, bool]] = []

    def status(self) -> dict:
        return {"active": self.active}

    async def abort(self, reason: str, *, send_stop: bool = True) -> bool:
        self.aborts.append((reason, send_stop))
        return self.active


def server_with_recorders(active: tuple[bool, ...] = (True, True, True)) -> tuple[GameServer, list[Recorder]]:
    srv = GameServer(MockRobot(), "127.0.0.1", 0)
    recorders = [Recorder(a) for a in active]
    for s, r in zip(srv.sequences, recorders, strict=True):
        s.seq = r
    return srv, recorders


def test_every_sequencer_of_the_server_is_in_the_list():
    srv = GameServer(MockRobot(), "127.0.0.1", 0)
    sequencers = [v for v in vars(srv).values() if hasattr(v, "request_abort") and hasattr(v, "abort")]
    assert len(sequencers) == 3
    listed = [s.seq for s in srv.sequences]
    assert all(any(q is listed_one for listed_one in listed) for q in sequencers)
    assert [s.key for s in srv.sequences] == ["auto_catch", "homework_approach", "study_cleanup"]


def test_stop_and_its_kin_are_accepted_while_any_sequence_runs():
    srv = GameServer(MockRobot(), "127.0.0.1", 0)
    for s in srv.sequences:
        assert {"stop", "soft_stop", "get_state"} <= set(s.allowed), s.key
        assert s.start_command not in ("stop", "soft_stop")


async def test_stop_aborts_every_sequence_without_a_second_stop():
    srv, recorders = server_with_recorders()
    reply = await srv.execute("stop", {})
    assert reply["type"] == "ack"
    assert [r.aborts for r in recorders] == [[("emergency stop (stop)", False)]] * 3
    assert srv.robot.snapshot().alarm  # the robot's own stop went out once, after the flags


async def test_motors_off_aborts_every_sequence():
    srv, recorders = server_with_recorders()
    await srv.execute("enable_motors", {"enable": False})
    assert [r.aborts for r in recorders] == [
        [("motors disabled during auto catch", True)],
        [("motors disabled during the homework approach", True)],
        [("motors disabled during the tidy-up", True)],
    ]


async def test_soft_stop_aborts_the_running_sequence():
    srv, recorders = server_with_recorders((False, True, False))
    reply = await srv.execute("soft_stop", {})
    assert reply["type"] == "ack"
    assert [r.aborts for r in recorders] == [[], [("stopped (soft_stop) during the homework approach", True)], []]


async def test_a_running_sequence_refuses_other_commands_with_its_own_reason():
    for i, reason in enumerate(["busy: auto catch running (stop to abort)",
                                "busy: the arm is approaching the homework (stop to abort)",
                                "busy: the study mode is tidying up (stop to abort)"]):
        srv, _ = server_with_recorders(tuple(j == i for j in range(3)))
        reply = await srv.execute("move_xy", {"x": 10, "y": 10})
        assert reply["type"] == "nack" and reply["data"]["reason"] == reason
        # a key release and motors off are never refused
        assert (await srv.execute("jog", {"vx": 0, "vy": 0, "vz": 0}))["type"] == "ack"


async def test_get_state_carries_every_sequence_status():
    srv, _ = server_with_recorders((True, False, False))
    data = (await srv.execute("get_state", {}))["data"]
    assert data["auto_catch"] == {"active": True}
    assert data["homework_approach"] == {"active": False} and data["study_cleanup"] == {"active": False}


def test_the_interface_says_which_robot_is_real_and_its_limits():
    mock = MockRobot()
    assert not mock.is_real and mock.limits is not None
    assert RealRobot.name == "real"

    class NamedReal(MockRobot):
        name = "real"

    real = NamedReal()
    assert real.is_real and GameServer(real, "127.0.0.1", 0).study_profile == "real"
    assert GameServer(mock, "127.0.0.1", 0).study_profile == "dry_run"

"""The tables of commands a running sequence accepts (websocket/wire.py). They are part of
the safety rules: a stop must be accepted whatever runs."""

from corexy_ufo_backend.websocket import wire

READ_ONLY = {"get_state", "auto_catch_status", "list_ports", "gesture_config", "homework_approach_status",
             "camera_map_status", "study_cleanup_status", "study_height_status", "easy_status"}
STOPS = {"stop", "soft_stop"}
# what each sequence accepts beyond the stops and the read-only commands (as before #212)
OWN = {
    "AUTO_CATCH_ALLOWED": {"auto_catch"},
    "APPROACH_ALLOWED": {"homework_approach", "homework_approach_release"},
    "PREPARE_ALLOWED": {"calibration_prepare_status"},
    "CLEANUP_ALLOWED": {"study_cleanup_start", "study_cleanup_confirm"},
    "EASY_ALLOWED": {"easy_deliver", "easy_cancel"},
}


def test_every_sequence_accepts_both_stops():
    for name in OWN:
        assert STOPS <= set(getattr(wire, name)), name
    assert STOPS <= set(wire.PRIORITY_COMMANDS)  # and they never wait behind a move


def test_each_table_is_exactly_the_stops_the_read_only_commands_and_its_own():
    for name, own in OWN.items():
        table = getattr(wire, name)
        assert set(table) == STOPS | READ_ONLY | own, name
        assert len(table) == len(set(table)), name
        assert set(table) <= set(wire.COMMANDS), name

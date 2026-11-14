"""Two registered Core2 boards: the one connected is used (#100)."""

from corexy_ufo_backend.serial_service.transport import pick_port

A = "/dev/cu.usbserial-AAAA"
B = "/dev/cu.usbserial-BBBB"
OTHER = "/dev/cu.usbmodem114101"


def test_first_board_connected():
    assert pick_port([A, B], [OTHER, A]) == A


def test_only_second_board_connected():
    assert pick_port([A, B], [OTHER, B]) == B


def test_both_connected_uses_the_first():
    assert pick_port([A, B], [B, A]) == A


def test_none_connected_tries_the_first_so_the_error_names_it():
    assert pick_port([A, B], [OTHER]) == A


def test_only_second_registered():
    assert pick_port(["", B], [B]) == B


def test_none_registered_leaves_it_to_auto_detect():
    assert pick_port(["", "  "], [OTHER, A]) == ""

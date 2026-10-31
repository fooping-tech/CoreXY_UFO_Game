from corexy_ufo_backend.serial_service import protocol as P

POS = ('POS X=12.500 Y=7.250 A=1580 B=420 F=900.000 EN=HARDWIRED_ACTIVE HOMED=YES X_HOMED=YES Y_HOMED=YES '
       'HOMING=Complete MOTION=NO JOB=IDLE PEN=UP ALARM=NO ALARM_REASON="none" TMC=READY LIMIT_X=OPEN LIMIT_Y=OPEN '
       'LIMIT_X_RAW=OPEN LIMIT_Y_RAW=OPEN TEST_MODE=ON JOY=NONE')


def test_parse_pos():
    p = P.parse_pos_line(POS)
    assert p is not None
    assert (p.x, p.y) == (12.5, 7.25)
    assert p.homed and p.tmc_ready and p.test_mode and not p.alarm and not p.motion
    assert p.alarm_reason == "none"
    assert not p.homing_active


def test_parse_pos_alarm_with_spaces_in_reason():
    line = POS.replace('ALARM=NO ALARM_REASON="none"', 'ALARM=YES ALARM_REASON="hard limit active away from home X"')
    p = P.parse_pos_line(line)
    assert p.alarm and p.alarm_reason.startswith("hard limit")


def test_parse_servo_result():
    r = P.parse_servo_result("SERVO_TURN id=1 value=-2.50 result=PASS target=-10240 actual=-10238 error=+2 ms=4300")
    assert r and r.ok and r.servo_id == 1 and r.value == -2.5 and r.actual == -10238
    r2 = P.parse_servo_result("SERVO_TURN id=1 value=4.00 result=REJECTED reason=turns_over")
    assert r2 and not r2.ok and r2.reason == "turns_over"


def test_parse_servo_status():
    s = P.parse_servo_status("SERVO_STATUS id=1 result=OK flags=0x00 mode=0 torque=1 raw=2048 goal=2048 limits=0/4095 tracking=YES abs=6144 turns=1.50 voltage=7.4 temp=33 moving=0")
    assert s and s.ok and s.abs_counts == 6144 and s.turns == 1.5 and s.tracking and not s.moving
    s2 = P.parse_servo_status("SERVO_STATUS id=2 result=NO_REPLY tracking=NO")
    assert s2 and not s2.ok and s2.abs_counts is None


def test_classify_and_failure():
    assert P.classify_line("ACK QUEUED XY") == "queue_ack"
    assert P.classify_line("ERROR: CommandQueue full") == "queue_full"
    assert P.classify_line("NACK_XY target=(1,2) reason=alarm") == "xy_failed"
    assert P.is_failure_line("REJECT: machine is not homed")
    assert P.is_failure_line("ERROR: unknown command: FOO")
    assert not P.is_failure_line("ERROR: CommandQueue full")
    assert not P.is_failure_line("ACK_XY target=(1,2)")


def test_builders_and_validation():
    assert P.cmd_xy(10, 20.5, 900) == "XY 10.000 20.500 900"
    assert P.cmd_servo_turn(1, -1.234) == "SERVO_TURN 1 -1.234"
    assert P.cmd_servo_turn(2, 1 / 360) == "SERVO_TURN 2 0.00278"  # 1 degree (it was sent as 0.00)
    assert P.cmd_servo_turn(1, 3.0) == "SERVO_TURN 1 3.00"
    import pytest
    with pytest.raises(ValueError):
        P.validate_line("X" * 200)
    with pytest.raises(ValueError):
        P.validate_line("XY 1 2\nABORT")

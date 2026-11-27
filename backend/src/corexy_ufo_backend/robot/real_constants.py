"""The real robot's constants: the servo IDs and counts, the waits, the messages for a servo
whose power was cut (see real_robot.py)."""

from __future__ import annotations

COUNTS_PER_TURN = 4096
MAX_TURNS_PER_COMMAND = 3.0
Z_SERVO_ID = 1
ARM_SERVO_ID = 2
# arm_step: largest single manual step of the claw servo (degrees)
ARM_STEP_MAX_DEG = 90.0
CLAW_TOLERANCE_DEG = 0.5  # already there: no turn
JOG_END_WAIT_S = 2.0
# #106: the drum at rest is kept when it moved this far since last kept; a call-back whose
# drift from it is over Z_RESTORE_MAX_DRIFT (3/8 of a turn) is refused (moved while off)
Z_REST_SAVE_COUNTS = 8
Z_RESTORE_MAX_DRIFT = 1536  # how long a servo command waits for a jog (and its ramp) to end
SERVO_SPEED_COUNTS_PER_S = 2400.0
# Z jog release ramp. The firmware's servo jog holds the position it last READ when
# the rate drops to 0; at speed that read lags the drum, so the servo overshoots and
# swings back ("reverses for a moment" on W/S release; the joystick's analog stick
# never drops the rate at once). Ramping the rate down first lets it stop cleanly.
# Ease-out (rate * f^2): the last steps are very slow, so the hanging arm is not
# thrown up and does not drop back when a raise (W) stops.
Z_RAMP_S = 0.35
# The drum servo alone lost power (operators cut it): it is back to one turn
# (limits 0/4095) while the firmware still tracks turns, so a jog stops silently
# at the end of that turn and the turn count is gone.
Z_SERVO_RESET_MSG = ("Z servo reset (its power was cut): a jog stops at the end of one turn "
                     "and the drum's turn count is lost; recover it (z_servo_recover), "
                     "then record the Z points again")
# Newer firmware (CoreXY_UFO #11) reports the same state as `tracking=LOST` and sets
# multi-turn again when the next jog starts (`JOG servo id=1 ... tracking=RESET`):
# no recovery command is needed, but the turn count is still gone.
Z_SERVO_LOST_MSG = ("Z servo reset (its power was cut): the drum's turn count is lost; "
                    "jog Z (the first press sets multi-turn again), then record the Z points again")
CLAW_SERVO_RESET_MSG = ("claw servo reset (its power was cut): its recorded counts are gone; "
                        "press again (the firmware refused this one before moving)")
# z_servo_recover: a SERVO_TURN this small (up), refused unmoved while the servo is reset
Z_RECOVER_TURNS = 0.01
# #348: a bus error made the firmware drop its count of a servo's turns (the servo did not lose
# power): the smallest turn has it take the count back from the servo (about 12 counts, 1 deg)
SERVO_NUDGE_TURNS = 0.003
Z_RESYNC_MSG = ("the drum servo's count of turns is being taken back after a servo bus error "
                "(it does not answer, or still moves): trying again")
CLAW_RESYNC_MSG = ("the claw servo's count of turns is being taken back after a servo bus error "
                   "(it does not answer, or still moves): trying again")
# #163: `JOG servo id=N disabled reason=...` that only a power cycle of that servo clears
# (CoreXY_UFO StsServoBus::enableTracking: the firmware cannot tell its turn count)
POWER_CYCLE_REASONS = ("unknown_turn_count", "goal_mismatch")
Z_RAMP_STEP_S = 0.04

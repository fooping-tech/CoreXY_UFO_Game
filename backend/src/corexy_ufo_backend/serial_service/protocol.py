"""Line protocol of the CoreXY_UFO firmware (M5Stack Core2, USB serial 115200 8N1).

Everything here is taken from the firmware source (CoreXY_UFO repo):
  * CommandTask.cpp     - line framing ('\\r' or '\\n'), max 127 chars,
                          `ACK QUEUED <CMD>` / `ERROR: <msg>` / `ERROR: CommandQueue full`
  * Diagnostics.cpp:92  - the POS / M114 line
  * MotionTask.cpp      - `ACK_XY target=(x,y) ...`, `NACK_XY ... reason=...`,
                          `SERVO_TURN id=N value=V result=PASS|... <detail>`,
                          `SERVO_STATUS id=N result=OK ... abs=<counts> ...`
  * HomingController.cpp:163 - `HOME complete X=.. Y=..`
  * MotionTask.cpp (a49bc54) - serial velocity jog and non-alarm stop
    (CoreXY_UFO docs/handoff/REPLY_FIRMWARE_JOG.md):
      `JOG vx vy [z arm]` -> `JOG start ...` once, then nothing per refresh;
      `JOG_POS X= Y= VX= VY= ...` every 50 ms; `JOG end reason=... X= Y= HOMED=`;
      `JOG soft_limit axis=X X=..`; `NACK_JOG reason=not_homed|alarm|homing|job_active|busy|bad_args`.
      A rejected press stays silent until `JOG 0 0` or a 250 ms gap.
      `STOP` -> `ACK QUEUED STOP` -> (stopped XY: `NACK_XY ... reason=stopped X= Y=`) -> `STOP complete X= Y= HOMED=`
There is NO JSON and NO watchdog for plain commands; JOG stops by itself after 250 ms without a refresh.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

LINE_MAX_CHARS = 127
BOOT_BANNER = "CoreXY plotter ready"

# --- completion patterns (what to wait for after `ACK QUEUED <cmd>`) -----------
COMPLETION_PATTERNS: dict[str, re.Pattern[str]] = {
    "XY": re.compile(r"^(ACK_XY|NACK_XY)\b"),
    "G0": re.compile(r"^(ACK_XY|NACK_XY)\b"),
    "G1": re.compile(r"^(ACK_XY|NACK_XY)\b"),
    "HOME": re.compile(r"^(HOME complete|HOMING error)\b"),
    "G28": re.compile(r"^(HOME complete|HOMING error)\b"),
    "POS": re.compile(r"^POS\b"),
    "M114": re.compile(r"^POS\b"),
    "SERVO_TURN": re.compile(r"^SERVO_TURN id=\d+ .*result="),
    "SERVO_ANGLE": re.compile(r"^SERVO_ANGLE id=\d+ .*result="),
    "SERVO_STATUS": re.compile(r"^SERVO_STATUS id=\d+ result="),
    "SERVO_OFF": re.compile(r"^SERVO_OFF id=\d+ result="),
    "TEST_MODE": re.compile(r"^TEST_MODE result="),
    "ALARM_CLEAR": re.compile(r"^ALARM_CLEAR complete"),
    "ABORT": re.compile(r"^ABORT complete"),
    "HOME_STATUS": re.compile(r"^HOME_STATUS\b"),
    "LIMIT_STATUS": re.compile(r"^LIMIT_STATUS\b"),
    "TEST_JOG": re.compile(r"^TEST_JOG result="),
    "STOP": re.compile(r"^STOP complete\b"),
}

JOG_TIMEOUT_S = 0.25  # firmware ends a jog session this long after the last JOG line

QUEUE_ACK_RE = re.compile(r"^ACK (QUEUED \S+|ABORT requested)")
QUEUE_FULL = "ERROR: CommandQueue full"
ERROR_RE = re.compile(r"^ERROR: ")
REJECT_RE = re.compile(r"^REJECT: ")

# Lines that mean "the command failed", mirrored from tools/serial_tool/serial_send.py
_FAILURE_MARKERS = ("NACK", "REJECT:", "rejected reason=", "ALARM=YES", "machine is alarmed")


def is_failure_line(line: str) -> bool:
    if line.startswith("ERROR:") and line != QUEUE_FULL:
        return True
    return any(m in line for m in _FAILURE_MARKERS)


def classify_line(line: str) -> str:
    """Coarse category for logging/state updates."""
    if line.startswith("POS "):
        return "pos"
    if line.startswith("JOG_POS "):
        return "jog_pos"
    if line.startswith("JOG start"):
        return "jog_start"
    if line.startswith("JOG end"):
        return "jog_end"
    if line.startswith("JOG soft_limit"):
        return "jog_soft_limit"
    if line.startswith("NACK_JOG"):
        return "jog_rejected"
    if line.startswith("STOP complete"):
        return "stop_done"
    if QUEUE_ACK_RE.match(line):
        return "queue_ack"
    if line == QUEUE_FULL:
        return "queue_full"
    if line.startswith("ERROR:"):
        return "error"
    if line.startswith("REJECT:"):
        return "reject"
    if line.startswith("ACK_XY"):
        return "xy_done"
    if line.startswith("NACK_XY"):
        return "xy_failed"
    if line.startswith("HOME complete"):
        return "home_done"
    if line.startswith("HOMING error"):
        return "home_failed"
    if line.startswith("SERVO_TURN") or line.startswith("SERVO_ANGLE"):
        return "servo_result"
    if line.startswith("SERVO_STATUS"):
        return "servo_status"
    if line.startswith("ABORT complete"):
        return "abort_done"
    if line.startswith("ALARM_CLEAR complete"):
        return "alarm_cleared"
    if line.startswith("TEST_MODE result="):
        return "test_mode"
    if line.startswith(BOOT_BANNER):
        return "boot"
    return "log"


# --- POS line -------------------------------------------------------------------
@dataclass
class PosReport:
    x: float
    y: float
    a_steps: int = 0
    b_steps: int = 0
    feed: float = 0.0
    homed: bool = False
    x_homed: bool = False
    y_homed: bool = False
    homing_state: str = "Idle"
    motion: bool = False
    job_active: bool = False
    alarm: bool = False
    alarm_reason: str = "none"
    tmc_ready: bool = False
    limit_x: bool = False
    limit_y: bool = False
    test_mode: bool = False
    raw: str = ""

    @property
    def homing_active(self) -> bool:
        return self.homing_state not in ("Idle", "Complete", "Alarm")


_POS_RE = re.compile(r"^POS X=(?P<x>-?[\d.]+) Y=(?P<y>-?[\d.]+)")
_KV_RE = re.compile(r'(\w+)=("[^"]*"|\S+)')


def parse_pos_line(line: str) -> PosReport | None:
    m = _POS_RE.match(line)
    if not m:
        return None
    kv = {k: v.strip('"') for k, v in _KV_RE.findall(line)}

    def yes(key: str) -> bool:
        return kv.get(key, "NO") in ("YES", "ON", "ACTIVE", "READY")

    def num(key: str, default: float = 0.0) -> float:
        try:
            return float(kv.get(key, default))
        except ValueError:
            return default

    return PosReport(
        x=float(m.group("x")),
        y=float(m.group("y")),
        a_steps=int(num("A")),
        b_steps=int(num("B")),
        feed=num("F"),
        homed=yes("HOMED"),
        x_homed=yes("X_HOMED"),
        y_homed=yes("Y_HOMED"),
        homing_state=kv.get("HOMING", "Idle"),
        motion=yes("MOTION"),
        job_active=kv.get("JOB", "IDLE") == "ACTIVE",
        alarm=yes("ALARM"),
        alarm_reason=kv.get("ALARM_REASON", "none"),
        tmc_ready=yes("TMC"),
        limit_x=yes("LIMIT_X"),
        limit_y=yes("LIMIT_Y"),
        test_mode=yes("TEST_MODE"),
        raw=line,
    )


# --- servo lines ------------------------------------------------------------------
@dataclass
class ServoResult:
    command: str
    servo_id: int
    value: float
    result: str  # PASS | TIMEOUT | ABORTED | REJECTED | FAILED
    target: int | None = None
    actual: int | None = None
    reason: str = ""
    raw: str = ""

    @property
    def ok(self) -> bool:
        return self.result == "PASS"


_SERVO_RESULT_RE = re.compile(
    r"^(?P<cmd>SERVO_TURN|SERVO_ANGLE) id=(?P<id>\d+) value=(?P<val>-?[\d.]+) result=(?P<res>\w+)(?P<rest>.*)$"
)


def parse_servo_result(line: str) -> ServoResult | None:
    m = _SERVO_RESULT_RE.match(line)
    if not m:
        return None
    rest = dict(_KV_RE.findall(m.group("rest")))

    def opt_int(key: str) -> int | None:
        try:
            return int(rest[key])
        except (KeyError, ValueError):
            return None

    return ServoResult(
        command=m.group("cmd"),
        servo_id=int(m.group("id")),
        value=float(m.group("val")),
        result=m.group("res"),
        target=opt_int("target"),
        actual=opt_int("actual"),
        reason=rest.get("reason", "").strip('"'),
        raw=line,
    )


@dataclass
class ServoStatus:
    servo_id: int
    result: str
    abs_counts: int | None = None
    turns: float | None = None
    moving: bool = False
    torque: bool = False
    tracking: bool = False
    voltage: float | None = None
    temp: int | None = None
    extra: dict[str, str] = field(default_factory=dict)
    raw: str = ""

    @property
    def ok(self) -> bool:
        return self.result == "OK"


_SERVO_STATUS_RE = re.compile(r"^SERVO_STATUS id=(?P<id>\d+) result=(?P<res>\w+)(?P<rest>.*)$")


def parse_servo_status(line: str) -> ServoStatus | None:
    m = _SERVO_STATUS_RE.match(line)
    if not m:
        return None
    rest = {k: v.strip('"') for k, v in _KV_RE.findall(m.group("rest"))}
    st = ServoStatus(servo_id=int(m.group("id")), result=m.group("res"), extra=rest, raw=line)
    try:
        if "abs" in rest:
            st.abs_counts = int(rest["abs"])
        if "turns" in rest:
            st.turns = float(rest["turns"])
        st.moving = rest.get("moving", "0") not in ("0", "NO")
        st.torque = rest.get("torque", "0") not in ("0", "NO")
        st.tracking = rest.get("tracking", "NO") == "YES"
        if "voltage" in rest:
            st.voltage = float(rest["voltage"])
        if "temp" in rest:
            st.temp = int(rest["temp"])
    except ValueError:
        pass
    return st


# --- command builders -------------------------------------------------------------
def cmd_xy(x: float, y: float, feed: float | None = None) -> str:
    s = f"XY {x:.3f} {y:.3f}"
    if feed is not None:
        s += f" {feed:.0f}"
    return s


def cmd_servo_turn(servo_id: int, turns: float) -> str:
    return f"SERVO_TURN {servo_id} {turns:.2f}"


def cmd_servo_status(servo_id: int) -> str:
    return f"SERVO_STATUS {servo_id}"


def validate_line(cmd: str) -> None:
    if len(cmd) > LINE_MAX_CHARS:
        raise ValueError(f"command longer than {LINE_MAX_CHARS} chars")
    if "\n" in cmd or "\r" in cmd:
        raise ValueError("command must be a single line")


# --- JOG / STOP -----------------------------------------------------------------
def cmd_jog(vx_mm_s: float, vy_mm_s: float) -> str:
    return f"JOG {vx_mm_s:.1f} {vy_mm_s:.1f}"


def parse_kv(line: str) -> dict[str, str]:
    """KEY=VALUE fields of a status line (quotes stripped)."""
    return {k: v.strip('"') for k, v in _KV_RE.findall(line)}


def xy_from(line: str) -> tuple[float, float] | None:
    """X= / Y= of JOG_POS, JOG end, STOP complete, NACK_XY ... reason=stopped."""
    kv = parse_kv(line)
    try:
        return float(kv["X"]), float(kv["Y"])
    except (KeyError, ValueError):
        return None

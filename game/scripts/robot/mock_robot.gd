class_name MockRobot
extends Node
## Simulated crane. Moves each axis towards a target with bounded velocity and
## acceleration (trapezoid-like), reports IDLE/MOVING_XY/Z_* states and pushes
## samples into RobotState exactly like the real backend would. Also runs the
## scripted test scenarios used by the debug UI.

signal scenario_started(name: String)
signal scenario_finished(name: String)

var enabled: bool = true
## Report rate in Hz (simulates a slow status poll; the renderer interpolates).
var report_hz: float = 60.0
var max_speed_xy: float = 250.0 # mm/s
var accel_xy: float = 1000.0    # mm/s^2
var max_speed_z: float = 60.0    # units/s
var accel_z: float = 400.0
var jitter_mm: float = 0.0

var pos: Vector3 = Vector3.ZERO
var vel: Vector3 = Vector3.ZERO
var target: Vector3 = Vector3.ZERO
var grabbing: bool = false
var connected: bool = true
var _report_accum: float = 0.0
var _scenario: Array = []
var _scenario_name: String = ""
var _scenario_wait: float = 0.0
var _scenario_index: int = 0

func _ready() -> void:
	var r := GameConfig.robot()
	pos = Vector3((r.x_min_mm + r.x_max_mm) * 0.5, (r.y_min_mm + r.y_max_mm) * 0.5,
		r.z_max_mm if r.z_up_is_positive else r.z_min_mm)
	target = pos
	_report(true)

func set_target(p: Vector3) -> void:
	target = _clamp_to_limits(p)

func set_target_axis(axis: int, v: float) -> void:
	var t := target
	t[axis] = v
	set_target(t)

## Emergency stop: velocity goes to zero instantly, target = current.
func emergency_stop() -> void:
	vel = Vector3.ZERO
	target = pos
	_scenario.clear()

func set_connected(c: bool) -> void:
	connected = c
	RobotState.connected = c
	if not c:
		RobotState.machine_state = "UNKNOWN"
	else:
		_report(true)

func _clamp_to_limits(p: Vector3) -> Vector3:
	var r := GameConfig.robot()
	return Vector3(clampf(p.x, r.x_min_mm, r.x_max_mm), clampf(p.y, r.y_min_mm, r.y_max_mm), clampf(p.z, r.z_min_mm, r.z_max_mm))

func _physics_process(dt: float) -> void:
	if not enabled:
		return
	_tick_scenario(dt)
	for axis in range(3):
		var vmax := max_speed_z if axis == 2 else max_speed_xy
		var acc := accel_z if axis == 2 else accel_xy
		var d := target[axis] - pos[axis]
		var v := vel[axis]
		# velocity needed to stop exactly at target
		var stop_v := sqrt(2.0 * acc * absf(d)) * signf(d)
		var desired := clampf(stop_v, -vmax, vmax)
		v = move_toward(v, desired, acc * dt)
		if absf(d) < 0.02 and absf(v) < 1.0:
			v = 0.0
			pos[axis] = target[axis]
		else:
			pos[axis] += v * dt
		vel[axis] = v
	_report_accum += dt
	if _report_accum >= 1.0 / maxf(report_hz, 1.0):
		_report_accum = 0.0
		_report(false)

func _state_string() -> String:
	if grabbing:
		return "GRABBING"
	if absf(vel.z) > 0.01:
		var up := vel.z > 0.0 if GameConfig.robot().z_up_is_positive else vel.z < 0.0
		return "Z_RAISING" if up else "Z_LOWERING"
	if absf(vel.x) > 0.01 or absf(vel.y) > 0.01:
		return "MOVING_XY"
	return "IDLE"

func _report(force: bool) -> void:
	if not connected and not force:
		return
	RobotState.source = "mock"
	RobotState.connected = connected
	RobotState.homed = true
	var p := pos
	if jitter_mm > 0.0:
		p += Vector3(randf_range(-jitter_mm, jitter_mm), randf_range(-jitter_mm, jitter_mm), 0.0)
	RobotState.push_pose(p.x, p.y, p.z, _state_string(), 0, true)

# ----------------------------------------------------------------- scenarios
## Each step: {"move": Vector3(axis targets; NAN = keep), "wait": sec,
## "stop": true, "disconnect": bool, "grab": bool, "rope_snap": true}
func run_scenario(name: String) -> void:
	var r := GameConfig.robot()
	var cx: float = (r.x_min_mm + r.x_max_mm) * 0.5
	var cy: float = (r.y_min_mm + r.y_max_mm) * 0.5
	var ztop: float = r.z_max_mm if r.z_up_is_positive else r.z_min_mm
	var zbot: float = r.z_min_mm if r.z_up_is_positive else r.z_max_mm
	var steps: Array = []
	match name:
		"x_sweep":
			steps = [{"move": Vector3(r.x_min_mm + 20, NAN, NAN)}, {"wait": 2.5}, {"move": Vector3(r.x_max_mm - 20, NAN, NAN)}, {"wait": 2.5}, {"move": Vector3(cx, NAN, NAN)}, {"wait": 2.0}]
		"y_sweep":
			steps = [{"move": Vector3(NAN, r.y_min_mm + 10, NAN)}, {"wait": 2.0}, {"move": Vector3(NAN, r.y_max_mm - 10, NAN)}, {"wait": 2.0}, {"move": Vector3(NAN, cy, NAN)}, {"wait": 2.0}]
		"xy_diagonal":
			steps = [{"move": Vector3(r.x_min_mm + 30, r.y_min_mm + 10, NAN)}, {"wait": 2.5}, {"move": Vector3(r.x_max_mm - 30, r.y_max_mm - 10, NAN)}, {"wait": 2.5}, {"move": Vector3(cx, cy, NAN)}, {"wait": 2.0}]
		"sudden_stop":
			steps = [{"move": Vector3(r.x_max_mm - 20, NAN, NAN)}, {"wait": 0.5}, {"stop": true}, {"wait": 2.5}, {"move": Vector3(cx, NAN, NAN)}, {"wait": 0.45}, {"stop": true}, {"wait": 2.0}]
		"z_down_up":
			steps = [{"move": Vector3(NAN, NAN, zbot)}, {"wait": 2.5}, {"move": Vector3(NAN, NAN, ztop)}, {"wait": 2.5}]
		"xyz_together":
			steps = [{"move": Vector3(r.x_min_mm + 40, r.y_max_mm - 20, zbot)}, {"wait": 3.0}, {"move": Vector3(r.x_max_mm - 40, r.y_min_mm + 20, ztop)}, {"wait": 3.0}, {"move": Vector3(cx, cy, ztop)}, {"wait": 2.0}]
		"disconnect":
			steps = [{"disconnect": true}, {"wait": 3.0}]
		"reconnect":
			steps = [{"disconnect": true}, {"wait": 2.0}, {"disconnect": false}, {"wait": 1.0}]
		"limits":
			steps = [{"move": Vector3(r.x_min_mm, r.y_min_mm, ztop)}, {"wait": 3.0}, {"move": Vector3(r.x_max_mm, r.y_max_mm, zbot)}, {"wait": 3.5}, {"move": Vector3(cx, cy, ztop)}, {"wait": 2.5}]
		"rope_snap":
			steps = [{"snap_z": zbot}, {"wait": 2.0}, {"snap_z": ztop}, {"wait": 2.0}]
		"grab_cycle":
			steps = [{"move": Vector3(NAN, NAN, zbot)}, {"wait": 2.2}, {"grab": true}, {"wait": 1.2}, {"move": Vector3(NAN, NAN, ztop)}, {"wait": 2.5}, {"grab": false}, {"wait": 0.5}]
		_:
			push_warning("unknown scenario " + name)
			return
	_scenario = steps
	_scenario_name = name
	_scenario_index = 0
	_scenario_wait = 0.0
	scenario_started.emit(name)

func is_scenario_running() -> bool:
	return not _scenario.is_empty()

func _tick_scenario(dt: float) -> void:
	if _scenario.is_empty():
		return
	if _scenario_wait > 0.0:
		_scenario_wait -= dt
		return
	if _scenario_index >= _scenario.size():
		_scenario.clear()
		scenario_finished.emit(_scenario_name)
		return
	var s: Dictionary = _scenario[_scenario_index]
	_scenario_index += 1
	if s.has("move"):
		var m: Vector3 = s.move
		var t := target
		for a in range(3):
			if not is_nan(m[a]):
				t[a] = m[a]
		set_target(t)
	if s.has("snap_z"):
		# Teleport Z (simulates a status jump after reconnect / coarse polling)
		pos.z = s.snap_z
		target.z = s.snap_z
		vel.z = 0.0
		_report(true)
	if s.has("stop") and s.stop:
		emergency_stop()
	if s.has("disconnect"):
		set_connected(not s.disconnect)
	if s.has("grab"):
		grabbing = s.grab
	if s.has("wait"):
		_scenario_wait = s.wait

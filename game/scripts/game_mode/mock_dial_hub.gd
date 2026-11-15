class_name MockDialHub
extends GameModeDevices
## The two M5Dials and the Illumination simulated inside the game (#138): the game mode
## runs with no backend and no hardware, and the tests inject faults. It follows
## UFO-DeviceHub's pc/mock_hub.py (MockDial): STANDBY / GAME, READY -> ARMED ->
## BALL_DETECTED -> RELEASING -> RETURNING -> COMPLETE, the same refusals, RELEASE_STARTED
## at once and RELEASE_DONE after the servo's hold and settle times.
##
## Time only moves in tick(dt), so a test steps it exactly.

const SERVO_HOLD_S := 1.5
const SERVO_SETTLE_S := 0.6
## UFO-DeviceHub's default unit colours (config/hardware.h DIAL_UNIT_COLOR_1 / _2)
const UNIT_COLORS := {DIAL_1: [0, 255, 255], DIAL_2: [255, 0, 255]}
const LED_PRIORITY := {"BACKGROUND": 0, "NORMAL": 1, "HIGH": 2}
const LED_EFFECTS := ["NONE", "SOLID", "BREATHE", "CHASE", "COMET", "WIPE", "FLASH", "SPARKLE"]
const LED_DIRECTIONAL := ["CHASE", "COMET", "WIPE"]

## seconds before a command's answer comes back
var latency_s := 0.03
var session := 1
var connected := true
## device id -> {online, op_mode, state, cycle, phase_left, release_cmd, aborted, releases}
var dials: Dictionary = {}
## Every command the devices accepted, oldest first: [device, name, params]
var executed: Array = []
# ---- fault injection (tests, the debug keys) ----
## each device event is delivered twice (the same event_id): a re-sent event
var duplicate_events := false
## "device|name" -> result to answer once instead of executing ("BUSY", "TIMEOUT"...)
var refuse_next: Dictionary = {}
## the next release of these devices ends with RELEASE_FAILED
var fail_release: Dictionary = {}
## RELEASE_DONE of these devices is never sent (a lost event)
var lose_release_done: Dictionary = {}
## after a release these devices still see a capsule (it did not leave: the switch stays on)
var stuck_ball: Dictionary = {}
## firmware 0.2: the Dials do not know SET_DIAL_EFFECT / SET_DIAL_COLOR (UNSUPPORTED)
var old_firmware := false

var _seq := 0
var _event_seq := 0
var _answers: Array = []  # [seconds left, rid, ok, result, data]

func _init() -> void:
	for d in [DIAL_1, DIAL_2]:
		dials[d] = _fresh(d)

## led: the PC's effect now ({} = the Dial shows its own state): {effect, direction, color, priority, left}
func _fresh(device: int) -> Dictionary:
	return {"online": true, "op_mode": "STANDBY", "state": "DISABLED", "cycle": 0, "phase_left": 0.0,
		"release_cmd": 0, "aborted": false, "releases": 0, "led": {}, "color": UNIT_COLORS[device].duplicate()}

## The PC's effect on a Dial now ("NONE" = its own display).
func led_effect(device: int) -> String:
	return str(dials[device].led.get("effect", "NONE"))

func kind() -> String:
	return "mock"

func available() -> bool:
	return connected

func session_id() -> int:
	return session if connected else 0

func can_mock_ball() -> bool:
	return true

func command(device: int, name: String, params: Dictionary = {}) -> String:
	_seq += 1
	var cid := _seq  # executing may send more commands (an event handler's): keep this one's id
	var rid := "mock-%d" % cid
	var result := _execute(device, name, params, cid)
	_answers.append([latency_s, rid, result == "ACCEPTED", result, {"command_id": cid}])
	return rid

func status(device: int) -> String:
	_seq += 1
	var rid := "mock-%d" % _seq
	if not connected or not dials.has(device) or not dials[device].online:
		_answers.append([latency_s, rid, false, "OFFLINE", {}])
	else:
		var d: Dictionary = dials[device]
		_answers.append([latency_s, rid, true, "ACCEPTED", {"status": {"dial_state": d.state, "op_mode": d.op_mode,
			"cycle": d.cycle, "releases": d.releases, "switch_on": d.state == "BALL_DETECTED",
			"front_effect": led_effect(device), "unit_color": d.color}}])
	return rid

func stop_all() -> void:
	for d in dials.keys():
		command(d, "STOP_ALL")
	command(ILLUMINATION, "STOP_ALL")

func mock_ball(device: int) -> bool:
	if not connected or not dials.has(device):
		return false
	var d: Dictionary = dials[device]
	if d.state != "ARMED" or not d.online:
		return false
	d.state = "BALL_DETECTED"
	d.led = {}  # the Dial's own flash and chase come first: the PC's effect ends
	_emit(device, "BALL_RECEIVED", {"cycle": d.cycle})
	return true

## The switch bounces: the same capsule reported `times` more (new event ids, the same cycle).
func chatter(device: int, times: int) -> void:
	for i in times:
		_emit(device, "BALL_RECEIVED", {"cycle": dials[device].cycle})

## An event of an old session arrives late.
func stale_event(device: int, name: String, data: Dictionary) -> void:
	_event_seq += 1
	device_event.emit({"name": name, "source": device, "data": data, "event_id": _event_seq, "session_id": session - 1})

func set_online(device: int, on: bool) -> void:
	var d: Dictionary = dials[device]
	if d.online == on:
		return
	d.online = on
	if not on:
		if d.state == "ARMED":
			d.state = "READY"
		device_event.emit({"name": "DEVICE_OFFLINE", "source": device, "data": {}, "event_id": null, "session_id": null})
	else:
		device_event.emit({"name": "DEVICE_ONLINE", "source": device, "data": {}, "event_id": null, "session_id": null})

## The hub's USB link drops and comes back with a new session: every Dial is back in
## STANDBY (a capsule it held is no longer known to it).
func restart_session() -> void:
	connected = false
	_answers.clear()
	device_event.emit({"name": "GATEWAY_DISCONNECTED", "source": null, "data": {"reason": "mock"}, "event_id": null, "session_id": null})
	session += 1
	for d in dials.keys():
		var busy: bool = dials[d].state in ["RELEASING", "RETURNING"]
		dials[d].op_mode = "STANDBY"
		dials[d].led = {}
		dials[d].color = UNIT_COLORS[d].duplicate()
		if not busy:
			dials[d].state = "DISABLED"
	connected = true
	device_event.emit({"name": "GATEWAY_CONNECTED", "source": null, "data": {"session_id": session}, "event_id": null, "session_id": null})

func tick(dt: float) -> void:
	for id in dials.keys():
		var d: Dictionary = dials[id]
		if not d.led.is_empty() and float(d.led.left) > 0.0:  # a timed effect runs out
			d.led.left -= dt
			if d.led.left <= 0.0:
				d.led = {}
		if d.state != "RELEASING" and d.state != "RETURNING":
			continue
		d.phase_left -= dt
		if d.phase_left > 0.0:
			continue
		if d.state == "RELEASING":
			d.state = "RETURNING"
			d.phase_left = SERVO_SETTLE_S
		elif d.aborted or fail_release.has(id):
			fail_release.erase(id)
			d.led = {}
			d.state = "READY" if d.op_mode == "GAME" else "DISABLED"
			_emit(id, "RELEASE_FAILED", {"command_id": d.release_cmd, "reason": 1})
		else:
			d.led = {}  # the release sequence ended: the Dial ends the PC's effect by itself
			d.state = "BALL_DETECTED" if stuck_ball.has(id) else ("COMPLETE" if d.op_mode == "GAME" else "DISABLED")
			if lose_release_done.has(id):
				lose_release_done.erase(id)
			else:
				_emit(id, "RELEASE_DONE", {"command_id": d.release_cmd, "elapsed_ms": int((SERVO_HOLD_S + SERVO_SETTLE_S) * 1000.0)})
	var due: Array = []
	for a in _answers:
		a[0] -= dt
		if a[0] <= 0.0:
			due.append(a)
	for a in due:
		_answers.erase(a)
		command_done.emit(a[1], a[2], a[3], a[4])

func _emit(device: int, name: String, data: Dictionary) -> void:
	_event_seq += 1
	var ev := {"name": name, "source": device, "data": data, "event_id": _event_seq, "session_id": session}
	device_event.emit(ev)
	if duplicate_events:
		device_event.emit(ev.duplicate(true))

func _execute(device: int, name: String, params: Dictionary, cid: int) -> String:
	if not connected:
		return "NOT_CONNECTED"
	var key := "%d|%s" % [device, name]
	if refuse_next.has(key):
		var r := str(refuse_next[key])
		refuse_next.erase(key)
		return r
	if device == ILLUMINATION:  # lights only: accepted, nothing to simulate
		executed.append([device, name, params])
		return "ACCEPTED"
	if not dials.has(device):
		return "UNKNOWN_DEVICE"
	var d: Dictionary = dials[device]
	if not d.online:
		return "OFFLINE"
	var busy: bool = d.state in ["RELEASING", "RETURNING"]
	var result := "UNSUPPORTED"
	match name:
		"STOP_ALL":
			d.led = {}
			d.op_mode = "STANDBY"
			if busy:
				d.aborted = true
				d.state = "RETURNING"
				d.phase_left = SERVO_SETTLE_S
			else:
				d.state = "DISABLED"
			result = "ACCEPTED"
		"SET_DIAL_COLOR":
			if old_firmware:
				result = "UNSUPPORTED"
			else:
				var c = params.get("color", [0, 0, 0])
				d.color = c.duplicate() if c is Array and c.size() == 3 and c != [0, 0, 0] else UNIT_COLORS[device].duplicate()
				result = "ACCEPTED"
		"SET_DIAL_EFFECT":
			result = _dial_effect(d, params)
		"SET_MODE":
			if str(params.get("mode", "")) == "STANDBY":
				if busy:
					result = "BUSY"
				else:
					d.op_mode = "STANDBY"
					d.state = "DISABLED"
					result = "ACCEPTED"
			else:
				d.op_mode = "GAME"
				if d.state == "DISABLED":
					d.state = "READY"
				result = "ACCEPTED"
		"ARM_RECEIVER":
			if busy:
				result = "BUSY"
			elif d.op_mode != "GAME":
				result = "REJECTED_STATE"
			elif d.state == "ARMED":
				result = "ACCEPTED"
			elif not d.state in ["READY", "COMPLETE"]:
				result = "REJECTED_STATE"
			else:
				d.cycle += 1
				d.state = "ARMED"
				result = "ACCEPTED"
		"DISARM_RECEIVER":
			if busy:
				result = "BUSY"
			elif d.state == "BALL_DETECTED":
				result = "REJECTED_STATE"
			else:
				if d.state == "ARMED":
					d.state = "READY"
				result = "ACCEPTED"
		"RELEASE_BALL":
			if busy:
				result = "BUSY"
			elif d.op_mode != "GAME" or d.state != "BALL_DETECTED":
				result = "REJECTED_STATE"
			else:
				d.state = "RELEASING"
				d.phase_left = SERVO_HOLD_S
				d.release_cmd = cid
				d.aborted = false
				d.releases += 1
				_emit(device, "RELEASE_STARTED", {"command_id": cid})
				result = "ACCEPTED"
	if result == "ACCEPTED":
		executed.append([device, name, params])
	return result

## SET_DIAL_EFFECT as the Dial answers it (UFO-DeviceHub docs/game-mode-interface.md §2).
func _dial_effect(d: Dictionary, params: Dictionary) -> String:
	if old_firmware:
		return "UNSUPPORTED"
	var effect := str(params.get("effect", ""))
	var direction := str(params.get("direction", "NONE"))
	var priority := str(params.get("priority", "NORMAL"))
	if not effect in LED_EFFECTS or not LED_PRIORITY.has(priority) or not direction in ["NONE", "TO_SCREEN", "TO_DIAL"] \
			or (effect in LED_DIRECTIONAL and direction == "NONE"):
		return "INVALID_PARAMS"
	if not d.led.is_empty() and int(LED_PRIORITY[priority]) < int(LED_PRIORITY[d.led.priority]):
		return "IGNORED_PRIORITY"
	if effect == "NONE":
		d.led = {}
	else:
		d.led = {"effect": effect, "direction": direction, "color": params.get("color", d.color), "priority": priority,
			"left": float(params.get("duration_ms", 0)) / 1000.0}
	return "ACCEPTED"

## How many times `name` was accepted by `device` (tests).
func count(device: int, name: String) -> int:
	var n := 0
	for e in executed:
		if e[0] == device and e[1] == name:
			n += 1
	return n

class_name GameModeController
extends Node
## SUMMON THE UFO, the 150 s score game (#138; the rules are docs/game_mode_spec.md).
##
## The player grabs real capsules with the crane and drops them into the M5Dial on the
## left (Dial 1, 0x20) or the right (Dial 2, 0x21) of the screen. A capsule a Dial reports
## (BALL_RECEIVED) appears to come into the screen through that side's port, flies to
## UFOくん and is dropped from where the UFO was at that moment into the pinball field.
## When it leaves the field it goes back out through its own side's port, and the same
## Dial is told to let the real one go (RELEASE_BALL).
##
## This controller owns the experience: the clock, the two lanes (one per Dial, each with
## its own state machine), the score. It is separate from RobotState and from the crane:
## it never sends a robot command and never reads the arm's position; the player keeps
## the usual manual controls. The devices are reached only through GameModeDevices.
##
## What it never does:
##  - release twice: one RELEASE_BALL per capsule, never repeated by itself (a refusal, a
##    lost answer, a link that came back: the lane stops in FAULT for a person to look);
##  - trust an old event: events are matched by hub session, Dial and cycle;
##  - wait for the lights: the Illumination / LED commands are best effort;
##  - claim the capsule left: RELEASE_DONE means the servo sequence ended, nothing more.

signal phase_changed(phase: String)
signal lane_changed(side: String, state: String)
signal scored(points: int, kind: String, at: Vector2)

## IDLE (not started) -> COUNTDOWN -> PLAYING -> SETTLING (time is up: capsules in play
## finish and go out) -> RESULT; STOPPED = the stop key
const PHASES := ["IDLE", "COUNTDOWN", "PLAYING", "SETTLING", "RESULT", "STOPPED"]
## a lane: OFFLINE (the Dial does not answer) / ARMING (SET_MODE, ARM_RECEIVER on their
## way) / READY (armed, waiting for a capsule) / ABSORBING / DROPPING / SIMULATING /
## RETURNING / RELEASING / VERIFYING / CLOSING (time is up: disarming) / CLOSED / FAULT
const LANE_STATES := ["OFFLINE", "ARMING", "READY", "ABSORBING", "DROPPING", "SIMULATING", "RETURNING", "RELEASING",
	"VERIFYING", "CLOSING", "CLOSED", "FAULT"]
const BUSY_STATES := ["ABSORBING", "DROPPING", "SIMULATING", "RETURNING", "RELEASING", "VERIFYING"]
const LAYER := 2
## The Dial's transfer LEDs: UFO-DeviceHub's docs/game-mode-interface.md §5 (the same table as
## its pc/game_mode.py ANIMATIONS). No colour = the Dial's unit colour.
const LED_ANIMATIONS := {
	"INTAKE": {"effect": "CHASE", "direction": "TO_SCREEN", "duration_ms": 1500, "priority": "NORMAL", "target": "BOTH"},
	"RETURN_FLOW": {"effect": "COMET", "direction": "TO_DIAL", "duration_ms": 0, "priority": "NORMAL", "target": "BOTH"},
	"RELEASING": {"effect": "CHASE", "direction": "TO_DIAL", "duration_ms": 0, "priority": "NORMAL", "target": "BOTH"},
	"FAULT": {"effect": "FLASH", "direction": "NONE", "duration_ms": 1500, "priority": "HIGH", "target": "BOTH", "color": [255, 0, 0]},
	"CLEAR": {"effect": "NONE", "direction": "NONE", "duration_ms": 0, "priority": "HIGH", "target": "BOTH"},
}
## answers that mean "this firmware has no such command" (Dial 0.2: UNSUPPORTED, Hub 0.2: BAD_REQUEST)
const LED_UNKNOWN := ["UNSUPPORTED", "BAD_REQUEST"]
const SIDES := ["left", "right"]

class Lane:
	var side := ""
	var device := 0
	var color := Color.WHITE
	var state := "OFFLINE"
	var capsule: Dictionary = {}
	var t := 0.0
	var retry_left := 0.0
	var mode_ok := false
	var last_cycle := -1
	var cycle_session := 0
	var release_cid := 0
	var release_started := false
	var verify_tries := 0
	var fault := ""
	## why it is not ready yet (the Dial's refusal), for the HUD
	var note := ""
	var released := 0
	## false once the Dial said it does not know the LED commands (older firmware): no more are sent
	var led_ok := true
	## the wait for RELEASE_DONE ran out: the status decides (COMPLETE = the event was lost)
	var release_timed_out := false

const PIXEL_SIZE := Vector2i(640, 360)
## one dot of the pixel canvas on the 1280 x 720 screen
const DOT_PX := 2.0
const BOUNCE_PX := 8.0
const BOUNCE_MAX_PX := 16.0
## the new kinds of target borrow a sound
## a kind of target that has no sound of its own borrows one (every kind has its own since #143)
const SOUND_OF := {}

var main: Node
var devices: GameModeDevices
var mock_hub: MockDialHub
var backend_hub: BackendDialHub
var score := ScoreManager.new()
var capsules := CapsuleManager.new()
var ufo := UfoDropController.new()
var trace := GameModeTrace.new()
var field: PinballField
var backdrop: GameModeBackdrop
## the low-resolution canvas (640 x 360, one dot = two screen pixels like the UFO's sprite at
## 2x): the background, the field's picture and the effects are drawn in it, `screen` shows it
var pixel_view: SubViewport
var screen: TextureRect
var field_art: PinballFieldArt
## the arm camera as a round aiming scope in the right column (hidden without a camera)
var scope: ArmScope
var scope_enabled := true
var fx: GameModeVFX
var sounds: GameModeSounds
var hud: GameModeHud
var layer: CanvasLayer
var lanes: Dictionary = {}  # side -> Lane

var phase := "IDLE"
var time_left := 0.0
var countdown_left := 0.0
var settle_left := 0.0
var message := ""
var session := 0
## seconds since start() (the score's clock)
var clock := 0.0

# ---- tuning (config game_mode; docs/game_mode_spec.md §5) ----
var duration_s := 150.0
var countdown_s := 3.0
var hurry_s := 30.0
var warning_s := 10.0
var settle_max_s := 30.0
var absorb_s := 0.85
var drop_s := 0.25
var return_s := 0.9
var release_sync_s := 0.6
var release_timeout_s := 8.0
var command_timeout_s := 5.0
var arm_retry_s := 3.0
var verify_retry_s := 0.5
var verify_tries := 4
var closing_wait_s := 1.5
var lights := true
## the Dials' own transfer LEDs (SET_DIAL_EFFECT / SET_DIAL_COLOR, firmware 0.3)
var dial_leds := true
## "high" / "low": how much the background does (config game_mode.visual_quality)
var visual_quality := "high"
## false: no bounce, no trails, no breathing (config game_mode.effects; the game is the same)
var effects := true
var trace_to_file := true
var devices_wanted := "auto"
## --game-mode-demo: with mock Dials, capsules come by themselves (a rehearsal with no hands)
var demo := false
var demo_gap_s := 2.5
var _demo_left := 1.0
var _demo_side := 0

var _active := false
var _cmds: Dictionary = {}  # rid -> {lane: Lane or null, what, left}
var _seen: Dictionary = {}  # "session|source|event_id" -> true
var _hurry_done := false
var _warned_at := 99
var _counted := 99
var _combo_seen := 0
var _bounce := 0.0
var _bounce_t := 0.0

func setup(m: Node) -> void:
	main = m
	var cfg: Dictionary = GameConfig.data.get("game_mode", {}) if GameConfig.data.get("game_mode") is Dictionary else {}
	_configure(cfg)
	layer = CanvasLayer.new()
	layer.name = "GameModeLayer"
	layer.layer = LAYER
	layer.visible = false
	add_child(layer)
	pixel_view = SubViewport.new()
	pixel_view.name = "PixelView"
	pixel_view.size = PIXEL_SIZE
	pixel_view.disable_3d = true
	pixel_view.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	pixel_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(pixel_view)
	# everything inside keeps the 1280 x 720 design coordinates, drawn at half size
	pixel_view.canvas_transform = Transform2D(0.0, Vector2.ONE / DOT_PX, 0.0, Vector2.ZERO)
	screen = TextureRect.new()
	screen.name = "Screen"
	screen.texture = pixel_view.get_texture()
	screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen.stretch_mode = TextureRect.STRETCH_SCALE
	screen.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	screen.size = Vector2(PIXEL_SIZE) * DOT_PX
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(screen)
	backdrop = GameModeBackdrop.new()
	backdrop.name = "Backdrop"
	backdrop.quality = visual_quality
	pixel_view.add_child(backdrop)
	# the field is the physics (in the game's own world); its picture is in the pixel canvas
	field = PinballField.new()
	field.name = "PinballField"
	field.configure(cfg.get("field", {}) if cfg.get("field") is Dictionary else {})
	layer.add_child(field)
	field.target_hit.connect(_on_target_hit)
	field.capsule_exited.connect(_on_capsule_exited)
	field.process_mode = Node.PROCESS_MODE_DISABLED
	field_art = PinballFieldArt.new()
	field_art.name = "PinballFieldArt"
	field_art.field = field
	field_art.points = score.table
	field_art.effects = effects
	pixel_view.add_child(field_art)
	fx = GameModeVFX.new()
	fx.name = "GameModeVFX"
	pixel_view.add_child(fx)
	sounds = GameModeSounds.new()
	sounds.name = "GameModeSounds"
	add_child(sounds)
	lane_changed.connect(sounds.on_lane)  # a Dial's sounds come from its side
	hud = GameModeHud.new()
	hud.name = "GameModeHud"
	layer.add_child(hud)
	hud.setup(self)
	scope = ArmScope.new()
	scope.name = "ArmScope"
	layer.add_child(scope)
	scope.setup(main.cameras if main != null and main.get("cameras") != null else null)
	var sc: Dictionary = cfg.get("scope", {}) if cfg.get("scope") is Dictionary else {}
	scope_enabled = bool(sc.get("enabled", true))
	scope.zoom = clampf(float(sc.get("zoom", 1.0)), 1.0, 4.0)
	mock_hub = MockDialHub.new()
	mock_hub.name = "MockDialHub"
	add_child(mock_hub)
	backend_hub = BackendDialHub.new()
	backend_hub.name = "BackendDialHub"
	add_child(backend_hub)
	if main != null and main.get("ws") != null:
		backend_hub.setup(main.ws)
	for hub in [mock_hub, backend_hub]:
		hub.device_event.connect(_on_device_event.bind(hub))
		hub.command_done.connect(_on_command_done.bind(hub))
	devices = mock_hub
	ufo.configure(PinballField.LEFT, PinballField.RIGHT, cfg.get("ufo", {}) if cfg.get("ufo") is Dictionary else {})
	var dials: Dictionary = cfg.get("dials", {}) if cfg.get("dials") is Dictionary else {}
	for side in SIDES:
		var l := Lane.new()
		l.side = side
		var d: Dictionary = dials.get(side, {}) if dials.get(side) is Dictionary else {}
		l.device = int(d.get("device", GameModeDevices.DIAL_1 if side == "left" else GameModeDevices.DIAL_2))
		var c = d.get("color")
		l.color = Color8(int(c[0]), int(c[1]), int(c[2])) if c is Array and c.size() == 3 else fx.colors[side]
		fx.colors[side] = l.color
		backdrop.side_colors[side] = l.color
		backdrop.ports[side] = fx.port(side)
		field.wall_colors[0 if side == "left" else 1] = l.color
		lanes[side] = l

func _configure(cfg: Dictionary) -> void:
	duration_s = float(cfg.get("duration_s", duration_s))
	countdown_s = float(cfg.get("countdown_s", countdown_s))
	hurry_s = float(cfg.get("hurry_s", hurry_s))
	warning_s = float(cfg.get("warning_s", warning_s))
	settle_max_s = float(cfg.get("settle_max_s", settle_max_s))
	lights = bool(cfg.get("lights", lights))
	dial_leds = bool(cfg.get("dial_leds", dial_leds))
	visual_quality = str(cfg.get("visual_quality", visual_quality))
	effects = bool(cfg.get("effects", effects))
	trace_to_file = bool(cfg.get("trace", trace_to_file))
	devices_wanted = str(cfg.get("devices", devices_wanted))
	var t: Dictionary = cfg.get("timing", {}) if cfg.get("timing") is Dictionary else {}
	absorb_s = float(t.get("absorb_s", absorb_s))
	drop_s = float(t.get("drop_s", drop_s))
	return_s = float(t.get("return_s", return_s))
	release_sync_s = float(t.get("release_sync_s", release_sync_s))
	release_timeout_s = float(t.get("release_timeout_s", release_timeout_s))
	command_timeout_s = float(t.get("command_timeout_s", command_timeout_s))
	arm_retry_s = float(t.get("arm_retry_s", arm_retry_s))
	verify_retry_s = float(t.get("verify_retry_s", verify_retry_s))
	verify_tries = int(t.get("verify_tries", verify_tries))
	if cfg.get("score") is Dictionary:
		score.configure(cfg.score)

# ------------------------------------------------------------------ on / off
func active() -> bool:
	return _active

func running() -> bool:
	return phase in ["COUNTDOWN", "PLAYING", "SETTLING"]

## "mock" (inside the game) / "backend" / "auto" (the backend when the game uses it).
func use_devices(which: String) -> void:
	if running():
		return
	var want := which
	if want == "auto":
		want = "backend" if main != null and main.get("ws") != null and main.ws.enabled else "mock"
	devices = backend_hub if want == "backend" else mock_hub

## The game mode's screen comes up (the title picked it); Enter starts a round.
func open() -> void:
	if _active:
		return
	_active = true
	use_devices(devices_wanted)
	layer.visible = true
	pixel_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	field.process_mode = Node.PROCESS_MODE_INHERIT
	_reset_round()
	_set_phase("IDLE")
	message = "Enter でスタート"

## Leaves the game mode (Esc to the title). A running round is stopped like the stop key
## (STOP_ALL to the devices); nothing is released afterwards.
func close() -> void:
	if not _active:
		return
	if running():
		_halt("タイトルに戻った")
	_active = false
	sounds.set_bgm(false)
	field.clear()
	fx.reset()
	trace.close()
	layer.visible = false
	layer.offset = Vector2.ZERO
	screen.position = Vector2.ZERO
	scope.step(0.0, false)
	pixel_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	field.process_mode = Node.PROCESS_MODE_DISABLED
	phase = "IDLE"

func start() -> void:
	if not _active or running():
		return
	_reset_round()
	if trace_to_file:
		trace.open("user://game_mode/trace_%s.jsonl" % Time.get_datetime_string_from_system().replace(":", "").replace("-", ""))
	session = devices.session_id()
	countdown_left = countdown_s
	time_left = duration_s
	_set_phase("COUNTDOWN")
	message = ""
	for side in SIDES:
		_prepare(lanes[side])
	_light("SET_LIGHT_MODE", {"mode": "GAME_READY", "brightness": 160, "speed": 128, "transition_ms": 300})
	_trace("game_start", null, {})

func _reset_round() -> void:
	score.reset()
	capsules.reset()
	ufo.reset()
	field.clear()
	field.set_frozen(false)
	fx.reset()
	sounds.set_bgm(false)
	_cmds.clear()
	_seen.clear()
	_hurry_done = false
	_warned_at = 99
	_counted = 99
	clock = 0.0
	time_left = duration_s
	countdown_left = 0.0
	settle_left = 0.0
	for side in SIDES:
		var l: Lane = lanes[side]
		l.state = "OFFLINE"
		l.capsule = {}
		l.t = 0.0
		l.retry_left = 0.0
		l.mode_ok = false
		l.last_cycle = -1
		l.cycle_session = 0
		l.release_cid = 0
		l.release_started = false
		l.fault = ""
		l.note = ""
		l.released = 0
		l.led_ok = true
		l.release_timed_out = false

# ------------------------------------------------------------------ the tick
func _physics_process(dt: float) -> void:
	if _active:
		tick(dt)

func _process(dt: float) -> void:
	if not _active:
		return
	if main != null and main.get("shake") != null:
		layer.offset = main.shake.offset  # the picture shakes; the physics does not
	scope.demo = demo  # the rehearsal has its own made-up picture: no camera needed
	scope.step(dt, scope_enabled and phase != "IDLE")
	backdrop.planet_visible = not scope.visible
	if main != null and main.get("gesture_hud") != null:
		backdrop.moon_visible = not (main.gesture_hud as Control).visible
	# the bounce: the picture drops a few dots and springs back (whole dots, so it stays crisp)
	_bounce_t += dt
	screen.position = Vector2(0, snappedf(bounce_offset(), DOT_PX))

## The picture bounces (a score). Only the picture: the physics, the clock and the devices
## never wait for it. Stronger calls add up to a limit.
func bounce(strength: float) -> void:
	if not effects or strength <= 0.0:
		return
	_bounce = minf(absf(bounce_offset()) + strength * BOUNCE_PX, BOUNCE_MAX_PX)
	_bounce_t = 0.0

## How far down the picture is now (px): a decaying spring.
func bounce_offset() -> float:
	var y := _bounce * exp(-9.0 * _bounce_t) * cos(_bounce_t * 26.0)
	return y if absf(_bounce) * exp(-9.0 * _bounce_t) >= 1.0 else 0.0

## 0..3: which step of the combo table the chain has reached now.
func combo_level() -> int:
	var m := score.multiplier(clock)
	var lvl := 0
	for i in score.combo_steps.size():
		if m >= float(score.combo_steps[i][1]):
			lvl = i + 1
	return mini(lvl, 3)

## The picture follows the round: the sky by the time left, the stars and lamps by the combo.
func _present_state() -> void:
	var playing := phase == "PLAYING"
	var lvl := combo_level() if playing else 0
	field_art.combo_level = lvl
	field_art.effects = effects
	fx.effects = effects
	backdrop.energy = lvl / 3.0
	backdrop.urgency = (2 if time_left <= warning_s else (1 if time_left <= hurry_s else 0)) if playing else 0
	backdrop.time_k = time_left / maxf(duration_s, 1.0) if playing else 1.0
	if lvl > _combo_seen:  # the combo climbed a step
		backdrop.pulse(backdrop.light_color(), 0.3 + 0.2 * lvl)
		fx.banner("COMBO x%s" % str(score.multiplier(clock)), lvl)
		sounds.combo_step = lvl
		sounds.play("combo")
	_combo_seen = lvl

## One step of the game mode's time (60 Hz from the physics tick; the tests call it).
func tick(dt: float) -> void:
	devices.tick(dt)
	_expire_commands(dt)
	fx.advance(dt)
	backdrop.advance(dt)
	if phase != "STOPPED":
		ufo.advance(dt)
	fx.ufo_pos = ufo.position()
	fx.ufo_visible = phase != "IDLE"  # on the title screen the UFO is the big one in the middle
	match phase:
		"COUNTDOWN":
			clock += dt
			countdown_left -= dt
			var n := int(ceil(countdown_left))
			if n < _counted and n > 0:
				_counted = n
				sounds.play("count")
			if countdown_left <= 0.0:
				_go()
		"PLAYING":
			clock += dt
			time_left = maxf(time_left - dt, 0.0)
			_clock_cues()
			_demo_tick(dt)
			if time_left <= 0.0:
				_time_up()
		"SETTLING":
			clock += dt
			settle_left -= dt
			if _all_settled():
				_result()
			elif settle_left <= 0.0:
				for side in SIDES:
					var l: Lane = lanes[side]
					if not l.state in ["CLOSED", "FAULT"]:
						_fault(l, "清算が時間内に終わらなかった")
				_result()
	if running():
		for side in SIDES:
			_tick_lane(lanes[side], dt)
	field.switch_lit = score.switch_lit
	field.jackpot_on = score.jackpot_armed(clock)
	_present_state()

func _go() -> void:
	_set_phase("PLAYING")
	sounds.play("go")
	sounds.set_bgm(true)
	_light("SET_LIGHT_MODE", {"mode": "GAME_PLAY", "brightness": 180, "speed": 128, "transition_ms": 300})
	_light("TRIGGER_EFFECT", {"effect": "GAME_START", "duration_ms": 1000, "intensity": 200})
	for side in SIDES:
		var l: Lane = lanes[side]
		if l.state == "ARMING" and l.mode_ok and not _waiting(l, "arm"):
			_arm(l)

func _demo_tick(dt: float) -> void:
	if not demo or not devices.can_mock_ball():
		return
	_demo_left -= dt
	if _demo_left <= 0.0:
		_demo_left = demo_gap_s
		_demo_side = 1 - _demo_side
		devices.mock_ball(lanes[SIDES[_demo_side]].device)

func _clock_cues() -> void:
	if not _hurry_done and time_left <= hurry_s:
		_hurry_done = true
		sounds.play("hurry")
		sounds.set_bgm(true, true)
		backdrop.pulse(Color("ff4fd8"), 0.8)
		_light("SET_LIGHT_MODE", {"mode": "GAME_PLAY", "brightness": 220, "speed": 230, "transition_ms": 200})
		_trace("hurry", null, {})
	var s := int(ceil(time_left))
	if time_left <= warning_s and s < _warned_at and s > 0:
		_warned_at = s
		sounds.play("warning")

## 0 s: nothing new is taken. Capsules in play finish (their score counts) and go out.
func _time_up() -> void:
	_set_phase("SETTLING")
	settle_left = settle_max_s
	sounds.set_bgm(false)
	sounds.play("timeup")
	_trace("time_up", null, {})
	for side in SIDES:
		var l: Lane = lanes[side]
		match l.state:
			"READY", "ARMING", "OFFLINE":
				# ARMING / OFFLINE too (review on #139): an ARM_RECEIVER still on its way, or one
				# whose answer was lost, may have armed the Dial
				if devices.available():
					_send(l, "disarm", "DISARM_RECEIVER")
					l.t = closing_wait_s
					_set_lane(l, "CLOSING")
				else:
					_set_lane(l, "CLOSED")

func _all_settled() -> bool:
	for side in SIDES:
		if not lanes[side].state in ["CLOSED", "FAULT"]:
			return false
	return true

func _result() -> void:
	_set_phase("RESULT")
	field.clear()
	sounds.set_bgm(false)
	sounds.play("result")
	for side in SIDES:
		var l: Lane = lanes[side]
		if l.state == "CLOSED":  # a faulted Dial is left as it is for a person to look at
			_led(l, "CLEAR")
			_send(l, "standby", "SET_MODE", {"mode": "STANDBY"})
	_light("SET_LIGHT_MODE", {"mode": "RESULT", "brightness": 180, "speed": 128, "transition_ms": 500})
	_light("TRIGGER_EFFECT", {"effect": "GAME_CLEAR", "duration_ms": 2000, "intensity": 220})
	message = "Enter: もう一回    Esc: タイトル"
	_trace("result", null, {"score_delta": score.score})
	trace.close()

# ------------------------------------------------------------------ lanes
func _prepare(l: Lane) -> void:
	l.mode_ok = false
	if not devices.available():
		l.retry_left = arm_retry_s
		_set_lane(l, "OFFLINE")
		return
	_set_lane(l, "ARMING")
	_send(l, "mode", "SET_MODE", {"mode": "GAME"})

func _arm(l: Lane) -> void:
	_set_lane(l, "ARMING")
	_send(l, "arm", "ARM_RECEIVER")

func _tick_lane(l: Lane, dt: float) -> void:
	match l.state:
		"OFFLINE":
			if phase in ["COUNTDOWN", "PLAYING"]:
				l.retry_left -= dt
				if l.retry_left <= 0.0:
					_prepare(l)
		"ABSORBING":
			l.t -= dt
			if l.t <= 0.0:
				l.t = drop_s
				_set_lane(l, "DROPPING")
				fx.play("capsule_materialize", l.side, Vector2(l.capsule.drop_x, PinballField.SPAWN_Y), drop_s)
				sounds.play("drop")
		"DROPPING":
			l.t -= dt
			if l.t <= 0.0:
				field.spawn_capsule(l.capsule.capsule_id, l.capsule.drop_x, l.color)
				fx.play("capsule_portal_close", l.side)
				_set_lane(l, "SIMULATING")
		"RETURNING":
			l.t -= dt
			if l.t <= 0.0:
				_release(l)
		"RELEASING":
			l.t -= dt
			if l.t <= 0.0:
				# no RELEASE_DONE in time: never wait for ever, never release again. The Dial's
				# status decides (the contract's §7): done and empty = the event was lost.
				l.release_timed_out = true
				_trace("release", l, {"release_status": "timeout"})
				_verify(l)
		"VERIFYING":
			if l.t > 0.0:
				l.t -= dt
				if l.t <= 0.0:
					_send(l, "status", "")
		"CLOSING":
			l.t -= dt
			if l.t <= 0.0:
				_set_lane(l, "CLOSED")

## A capsule is taken in: the drop point is where the UFO is now, and it never changes.
func _take(l: Lane, cycle: int, late: bool) -> void:
	var c = capsules.create(l.device, session, cycle, ufo.x(), late)
	if c == null:
		_trace("ball_ignored", l, {"cycle": cycle, "result": "capsule_limit"})
		return
	l.capsule = c
	l.last_cycle = cycle
	l.cycle_session = session
	l.release_cid = 0
	l.release_started = false
	_trace("capsule_created", l, {"physics_position": [c.drop_x, PinballField.SPAWN_Y]})
	if late:
		# time was already up when it landed: no play, no score, straight back out
		l.t = release_sync_s
		_set_lane(l, "RETURNING")
		_led(l, "RETURN_FLOW")
		fx.play("capsule_return", l.side, fx.port(l.side), return_s)
		return
	l.t = absorb_s
	_set_lane(l, "ABSORBING")
	backdrop.side_pulse(l.side)
	fx.play("capsule_portal_open", l.side, Vector2.ZERO, absorb_s)
	fx.play("capsule_absorb", l.side, Vector2.ZERO, absorb_s)
	fx.play("capsule_transfer_trail", l.side, Vector2(c.drop_x, PinballField.SPAWN_Y), absorb_s)
	sounds.play("absorb")
	_led(l, "INTAKE")
	_light("TRIGGER_EFFECT", {"effect": "BALL_RECEIVED", "duration_ms": 800, "intensity": 200})

func _on_target_hit(capsule_id: String, kind: String, target: String, pos: Vector2) -> void:
	var c = capsules.get_capsule(capsule_id)
	if c == null or not running():
		return
	var r := score.hit(capsule_id, kind, target, clock)
	if int(r.points) <= 0:
		return
	c.score += int(r.points)
	var l: Lane = _lane_of(c.source_dial)
	_present_score(r, pos, l)
	_trace("score", l, {"score_delta": r.points, "effect_id": kind, "physics_position": [pos.x, pos.y]})

func _on_capsule_exited(capsule_id: String, goal: String, pos: Vector2) -> void:
	var c = capsules.get_capsule(capsule_id)
	if c == null:
		return
	var l: Lane = _lane_of(c.source_dial)
	if l == null or l.state != "SIMULATING":
		return
	c.goal = goal
	if goal != "timeout":
		var r := score.goal(capsule_id, goal, clock)
		if int(r.points) > 0:
			c.score += int(r.points)
			_present_score(r, pos, l)
			_trace("score", l, {"score_delta": r.points, "effect_id": r.kind, "physics_position": [pos.x, pos.y]})
	else:
		_trace("stay_timeout", l, {"physics_position": [pos.x, pos.y]})
	field.remove_capsule(capsule_id)
	score.forget(capsule_id)
	l.t = release_sync_s
	_set_lane(l, "RETURNING")
	fx.play("capsule_return", l.side, pos, return_s)
	backdrop.side_pulse(l.side)
	sounds.play("return")
	_led(l, "RETURN_FLOW")

func _present_score(r: Dictionary, pos: Vector2, l: Lane) -> void:
	var kind := str(r.kind)
	var big: bool = kind in ["jackpot", "goal_center", "star", "alien"] or str(r.bonus) != ""
	var text := "+%d" % int(r.points)
	if float(r.mult) > 1.0:
		text += " x%s" % str(r.mult)
	var lvl := combo_level()
	fx.popup(text, pos, Color("ffe03c") if big else (l.color.lerp(Color.WHITE, 0.6) if l != null else Color.WHITE), big, lvl)
	var jolt := 0.0  # how hard the picture bounces: nothing for a pin, most for a jackpot
	if kind == "jackpot" or str(r.bonus) != "":
		jolt = 1.2
	elif big:
		jolt = 0.8
	elif kind.begins_with("goal"):
		jolt = 0.5
	elif kind != "pin":
		jolt = 0.3
	bounce(jolt * (1.0 + 0.25 * lvl))
	var snd: String = "goal" if kind.begins_with("goal") else SOUND_OF.get(kind, kind)
	if str(r.bonus) == "switch_bonus":
		snd = "bonus"
	sounds.play(snd)
	fx.hit(str(r.bonus) if str(r.bonus) != "" else kind, pos, l.color if l != null else Color.WHITE)
	if main != null and main.get("shake") != null:
		var k := 0.0
		if kind == "bumper":
			k = 0.12
		elif big:
			k = 0.5 if kind == "jackpot" or str(r.bonus) != "" else 0.25
		if k > 0.0:
			main.shake.add_trauma(k)
	if kind == "jackpot" or str(r.bonus) != "":
		backdrop.pulse(Color("ffe03c"), 1.0)
		_light("TRIGGER_EFFECT", {"effect": "SCORE", "duration_ms": 1200, "intensity": 255})
	scored.emit(int(r.points), kind, pos)

## The one RELEASE_BALL of this capsule. Not sent when the hub's session changed since the
## Dial reported it (the Dial no longer knows it holds one): a person has to look.
func _release(l: Lane) -> void:
	if l.capsule.is_empty():
		_set_lane(l, "CLOSED" if phase != "PLAYING" else "OFFLINE")
		return
	if bool(l.capsule.orphaned) or (session != 0 and int(l.capsule.session) != session):
		_fault(l, "通信がつながり直したので、自動では排出しない")
		return
	l.t = release_timeout_s
	l.release_started = false
	l.release_timed_out = false
	_set_lane(l, "RELEASING")
	_send(l, "release", "RELEASE_BALL")

## The release sequence ended: is the Dial ready for the next one?
func _verify(l: Lane) -> void:
	l.verify_tries = verify_tries
	l.t = 0.0
	_set_lane(l, "VERIFYING")
	_send(l, "status", "")

func _released(l: Lane) -> void:
	capsules.finish(l.capsule.capsule_id, "done")
	l.capsule = {}
	l.released += 1
	fx.play("capsule_portal_close", l.side)
	if phase == "PLAYING":
		_arm(l)
	else:
		_set_lane(l, "CLOSED")

func _fault(l: Lane, why: String) -> void:
	l.fault = why
	if not l.capsule.is_empty():
		capsules.finish(l.capsule.capsule_id, "failed")
		field.remove_capsule(l.capsule.capsule_id)
	_set_lane(l, "FAULT")
	_led(l, "FAULT")
	fx.play("capsule_fault", l.side)
	sounds.play("fault")
	_trace("fault", l, {"result": why, "release_status": "failed"})

func _lane_of(device) -> Lane:
	for side in SIDES:
		if device != null and lanes[side].device == int(device):
			return lanes[side]
	return null

func _set_lane(l: Lane, state: String) -> void:
	if l.state == state:
		return
	l.state = state
	_trace("lane_state", l, {})
	lane_changed.emit(l.side, state)

func _set_phase(p: String) -> void:
	phase = p
	phase_changed.emit(p)

# ------------------------------------------------------------------ commands
func _send(l: Lane, what: String, name: String, params: Dictionary = {}) -> void:
	var rid := devices.status(l.device) if what == "status" else devices.command(l.device, name, params)
	_cmds[rid] = {"lane": l, "what": what, "left": command_timeout_s}
	_trace("command", l, {"effect_id": name if what != "status" else "GET_STATUS", "result": "sent"})

func _waiting(l: Lane, what: String) -> bool:
	for c in _cmds.values():
		if c.lane == l and c.what == what:
			return true
	return false

func _expire_commands(dt: float) -> void:
	for rid in _cmds.keys():
		if not _cmds.has(rid):
			continue
		_cmds[rid].left -= dt
		if _cmds[rid].left <= 0.0:
			_answer(rid, false, "TIMEOUT", {})

func _on_command_done(rid: String, ok: bool, result: String, data: Dictionary, hub: GameModeDevices) -> void:
	if hub == devices:
		_answer(rid, ok, result, data)

func _answer(rid: String, ok: bool, result: String, data: Dictionary) -> void:
	if not _cmds.has(rid):
		return
	var c: Dictionary = _cmds[rid]
	_cmds.erase(rid)
	var l: Lane = c.lane
	_trace("ack", l, {"effect_id": c.what, "result": result, "command_id": data.get("command_id")})
	if l == null or not running():
		return  # a light, or an answer that came after the round ended
	match c.what:
		"mode":
			if l.state != "ARMING":
				return
			if ok:
				l.mode_ok = true
				_dial_color(l)
				if phase == "PLAYING":
					_arm(l)
			else:
				l.note = "Dial が応えない（%s）" % result
				l.retry_left = arm_retry_s
				_set_lane(l, "OFFLINE")
		"arm":
			if l.state != "ARMING":
				return
			if ok:
				l.note = ""
				_set_lane(l, "READY")
				if phase != "PLAYING":  # time ran out while it was arming
					_send(l, "disarm", "DISARM_RECEIVER")
					l.t = closing_wait_s
					_set_lane(l, "CLOSING")
			elif l.released > 0 and result == "REJECTED_STATE":
				_fault(l, "次の受け取りに戻れない（カプセルが残っている？）")
			else:
				# REJECTED_STATE before any release of this round: a capsule was left in the Dial, or the
				# Dial is in its own settings mode (DialState SETTINGS refuses everything but STOP_ALL)
				l.note = "Dial にカプセルが残っている？（か、Dial が設定モード）" if result == "REJECTED_STATE" else "Dial が応えない（%s）" % result
				l.retry_left = arm_retry_s
				_set_lane(l, "OFFLINE")
		"release":
			if ok:
				l.release_cid = int(data.get("command_id", 0))
			elif l.state == "RELEASING":
				_fault(l, "排出の命令が通らなかった（%s）" % result)
		"status":
			if l.state != "VERIFYING":
				return
			var st: Dictionary = data.get("status", {}) if data.get("status") is Dictionary else {}
			var ds := str(st.get("dial_state", st.get("state", "")))
			if ok and ds in ["COMPLETE", "READY"] and not bool(st.get("switch_on", false)):
				_released(l)
			else:
				l.verify_tries -= 1
				if l.verify_tries <= 0:
					_fault(l, ("RELEASE_DONE が来ない（排出できたか分からない。Dial: %s）" if l.release_timed_out
						else "排出のあと、Dial が次の準備にならない（%s）") % (ds if ok else result))
				else:
					l.t = verify_retry_s
		"led":
			if result in LED_UNKNOWN and l.led_ok:
				l.led_ok = false  # older firmware: the Dial shows its own LEDs, the game goes on
				_trace("led", l, {"led_command": "off for this round", "result": result})
		"disarm":
			if l.state == "CLOSING" and ok:
				_set_lane(l, "CLOSED")
			# refused = a capsule landed just before: its BALL_RECEIVED follows (CLOSING waits)

# ------------------------------------------------------------------ events
func _on_device_event(ev: Dictionary, hub: GameModeDevices) -> void:
	if hub != devices or not _active:
		return
	var name := str(ev.get("name", ""))
	var l: Lane = _lane_of(ev.get("source"))
	var ev_session = ev.get("session_id")
	match name:
		"GATEWAY_CONNECTED":
			session = int((ev.get("data", {}) as Dictionary).get("session_id", devices.session_id()))
			_trace("session", null, {"result": "connected"})
			for side in SIDES:
				if lanes[side].state == "OFFLINE":
					lanes[side].retry_left = 0.0
			return
		"GATEWAY_DISCONNECTED", "SESSION_CLOSED":
			_trace("session", null, {"result": name})
			for side in SIDES:
				_link_lost(lanes[side], name)
			return
		"DEVICE_REBOOTED":
			if l != null:
				_link_lost(l, name)
			return
		"DEVICE_OFFLINE":
			if l != null and l.state in ["READY", "ARMING"] and running():
				l.retry_left = arm_retry_s
				_set_lane(l, "OFFLINE")
			return
		"DEVICE_ONLINE":
			if l != null and l.state == "OFFLINE":
				l.retry_left = 0.0
			return
	if l == null or not name in ["BALL_RECEIVED", "RELEASE_STARTED", "RELEASE_DONE", "RELEASE_FAILED"]:
		return
	var data: Dictionary = ev.get("data", {}) if ev.get("data") is Dictionary else {}
	# an event of another session is history
	if ev_session != null and session != 0 and int(ev_session) != session:
		_trace("event_ignored", l, {"effect_id": name, "result": "stale_session", "cycle": data.get("cycle")})
		return
	if ev.get("event_id") != null:
		var key := "%s|%s|%s" % [ev_session, ev.get("source"), ev.get("event_id")]
		if _seen.has(key):
			_trace("event_ignored", l, {"effect_id": name, "result": "duplicate", "cycle": data.get("cycle")})
			return
		_seen[key] = true
	if session == 0 and ev_session != null:
		session = int(ev_session)
	_trace("event", l, {"effect_id": name, "cycle": data.get("cycle"), "command_id": data.get("command_id")})
	match name:
		"BALL_RECEIVED":
			_on_ball(l, int(data.get("cycle", 0)))
		"RELEASE_STARTED":
			if l.state == "RELEASING" and not l.release_started and _same_release(l, data):
				l.release_started = true
				_led(l, "RELEASING")
				fx.play("capsule_release_burst", l.side)
				sounds.play("release", l.side)
				_light("TRIGGER_EFFECT", {"effect": "BALL_RELEASED", "duration_ms": 800, "intensity": 200})
		"RELEASE_DONE":
			if l.state == "RELEASING" and _same_release(l, data):
				_trace("release", l, {"release_status": "done"})
				_verify(l)
		"RELEASE_FAILED":
			if l.state == "RELEASING" and _same_release(l, data):
				_fault(l, "排出に失敗した（RELEASE_FAILED）")

func _same_release(l: Lane, data: Dictionary) -> bool:
	return l.release_cid == 0 or not data.has("command_id") or int(data.command_id) == l.release_cid

func _on_ball(l: Lane, cycle: int) -> void:
	if l.cycle_session == session and cycle <= l.last_cycle:
		_trace("ball_ignored", l, {"cycle": cycle, "result": "old_cycle"})  # a bounce of the switch, a re-sent event
		return
	# ARMING / OFFLINE as well as READY (review on #139): a new cycle's BALL_RECEIVED in this
	# session says the Dial was armed and holds a capsule, even if the ARM_RECEIVER's answer
	# is still on its way or was lost. Ignoring it would leave the capsule in the Dial.
	if phase == "PLAYING" and l.state in ["READY", "ARMING", "OFFLINE"]:
		_take(l, cycle, false)
	elif phase == "SETTLING" and l.state in ["READY", "CLOSING", "CLOSED"]:
		_take(l, cycle, true)  # it landed as the time ran out
	else:
		_trace("ball_ignored", l, {"cycle": cycle, "result": "not_accepting:%s/%s" % [phase, l.state]})

## The hub's session is gone (USB, a reboot): what the Dial held is no longer known to it.
func _link_lost(l: Lane, why: String) -> void:
	if not running():
		return
	match l.state:
		"READY", "ARMING", "OFFLINE", "CLOSING":
			if phase == "SETTLING":
				_set_lane(l, "CLOSED")
			else:
				l.retry_left = arm_retry_s
				_set_lane(l, "OFFLINE")
		"ABSORBING", "DROPPING", "SIMULATING", "RETURNING":
			l.capsule.orphaned = true  # it keeps scoring; it is not released by itself
		"RELEASING", "VERIFYING":
			_fault(l, "排出の途中で通信が切れた（%s）" % why)

# ------------------------------------------------------------------ stop / keys
## Space: everything of the game mode stops now. STOP_ALL goes to the devices whatever
## the state; nothing is released or re-armed afterwards.
func on_stop_key() -> void:
	if not _active:
		return
	if running():
		_halt("Space で止めた")
	else:
		devices.stop_all()

func _halt(why: String) -> void:
	devices.stop_all()
	_cmds.clear()
	field.set_frozen(true)
	sounds.set_bgm(false)
	sounds.play("stop")
	for side in SIDES:
		var l: Lane = lanes[side]
		if not l.capsule.is_empty():
			capsules.finish(l.capsule.capsule_id, "stopped")
			l.fault = "止めたので排出していない"
			_set_lane(l, "FAULT")
		elif l.state != "FAULT":
			_set_lane(l, "CLOSED")
	_set_phase("STOPPED")
	message = "止めました。カプセルが Dial に残っていたら係の人が取り出してね    Enter: やり直す    Esc: タイトル"
	_trace("stopped", null, {"result": why})
	trace.close()

## true = the key was the game mode's.
func handle_key(keycode: int) -> bool:
	if not _active:
		return false
	match keycode:
		KEY_ENTER, KEY_KP_ENTER:
			if not running():
				start()
			return true
		KEY_Z:
			return _mock_ball("left")
		KEY_M:
			return _mock_ball("right")
	return false

func _mock_ball(side: String) -> bool:
	if not devices.can_mock_ball():
		return false
	devices.mock_ball(lanes[side].device)
	return true

# ------------------------------------------------------------------ lights / trace
## The Illumination: decoration. Sent and forgotten (a refusal is only traced).
func _light(name: String, params: Dictionary) -> void:
	if not lights or not devices.available():
		return
	var rid := devices.command(GameModeDevices.ILLUMINATION, name, params)
	_cmds[rid] = {"lane": null, "what": "light", "left": command_timeout_s}

## The Dial's own transfer LEDs (its front LED and the one towards the screen), as
## UFO-DeviceHub's docs/game-mode-interface.md says: the named animation in the Dial's unit
## colour. Decoration: sent and forgotten. A refusal (IGNORED_PRIORITY, NOT_CONFIGURED, a
## timeout) changes nothing, and nothing ever waits for the answer. The Dial ends an effect
## by itself when it detects a capsule, when a release ends, on STOP_ALL and on a new session.
func _led(l: Lane, animation: String) -> void:
	var a: Dictionary = LED_ANIMATIONS[animation]
	var sent: bool = dial_leds and l.led_ok and devices.available()
	_trace("led", l, {"effect_id": a.effect, "led_command": "%s %s %s%s" % [animation, a.effect, a.direction,
		"" if sent else " (not sent)"]})
	if sent:
		_send(l, "led", "SET_DIAL_EFFECT", a.duplicate(true))

## The Dial's unit colour for this session = this side's colour on the screen, so the port
## and the Dial's LEDs match (the Dial forgets it with the session: sent after every SET_MODE).
func _dial_color(l: Lane) -> void:
	if dial_leds and l.led_ok:
		_send(l, "led", "SET_DIAL_COLOR", {"color": [l.color.r8, l.color.g8, l.color.b8]})

func _trace(event: String, l: Lane, extra: Dictionary) -> void:
	var row := {"event": event, "game_t": snappedf(clock, 0.001), "session_id": session, "game_state": phase}
	if l != null:
		row["source_dial"] = l.device
		row["lane_state"] = l.state
		if not l.capsule.is_empty():
			row["capsule_id"] = l.capsule.capsule_id
			row["cycle"] = l.capsule.cycle
			if field != null and field.has_capsule(l.capsule.capsule_id):
				var p := field.capsule_position(l.capsule.capsule_id)
				row["physics_position"] = [snappedf(p.x, 0.1), snappedf(p.y, 0.1)]
	for k in extra.keys():
		if extra[k] != null:
			row[k] = extra[k]
	trace.add(row)

## One line per lane for the HUD.
func lane_text(side: String) -> String:
	var l: Lane = lanes[side]
	match l.state:
		"READY":
			return "ここに入れてね"
		"ABSORBING", "DROPPING":
			return "てんそう中…"
		"SIMULATING":
			return "プレイ中"
		"RETURNING", "RELEASING", "VERIFYING":
			return "カプセルを返すよ"
		"FAULT":
			return "係の人を呼んでね\n" + l.fault
		"OFFLINE", "ARMING":
			return ("じゅんび中…" + ("\n" + l.note if l.note != "" else "")) if running() else "-"
	return "-"

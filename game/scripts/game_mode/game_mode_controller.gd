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
## #183: the practice shows what the fist does: the main scene is asked for the claw
## ("closed" when the easy mode's fist step is done, "open" when the practice capsule begins). The
## main scene sends it like the hand's own claw request, with all its checks; nothing is sent here.
signal tutorial_claw(which: String)
## #183: the practice's finger steps show the carry: the main scene is asked to move the arm
## over that Dial (1 / 2). The backend moves XY only, with its own checks.
signal tutorial_goto(destination: int)

## IDLE (not started) -> COUNTDOWN -> PLAYING -> SETTLING (time is up: capsules in play
## finish and go out) -> RESULT; STOPPED = the stop key
const PHASES := ["IDLE", "TUTORIAL", "COUNTDOWN", "PLAYING", "SETTLING", "RESULT", "STOPPED"]
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

const PIXEL_SIZE := GameModeLayout.PIXEL_SIZE
## one dot of the pixel canvas on the 1280 x 720 screen
const DOT_PX := GameModeLayout.DOT_PX
## how much of a shake the HUD does not follow (1 = it stands still)
const HUD_SHAKE_HELD := 0.75
const BOUNCE_PX := 8.0
const BOUNCE_MAX_PX := 16.0
const HITSTOP_MAX_S := 0.1
## what flies off a scoring hit: kind -> [sparks, ring radius (0 = no ring)]
const HIT_FX := {"pin": [3, 0.0], "sling": [6, 0.0], "spinner": [8, 0.0], "switch": [8, 40.0], "bumper": [10, 56.0], "pop": [8, 40.0],
	"target": [8, 36.0], "gem": [12, 36.0], "warp": [14, 60.0], "alien": [18, 60.0], "star": [18, 64.0],
	"goal_left": [12, 50.0], "goal_right": [12, 50.0], "goal_center": [20, 70.0], "jackpot": [48, 110.0]}
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
## sparks and rings (a fixed pool, in the pixel canvas)
var particles: GameModeParticles
var scope_enabled := true
var fx: GameModeVFX
var sounds: GameModeSounds
var hud: GameModeHud
## The round's end (#153): the breakdown (the truth: fixed once when RESULT is reached, {}
## before), the show's timeline (what is on the screen now) and its screen. The show is
## presentation: the score, the lanes and the devices never read it.
var result: Dictionary = {}
var result_show := ResultShow.new()
var result_screen: GameModeResultScreen
var _result_bonus_cfg: Dictionary = {}
## The high scores (#155): the ten best final scores, in a file. A round that reached its
## result is offered by itself when the result's show is over.
var ranking := RankingManager.new()
var ranking_hud: GameModeRankingHud
## config game_mode.ranking.enabled: false = no record is made and no board is shown
var ranking_enabled := true
## what of the ranking is on the screen: "" / "record" (NEW RECORD!) / "board" (HIGH SCORES)
var ranking_view := ""
## seconds since ranking_view changed
var ranking_view_t := 0.0
## this round's place (1 .. 10), 0 = it is not on the board
var ranking_rank := 0
## why not: "" / "zero" / "out" (11th or lower) / "demo" / "short" / "off"
var ranking_note := ""
## this round's id: one round can be recorded once
var round_id := ""
## a rehearsal's rounds are recorded too (--game-mode-ranking-file: a file of its own)
var ranking_force := false
var rank_hold_s := 1.2
var rank_record_s := 3.2
var _rank_state := ""  # "" (not offered yet) / "hold" / "record" / "done"
var _rank_t := 0.0
var _full_duration_s := 150.0
var _rng := RandomNumberGenerator.new()
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

## The practice before the round (#149): the steps (its own state, not the round's and not
## the robot's), its screen and UFOくん's voice. While it runs the phase is TUTORIAL: the
## 150 s clock stands still and nothing counts towards a result.
var tutorial := GestureTutorialController.new()
var tutorial_hud: GestureTutorialHud
var tutorial_speech: StudySpeech
## config game_mode.tutorial.enabled: Enter on the title goes through the practice first
var tutorial_auto := true
## what the practice shows: the round's own difficulty as it is played (set when it starts)
var tutorial_mode := GestureTutorialSteps.DEFAULT_MODE
## The round's difficulty (#169): "hard" = the manual hand control, "easy" = pinch for XY,
## a fist = catch by itself, one / two fingers = carry to Dial 1 / 2. Its own state (config
## game_mode.difficulty, D on the title); what the hand does with it is the main scene's
## EasyModeControl. This controller still sends nothing to the crane.
var difficulty := "hard"
## why the easy mode cannot be used here ("" = it can): another hand scheme, no backend.
## Set by the main scene. Then the round is played with the manual controls and says so.
var easy_block := ""
var easy_hud: EasyModeHud
var _tutorial_cfg: Dictionary = {}
## the practice was gone through (or left out by staff) since the game mode opened
var tutorial_seen := false
## config game_mode.debug_panel: the debug panel stays open beside the score game (false:
## it is closed when the score game opens; F1 / Tab opens it as ever)
var debug_panel := false
## The practice capsule (the tutorial's last step): the lane machine of the round, run
## without the clock. "" (none) / "open" (a Dial takes one) / "closing" (one came back;
## the rest closes) / "done" / "fault". Its score and its capsule never reach a result:
## the round starts from a full reset.
var practice := ""
var practice_released := 0
## staff left the practice capsule out: the Dials are closed first, then the practice ends
var _practice_skip := false
var _voice_seq := 0
## lines waiting for the voice's link, and for how long still (config game_mode.tutorial.voice_link_wait_s)
var _say_pending: Array = []
var _say_wait := 0.0
var voice_link_wait_s := 2.5
var _active := false
var _cmds: Dictionary = {}  # rid -> {lane: Lane or null, what, left}
var _seen: Dictionary = {}  # "session|source|event_id" -> true
var _hurry_done := false
var _warned_at := 99
var _counted := 99
var _combo_seen := 0
var _bounce := 0.0
var _bounce_t := 0.0
var _hitstop_left := 0.0
var _sweat_left := 0.0

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
	# everything inside keeps the 720 x 1280 design coordinates (GameModeLayout), drawn at half size
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
	particles = GameModeParticles.new()
	particles.name = "Particles"
	particles.effects = effects
	particles.quality = visual_quality
	pixel_view.add_child(particles)
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
	tutorial_hud = GestureTutorialHud.new()
	tutorial_hud.name = "GestureTutorialHud"
	layer.add_child(tutorial_hud)
	tutorial_hud.setup(self)
	easy_hud = EasyModeHud.new()
	easy_hud.name = "EasyModeHud"
	layer.add_child(easy_hud)
	easy_hud.setup(self)
	if main != null and main.get("easy") != null:
		main.easy.state_changed.connect(_on_easy_state)
	result_screen = GameModeResultScreen.new()
	result_screen.name = "GameModeResultScreen"
	layer.add_child(result_screen)
	result_screen.setup(self)
	result_show.cue.connect(_on_result_cue)
	ranking_hud = GameModeRankingHud.new()
	ranking_hud.name = "GameModeRankingHud"
	layer.add_child(ranking_hud)
	ranking_hud.setup(self)
	_rng.seed = 153
	tutorial_speech = StudySpeech.new()
	tutorial_speech.name = "TutorialSpeech"
	add_child(tutorial_speech)
	tutorial_speech.voice_request = _tutorial_voice
	tutorial_speech.voice_wait_s = 6.0  # a line VOICEVOX makes for the first time (after that: its cache, #171)
	tutorial.say.connect(_on_tutorial_say)
	tutorial.step_started.connect(_on_tutorial_step)
	tutorial.step_succeeded.connect(_on_tutorial_ok)
	tutorial.finished.connect(_on_tutorial_finished)
	if main != null and main.get("gesture") != null:
		main.gesture.claw_requested.connect(tutorial.on_claw)  # the claw's real request, heard only
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
	_full_duration_s = duration_s
	var rk: Dictionary = cfg.get("ranking", {}) if cfg.get("ranking") is Dictionary else {}
	ranking_enabled = bool(rk.get("enabled", ranking_enabled))
	rank_hold_s = clampf(float(rk.get("hold_s", rank_hold_s)), 0.0, 20.0)
	rank_record_s = clampf(float(rk.get("record_s", rank_record_s)), 0.0, 20.0)
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
	_result_bonus_cfg = cfg.get("result_bonus", {}) if cfg.get("result_bonus") is Dictionary else {}
	if cfg.get("result_show") is Dictionary:
		result_show.configure(cfg.result_show)
	_tutorial_cfg = cfg.get("tutorial", {}) if cfg.get("tutorial") is Dictionary else {}
	tutorial_auto = bool(_tutorial_cfg.get("enabled", tutorial_auto))
	# (an older config has only tutorial.mode)
	set_difficulty(str(cfg.get("difficulty", _tutorial_cfg.get("mode", difficulty))))
	tutorial.configure(_tutorial_cfg)
	voice_link_wait_s = clampf(float(_tutorial_cfg.get("voice_link_wait_s", voice_link_wait_s)), 0.0, 10.0)
	debug_panel = bool(cfg.get("debug_panel", debug_panel))

# ------------------------------------------------------------------ on / off
func active() -> bool:
	return _active

func running() -> bool:
	return phase in ["TUTORIAL", "COUNTDOWN", "PLAYING", "SETTLING"]

## The Dials take a capsule now: the round, or the practice capsule.
func _taking() -> bool:
	return phase == "PLAYING" or (phase == "TUTORIAL" and practice == "open")

## (for the easy mode: a new catch, a new carry, only while this is true)
func taking() -> bool:
	return _active and _taking()

# ------------------------------------------------------------------ difficulty (#169)
func set_difficulty(d: String) -> void:
	difficulty = "easy" if d == "easy" else "hard"

## The easy mode is what is played: asked for, and usable here.
func easy_on() -> bool:
	return difficulty == "easy" and easy_block == ""

## D on the title (never in a round): the other difficulty.
func toggle_difficulty() -> void:
	if running():
		return
	set_difficulty("hard" if difficulty == "easy" else "easy")
	sounds.play("count")

## The line under START on the title: the difficulty, and why easy is not used when it is not.
func difficulty_text() -> String:
	var name := str(GestureTutorialSteps.MODE_NAMES.get(difficulty, difficulty))
	var out := "D：モード きりかえ　［ %s ］" % name
	if difficulty == "easy" and easy_block != "":
		out += "\n" + easy_block + " → むずかしいモードの操作で遊ぶ"
	return out

## The easy mode's carry to this side's Dial ended: the claw opened over it (the backend's
## report, passed on by the main scene). That is not a capsule in the Dial: the Dial's own
## BALL_RECEIVED is, as ever. Only when both the crane and the Dials are simulated
## (`simulated_crane`, mock Dials) nothing real can fall, so the mock Dial is given its
## capsule here and the rehearsal runs to its end. Never with the real crane.
func easy_delivered(side: String, simulated_crane: bool) -> void:
	if not _active or not lanes.has(side):
		return
	var mock: bool = simulated_crane and running() and devices.can_mock_ball()
	_trace("easy_delivered", lanes[side], {"result": "mock capsule" if mock else "waiting for the Dial's BALL_RECEIVED"})
	if mock:
		devices.mock_ball(lanes[side].device)

func _on_easy_state(from: String, to: String) -> void:
	if _active:
		_trace("easy_state", null, {"result": "%s -> %s" % [from, to], "effect_id": str(main.easy.note)})

## Nothing new is played: what is in a Dial goes straight back out.
func _closing() -> bool:
	return phase == "SETTLING" or (phase == "TUTORIAL" and practice == "closing")

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
	ranking.load_file()  # a missing or damaged file is an empty or shorter ranking, never a stop
	tutorial_seen = false
	_set_phase("IDLE")
	message = "Enter でスタート"

## Leaves the game mode (Esc to the title). A running round is stopped like the stop key
## (STOP_ALL to the devices); nothing is released afterwards.
func close() -> void:
	if not _active:
		return
	if running() and (phase != "TUTORIAL" or practice != ""):
		_halt("タイトルに戻った")  # the practice capsule too: STOP_ALL, nothing released afterwards
	_end_tutorial()
	_flush_ranking()
	_active = false
	sounds.set_bgm(false)
	sounds.ending_on = false
	field.clear()
	fx.reset()
	_clear_result()
	_clear_ranking_view()
	trace.close()
	layer.visible = false
	layer.offset = Vector2.ZERO
	hud.position = Vector2.ZERO
	screen.position = Vector2.ZERO
	scope.step(0.0, false)
	pixel_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	field.process_mode = Node.PROCESS_MODE_DISABLED
	phase = "IDLE"

## Enter: the practice first (once per visit, config game_mode.tutorial.enabled), else the round.
func begin() -> void:
	if not _active or running():
		return
	if tutorial_auto and not tutorial_seen:
		start_tutorial()
	else:
		start()

## The practice (#149): the spell, the hand shapes one by one, one real capsule, then the
## round. Nothing of it reaches the round: the round starts from a full reset.
func start_tutorial() -> void:
	if not _active or running():
		return
	_reset_round()
	_set_phase("TUTORIAL")
	message = ""
	var scheme_id := PinchJoystickScheme.ID
	var claw := {"fist": "closed", "peace": "open"}
	var hand_on := false
	if main != null and main.get("gesture") != null:
		scheme_id = main.gesture.scheme.id()
		claw = main.gesture.scheme.claw_poses()
		hand_on = main.gesture.enabled
	var hw := _voice_client()
	if hw != null and hw.has_method("_ensure_link"):
		hw._ensure_link()  # the voice comes over the helper's link (it may be off until now)
	tutorial_mode = "easy" if easy_on() else "hard"  # the practice shows what the round will be
	tutorial.begin(GestureTutorialSteps.resolve(_tutorial_cfg, tutorial_mode, scheme_id, claw), hand_on or demo)
	_trace("tutorial_start", null, {"result": tutorial_mode})

func _end_tutorial() -> void:
	tutorial.cancel()
	_say_pending = []
	tutorial_speech.clear()
	practice = ""

## The practice capsule: both Dials are prepared and armed as in a round; the clock stays.
func practice_begin() -> void:
	if phase != "TUTORIAL":
		return
	_reset_round()
	session = devices.session_id()
	practice = "open"
	if trace_to_file:  # the practice capsule has its own trace file: it is not part of a round's
		trace.open("user://game_mode/practice_%s.jsonl" % Time.get_datetime_string_from_system().replace(":", "").replace("-", ""))
	for side in SIDES:
		_prepare(lanes[side])
	_trace("practice_start", null, {})

## A capsule is on its way through the practice (it is not left behind by a skip).
func practice_busy() -> bool:
	for side in SIDES:
		if not lanes[side].capsule.is_empty():
			return true
	return false

## One practice capsule came back (or a Dial failed): the Dials still waiting are closed,
## a capsule still in play finishes.
func _practice_close() -> void:
	if practice != "open":
		return
	practice = "closing"
	_close_idle_lanes()

func _tick_practice() -> void:
	if practice == "open":
		for side in SIDES:
			if lanes[side].state == "FAULT":
				_practice_close()
				break
	if practice == "closing" and _all_settled():
		var failed := false
		for side in SIDES:
			failed = failed or lanes[side].state == "FAULT"
		if _practice_skip and not failed:
			practice = "skipped"
			_trace("practice_end", null, {"result": practice})
			tutorial.skip_all()  # no OK: the capsule was not done. The round starts.
			return
		practice = "done" if practice_released > 0 and not failed else "fault"
		_trace("practice_end", null, {"result": practice})

func _hand_snapshot() -> Dictionary:
	if demo and tutorial.active():
		return GestureTutorialController.demo_hand(tutorial.step(), tutorial.t)
	if main == null or main.get("gesture") == null:
		return {"enabled": false}
	var g: GestureControl = main.gesture
	var now := float(Time.get_ticks_msec())
	var age := g.age_ms(now)
	return {"enabled": g.enabled, "fresh": age >= 0.0 and age <= g.stale_ms, "camera_ok": g.camera_ok, "detected": g.detected,
		"pose": g.pose, "pinch": g.pinch, "pinch_finger": g.pinch_finger, "pos": g.hand_norm, "active": g.is_active(),
		"palm": g.palm, "mode": g.mode,
		# 0..1 of the top speed of what it steers (XY in mm/s, up / down in Z units/s)
		"speed": maxf(g.velocity.length() / maxf(g.scheme.max_speed(g), 1e-6), absf(g.velocity_z) / maxf(g.joystick.max_speed_z, 1e-6)) if g.is_active() else 0.0,
		"gate": str(main.get("gesture_gate_reason")), "claw_progress": g.claw_progress(now)}

## Lines for UFOくん. The voice comes over the helper's link, which may only just be
## opening (the practice's first line, the spell): the lines wait for it a moment
## (voice_link_wait_s) instead of being shown without a voice. Never longer: the voice is
## decoration.
func _on_tutorial_say(lines: Array) -> void:
	tutorial_speech.clear()
	_say_pending = []
	if voice_link_wait_s > 0.0 and _voice_coming():
		_say_pending = lines.duplicate()
		_say_wait = voice_link_wait_s
		return
	tutorial_speech.say(lines)

## A voice is possible but its link is not up yet (still connecting, or no hello yet).
func _voice_coming() -> bool:
	var hw := _voice_client()
	if hw == null or not tutorial_speech.voice_on or hw.get("link") == null or not hw.link.enabled:
		return false
	return not hw.link.is_open() or not bool(hw.get("hello_seen"))

func _tick_say(dt: float) -> void:
	if _say_pending.is_empty():
		return
	_say_wait -= dt
	if _say_wait <= 0.0 or not _voice_coming():
		var lines := _say_pending
		_say_pending = []
		tutorial_speech.say(lines)

var _demo_claw_closed := false

func _on_tutorial_step(_index: int, step: Dictionary) -> void:
	# the claw closed by the fist step stays closed (the carry is shown with it) and opens
	# when the practice capsule begins
	if _demo_claw_closed and str(step.get("kind", "")) == "practice":
		_demo_claw_closed = false
		tutorial_claw.emit("open")
	match str(step.get("kind", "")):
		"summon":
			sounds.play("summon")
			backdrop.pulse(Color("8a5cff"), 0.9)
		"practice":
			practice_begin()

## The one "OK" of a step: the chime, UFOくん's wink, stars. Once per step.
func _on_tutorial_ok(_index: int, step: Dictionary) -> void:
	sounds.play("tutorial_ok")
	if int(step.get("goto_demo", 0)) in [1, 2]:
		tutorial_goto.emit(int(step.goto_demo))
	if bool(step.get("claw_demo", false)):
		_demo_claw_closed = true
		tutorial_claw.emit("closed")
	fx.react("big")
	_trace("tutorial_ok", null, {"effect_id": str(step.get("id", ""))})

func _on_tutorial_finished(how: String) -> void:
	tutorial_seen = true
	_trace("tutorial_end", null, {"result": how})
	tutorial_speech.clear()
	if how == "done":
		tutorial_speech.say(["よし！ はじめよう！"])
	if phase != "TUTORIAL":
		return
	# the practice is over: the round starts from a full reset (no score, no capsule, no
	# clock of the practice is carried over; what the Dials already reported stays known)
	phase = "IDLE"
	start(true)

## The practice's gauge can be heard filling (#179): a blip every gauge_tick_s while the
## step's hold really grows, higher as it fills. Nothing while it stands or falls, in a
## step that is told, or after the OK.
var gauge_tick_s := 0.14
var _gauge_left := 0.0
var _gauge_seen := 0.0

func _tick_gauge_sound(dt: float) -> void:
	var p := tutorial.progress
	var growing: bool = tutorial.state == "judging" and not tutorial.telling() \
		and GestureTutorialController.is_hand_kind(tutorial.kind()) and p > _gauge_seen + 1e-4 and p < 1.0
	_gauge_seen = p
	_gauge_left -= dt
	if growing and _gauge_left <= 0.0:
		_gauge_left = gauge_tick_s
		sounds.play("gauge", "", 0.8 + 1.0 * p)

## UFOくん's voice for a line: asked of the backend (VOICEVOX / say) over the helper's link.
## "" = no voice now: the line is shown as words for its reading time.
func _tutorial_voice(text: String) -> String:
	var hw := _voice_client()
	if hw == null or not bool(hw.get("speech_available")) or hw.get("link") == null or not hw.link.is_open():
		return ""
	_voice_seq += 1
	var rid := "sm-gt-say-%d-%d" % [Time.get_ticks_msec(), _voice_seq]  # "sm-": the helper leaves it to its asker
	if hw.link.send_aux({"type": "homework_say", "request_id": rid, "data": {"text": text}}) != OK:
		return ""
	return rid

## The helper's link to the backend (the game's own, else the study mode's): where a voice
## can be asked for. null = there is none (no helper configured): the lines are words only.
func _voice_client() -> Node:
	if main == null:
		return null
	var hw: Node = main.get("homework") if main.get("homework") is Node else null
	if hw == null and main.get("study_mode") != null and main.study_mode != null and main.study_mode.services.homework is Node:
		hw = main.study_mode.services.homework
	if hw != null and hw.has_signal("aux_message") and not hw.aux_message.is_connected(_on_tutorial_aux):
		hw.aux_message.connect(_on_tutorial_aux)
	return hw

func _on_tutorial_aux(msg: Dictionary) -> void:
	var rid := str(msg.get("request_id", ""))
	if not rid.begins_with("sm-gt-"):
		return
	var data: Dictionary = msg.get("data", {}) if msg.get("data") is Dictionary else {}
	match str(msg.get("type", "")):
		"homework_speech":
			tutorial_speech.on_voice(rid, HomeworkClient.wav_stream(Marshalls.base64_to_raw(str(data.get("wav_base64", "")))), str(data.get("credit", "")))
		"homework_speech_error", "homework_error":
			tutorial_speech.on_voice_error(rid, str(data.get("message", "")))

## `after_practice`: what the Dials reported in the practice stays known (a repeated
## BALL_RECEIVED of the practice capsule is still old), everything else starts new.
func start(after_practice := false) -> void:
	if not _active or running():
		return
	var known := {}
	var seen := _seen.duplicate()
	for side in SIDES:
		known[side] = [lanes[side].last_cycle, lanes[side].cycle_session]
	_reset_round()
	if after_practice:
		_seen = seen
		for side in SIDES:
			lanes[side].last_cycle = int(known[side][0])
			lanes[side].cycle_session = int(known[side][1])
	round_id = RankingManager.new_id()
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
	_flush_ranking()
	score.reset()
	capsules.reset()
	ufo.reset()
	field.clear()
	field.set_frozen(false)
	fx.reset()
	particles.clear()
	_clear_result()
	_clear_ranking_view()
	_hitstop_left = 0.0
	_bounce = 0.0
	sounds.set_bgm(false)
	sounds.ending_on = false
	practice = ""
	practice_released = 0
	_practice_skip = false
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
		# the score and the clock move only a quarter as far (#157): on the tall screen they sit
		# at its very top edge and must stay readable, and inside it, through the biggest shake
		hud.position = -layer.offset * HUD_SHAKE_HELD
	scope.demo = demo  # the rehearsal has its own made-up picture: no camera needed
	scope.step(dt, scope_enabled and phase != "IDLE")
	# the hit-stop: only the picture holds still for a moment (the canvas is not redrawn);
	# the physics, the clock and the devices go on in tick() as ever
	_hitstop_left = maxf(_hitstop_left - dt, 0.0)
	pixel_view.render_target_update_mode = SubViewport.UPDATE_DISABLED if _hitstop_left > 0.0 else SubViewport.UPDATE_ALWAYS
	# the bounce: the picture drops a few dots and springs back (whole dots, so it stays crisp)
	_bounce_t += dt
	screen.position = Vector2(0, snappedf(bounce_offset(), DOT_PX))

## The picture holds still for `secs` (a big score). Only the picture.
func hitstop(secs: float) -> void:
	if effects and visual_quality != "low":
		_hitstop_left = clampf(maxf(_hitstop_left, secs), 0.0, HITSTOP_MAX_S)

func hitstop_left() -> float:
	return _hitstop_left

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
	particles.effects = effects
	if phase == "PLAYING":
		fx.ufo_mood = "hurry" if time_left <= hurry_s else "normal"
	elif phase == "SETTLING":
		fx.ufo_mood = "over"
	elif phase == "RESULT":
		fx.ufo_mood = "happy" if final_score() > 0 else "sad"
	else:
		fx.ufo_mood = "stopped" if phase == "STOPPED" else "normal"
	backdrop.energy = lvl / 3.0
	backdrop.urgency = (2 if time_left <= warning_s else (1 if time_left <= hurry_s else 0)) if playing else 0
	backdrop.time_k = time_left / maxf(duration_s, 1.0) if playing else 1.0
	if playing and time_left <= hurry_s:  # the UFO sweats while the time is short
		_sweat_left -= 1.0 / 60.0
		if _sweat_left <= 0.0:
			_sweat_left = 0.5 if time_left > warning_s else 0.25
			particles.burst(ufo.position() + Vector2(34, -30), Color("9fe8ff"), 2, 90.0, -PI * 0.25, 0.8, 0.0)
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
	particles.advance(dt)
	result_screen.advance(dt)
	ranking_hud.advance(dt)
	result_show.advance(dt)  # the result's timeline: its cues come out of this, in this tick
	_tick_ranking(dt)
	backdrop.advance(dt)
	if phase != "STOPPED":
		ufo.advance(dt)
	fx.ufo_pos = ufo.position()
	fx.ufo_visible = phase != "IDLE"  # on the title screen the UFO is the big one in the middle
	match phase:
		"TUTORIAL":
			if practice != "":
				clock += dt  # the practice capsule's own time (combos); the 150 s clock stands still
				_tick_practice()
				if demo and practice == "open" and devices.can_mock_ball() and tutorial.t > 2.0 and not practice_busy() \
						and lanes["left"].state == "READY":
					_mock_ball("left")  # the rehearsal puts the practice capsule in by itself
			_tick_say(dt)
			_tick_gauge_sound(dt)
			tutorial.tick(dt, _hand_snapshot(), {"speech_busy": tutorial_speech.busy() or not _say_pending.is_empty(), "practice": practice,
				"devices_ok": devices.available(), "capsule": practice_busy()})
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
	fx.react("start")
	particles.burst(ufo.position(), Color("ffe03c"), 24, 260.0)
	particles.ring(ufo.position(), Color("3ff0ff"), 110.0, 0.5)
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
		fx.react("hurry")
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
	result_show.time_up()  # the picture and the thud; SETTLING goes on by itself
	_trace("time_up", null, {})
	_close_idle_lanes()

## The Dials that hold nothing stop taking capsules (the round's end, the practice's end).
func _close_idle_lanes() -> void:
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
	# the breakdown is fixed here, once: everything that scored (SETTLING included) is in
	# score.score by now, and nothing can score after this (the field is cleared)
	result = ResultBonus.of_round(score, capsules, _result_bonus_cfg)
	field.clear()
	sounds.set_bgm(false)
	sounds.ending_on = true  # the result's music (#173), until the next round or the title
	for side in SIDES:
		var l: Lane = lanes[side]
		if l.state == "CLOSED":  # a faulted Dial is left as it is for a person to look at
			_led(l, "CLEAR")
			_send(l, "standby", "SET_MODE", {"mode": "STANDBY"})
	_light("SET_LIGHT_MODE", {"mode": "RESULT", "brightness": 180, "speed": 128, "transition_ms": 500})
	_light("TRIGGER_EFFECT", {"effect": "GAME_CLEAR", "duration_ms": 2000, "intensity": 220})
	message = "Enter: すぐ はじめる    T: もういちど れんしゅう    Esc: タイトル"
	# the same numbers as the screen: the score while playing and the whole breakdown
	var numbers := result.duplicate()
	numbers.erase("items")
	_trace("result", null, {"score_delta": score.score, "breakdown": numbers})
	# (the trace is closed when the ranking has been asked: its row is the round's last)
	result_show.begin(result, effects)  # the show starts; it changes nothing of the above

## The round's final score (the score while playing plus the end bonuses); before the
## result is reached, the score so far.
func final_score() -> int:
	return int(result.get("final_score", score.score))

## The number the HUD's score panel shows: the round's score, and in the result the number
## the show has reached (so the small panel and the big number never disagree).
func display_score() -> float:
	return result_show.shown if phase == "RESULT" and result_show.active() else float(score.score)

func _clear_result() -> void:
	result = {}
	result_show.reset()
	if result_screen != null:
		result_screen.clear()

func _shake(amount: float) -> void:
	if effects and amount > 0.0 and main != null and main.get("shake") != null:
		main.shake.add_trauma(amount)  # render.screen_shake off: nothing moves

## A cue of the result's timeline: every part of it (the sound, the shake, the bounce, the
## hit-stop, the light, the sparks) is started here, in this one tick, so they stay in
## step. Presentation only: no device, no score, and nothing waits for any of it.
func _on_result_cue(name: String, d: Dictionary) -> void:
	var c := GameModeResultScreen.CENTRE
	var rp := result_screen.particles
	var k := float(d.get("strength", 1.0))
	match name:
		"time_up":
			sounds.play("timeup_hit")
			_shake(0.7)
			hitstop(0.06)
			backdrop.pulse(Color.WHITE, 1.0)
		"reveal":
			backdrop.pulse(Color("3ff0ff"), 0.5)
		"count":  # the blips climb with the number
			sounds.play("result_count", "", 0.8 + 1.1 * float(d.get("k", 0.0)))
			rp.burst(c + Vector2(_rng.randf_range(-220.0, 220.0), 40.0), Color("ffe03c"), 2, 260.0, -PI * 0.5, PI * 0.8)
		"score_lock":
			sounds.play("score_lock")
			_shake(0.45)
			bounce(1.0)
			hitstop(0.05)
			rp.ring(c, Color("ffe03c"), 330.0, 0.5, 60.0)
			rp.burst(c, Color("ffe03c"), 40, 440.0)
		"bonus_show":
			sounds.play("bonus_show")
			_shake(0.15 + 0.2 * k)
			bounce(0.4 + 0.4 * k)
			rp.burst(Vector2(c.x, GameModeResultScreen.TITLE_Y), Color("ff4fd8"), int(14 + 20 * k), 320.0)
			rp.ring(GameModeResultScreen.BONUS_AT, Color("ff4fd8"), 120.0 + 80.0 * k, 0.4, 20.0)
		"bonus_hit":
			sounds.play("bonus_hit")
			_shake(0.3 + 0.45 * k)
			bounce(0.7 + 0.9 * k)
			hitstop(0.04 + 0.05 * k)
			rp.ring(c, Color("3ff0ff"), 260.0 + 220.0 * k, 0.5, 60.0)
			rp.ring(c, Color.WHITE, 180.0 + 120.0 * k, 0.35, 40.0)
			rp.burst(c, Color("ffe03c"), int(24 + 50 * k), 380.0 + 180.0 * k)
			_confetti(2 + int(round(3.0 * k)))
			backdrop.pulse(Color("ffe03c"), 0.5 + 0.5 * k)
			if k >= 0.6:
				result_screen.sheet("success_sparkle", c, 4.0)
		"bonus_lock":
			sounds.play("score_lock", "", 1.26)
		"final":
			if int(d.get("points", 0)) > 0:
				sounds.play("final_hit")
				sounds.play("result")  # the fanfare
				_shake(1.0)
				bounce(2.0)
				hitstop(HITSTOP_MAX_S)
				rp.ring(c, Color("3ff0ff"), 640.0, 0.8, 80.0)
				rp.ring(c, Color("ff4fd8"), 480.0, 0.65, 60.0)
				rp.ring(c, Color("ffb020"), 340.0, 0.5, 40.0)
				rp.burst(c, Color("ffe03c"), 70, 620.0)
				_confetti(5)
				result_screen.sheet("success_sparkle", c, 5.0)
				# party poppers from under the number, falling back to its foot
				result_screen.sheet("success_confetti", Vector2(c.x, GameModeResultScreen.CONFETTI_Y), 3.0)
				fx.react("big")
				backdrop.pulse(Color("ffb020"), 1.0)
			else:  # nothing scored: the score stands, quietly
				sounds.play("result")
				fx.react("miss")
		"confetti":
			_confetti(3)
			result_screen.sheet("success_sparkle", c + Vector2(_rng.randf_range(-280.0, 280.0), _rng.randf_range(-260.0, 260.0)), 2.0)
		"settled":
			# skipped, or shown without the show: the fanfare still marks the result, once
			if str(d.get("how", "")) in ["skipped", "plain"] and not result_show.log.has("final"):
				sounds.play("result")

## Paper falls from the top of the screen in the three neon colours.
func _confetti(bursts: int) -> void:
	var cols := [Color("ffe03c"), Color("3ff0ff"), Color("ff4fd8")]
	for i in bursts:
		result_screen.particles.burst(Vector2(_rng.randf_range(60.0, GameModeLayout.SCREEN.x - 60.0), _rng.randf_range(-10.0, 160.0)),
			cols[(i + _rng.randi()) % 3], 14, 300.0, PI * 0.5, PI * 0.9, 0.15)

# ------------------------------------------------------------------ high scores (#155)
## The result's show is over: the round's final score is offered to the ranking, by
## itself (no one types anything), once. Then "NEW RECORD!" when it made the top ten, then
## the board. Presentation and a file: no device hears of it, the score is not changed.
func _tick_ranking(dt: float) -> void:
	ranking_view_t += dt
	if phase != "RESULT":
		return
	match _rank_state:
		"":
			if result_show.settled():
				_register_score()
				_rank_t = rank_hold_s  # the final score stands a moment longer
				_rank_state = "hold" if ranking_enabled else "done"
		"hold":
			_rank_t -= dt
			if _rank_t <= 0.0:
				_show_rank()
		"record":
			_rank_t -= dt
			if _rank_t <= 0.0:
				_show_board()

## Why this round is not offered to the ranking ("" = it is): only a round played to its
## end by people counts. STOPPED and the practice never come here (they have no result).
func ranking_excluded() -> String:
	if not ranking_enabled:
		return "off"
	if ranking_force:
		return ""
	if demo:
		return "demo"
	if duration_s < _full_duration_s - 0.01:
		return "short"  # a round shortened from the command line (a rehearsal)
	return ""

func _register_score() -> void:
	ranking_rank = 0
	ranking_note = ranking_excluded()
	var final := final_score()
	if ranking_note == "" and final <= 0:
		ranking_note = "zero"
	if ranking_note == "":
		ranking_rank = ranking.submit(final, round_id)
		if ranking_rank == 0:
			ranking_note = "out"
	_trace("ranking", null, {"score_delta": final, "result": ("rank %d" % ranking_rank) if ranking_rank > 0 else ranking_note})
	trace.close()

func _show_rank() -> void:
	if ranking_rank <= 0 or not effects:
		_show_board()  # not a record (or no effects): straight to the board
		return
	ranking_view = "record"
	ranking_view_t = 0.0
	_rank_state = "record"
	_rank_t = rank_record_s
	result_screen.clear()
	# every part of the celebration starts in this one tick
	var c := GameModeRankingHud.CENTRE
	var rp := ranking_hud.particles
	var k := 1.0 - 0.06 * (ranking_rank - 1)  # the higher the place, the more of everything
	sounds.play("new_record")
	sounds.play("jackpot")  # the fanfare
	_shake(0.6 + 0.4 * k)
	bounce(1.2 + 0.8 * k)
	hitstop(HITSTOP_MAX_S)
	rp.ring(c, Color("ffd23c"), 620.0, 0.8, 80.0)
	rp.ring(c, Color("3ff0ff"), 460.0, 0.65, 60.0)
	rp.ring(c, Color("ff4fd8"), 320.0, 0.5, 40.0)
	rp.burst(c, Color("ffe03c"), int(50 + 40 * k), 600.0)
	var cols := [Color("ffe03c"), Color("3ff0ff"), Color("ff4fd8")]
	for i in 6:
		rp.burst(Vector2(_rng.randf_range(60.0, GameModeLayout.SCREEN.x - 60.0), _rng.randf_range(-10.0, 160.0)), cols[i % 3], 14, 300.0, PI * 0.5, PI * 0.9, 0.15)
	ranking_hud.art.visible = true  # (it is shown from this tick: the sheets go on it now)
	ranking_hud.sheet("success_sparkle", c, 5.0)
	ranking_hud.sheet("success_confetti", Vector2(c.x, GameModeRankingHud.CONFETTI_Y), 3.0)
	fx.react("big")
	backdrop.pulse(Color("ffd23c"), 1.0)

func _show_board() -> void:
	ranking_view = "board"
	ranking_view_t = 0.0
	_rank_state = "done"
	result_screen.clear()
	ranking_hud.clear()
	sounds.play("goal")

## R on the score game's title: the board, and back.
func toggle_ranking() -> void:
	if phase != "IDLE":
		return
	ranking_view = "" if ranking_view != "" else "board"
	ranking_view_t = 0.0
	if ranking_view == "board":
		ranking.load_file()  # as it is on the disk now
		sounds.play("goal")

## A result is being left before its show was over (Enter then T, T, Esc): the round was
## played to its end, so its score is still offered to the ranking, quietly.
func _flush_ranking() -> void:
	if phase == "RESULT" and _rank_state == "" and not result.is_empty():
		_register_score()
		_rank_state = "done"

func _clear_ranking_view() -> void:
	ranking_view = ""
	ranking_view_t = 0.0
	ranking_rank = 0
	ranking_note = ""
	_rank_state = ""
	_rank_t = 0.0
	if ranking_hud != null:
		ranking_hud.clear()

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
			if phase in ["COUNTDOWN", "PLAYING"] or _taking():
				l.retry_left -= dt
				if l.retry_left <= 0.0:
					_prepare(l)
		"ABSORBING":
			l.t -= dt
			if l.t <= 0.0:
				l.t = drop_s
				_set_lane(l, "DROPPING")
				fx.play("capsule_materialize", l.side, Vector2(l.capsule.drop_x, PinballField.SPAWN_Y), drop_s)
				fx.react("drop")
				particles.burst(Vector2(l.capsule.drop_x, PinballField.SPAWN_Y), l.color, 10, 180.0, PI * 0.5, 1.4)
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
	fx.react("call")
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
	field.flash_capsule(capsule_id)
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
		fx.react("miss")  # it ran out of time on the field: no goal
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
	# sparks and a ring from the hit, more as the combo climbs; the UFO is pleased
	var hf: Array = HIT_FX.get(kind, [6, 0.0])
	var tint: Color = l.color if l != null else Color.WHITE
	var up := kind.begins_with("goal") or kind == "jackpot"  # out of a goal they fountain upward
	particles.burst(pos, Color("ffe03c") if big else tint, int(hf[0] * (1.0 + 0.3 * lvl)), 300.0 if big else 220.0,
		-PI * 0.5, PI * 0.7 if up else TAU)
	if float(hf[1]) > 0.0:
		particles.ring(pos, Color("ffe03c") if big else tint, float(hf[1]) * (1.0 + 0.15 * lvl))
	if str(r.bonus) != "":
		particles.burst(pos, Color("ff4fd8"), 30, 340.0)
		particles.ring(pos, Color.WHITE, 140.0, 0.5)
		hitstop(0.08)
	elif big:
		hitstop(0.05)
	if kind != "pin":
		fx.react("big" if big else "score")
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
	if phase == "TUTORIAL":
		practice_released += 1
		_practice_close()  # one capsule is the practice: the other Dial stops waiting

func _fault(l: Lane, why: String) -> void:
	l.fault = why
	if not l.capsule.is_empty():
		capsules.finish(l.capsule.capsule_id, "failed")
		field.remove_capsule(l.capsule.capsule_id)
	_set_lane(l, "FAULT")
	_led(l, "FAULT")
	fx.play("capsule_fault", l.side)
	fx.react("miss")
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
				if _taking():
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
				if not _taking():  # time ran out while it was arming
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
	if _taking() and l.state in ["READY", "ARMING", "OFFLINE"]:
		_take(l, cycle, false)
	elif _closing() and l.state in ["READY", "CLOSING", "CLOSED"]:
		_take(l, cycle, true)  # it landed as the time ran out
	else:
		_trace("ball_ignored", l, {"cycle": cycle, "result": "not_accepting:%s/%s" % [phase, l.state]})

## The hub's session is gone (USB, a reboot): what the Dial held is no longer known to it.
func _link_lost(l: Lane, why: String) -> void:
	if not running():
		return
	match l.state:
		"READY", "ARMING", "OFFLINE", "CLOSING":
			if _closing() or (phase == "TUTORIAL" and practice != "open"):
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
		result_show.skip("stopped")  # a stop during the result's show: the show ends too, quietly (the score stands)

func _halt(why: String) -> void:
	_demo_claw_closed = false  # a stop: nothing more is asked of the claw
	devices.stop_all()
	_cmds.clear()
	_end_tutorial()
	field.set_frozen(true)
	fx.react("stop")
	sounds.set_bgm(false)
	sounds.ending_on = false
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
	message = "止めました。カプセルが Dial に残っていたら係の人が取り出してね    Enter: やり直す    T: れんしゅうから    Esc: タイトル"
	_trace("stopped", null, {"result": why})
	trace.close()

## true = the key was the game mode's.
func handle_key(keycode: int) -> bool:
	if not _active:
		return false
	match keycode:
		KEY_ENTER, KEY_KP_ENTER:
			# the title: the practice first. After a round: straight into the next one
			# (T = the practice once more). In the practice Enter does nothing, so no one
			# skips it by accident. While the result's show runs, the first Enter only
			# takes it to its last picture; the next one starts the round.
			if phase == "RESULT" and result_show.active() and not result_show.settled():
				result_show.skip()
			elif phase == "RESULT" and ranking_enabled and _rank_state != "done":
				# the final score, or NEW RECORD!, is still up: on to the board (the score is
				# offered to the ranking first if it was not yet); Enter on the board plays
				if _rank_state == "":
					_tick_ranking(0.0)
				_show_board()
			elif not running():
				begin()
			return true
		KEY_T:
			if not running():
				start_tutorial()
				return true
			return false
		KEY_D:
			if not running():
				toggle_difficulty()
				return true
			return false
		KEY_R:
			if phase == "IDLE" and ranking_enabled:
				toggle_ranking()
				return true
			return false
		KEY_F6, KEY_F7, KEY_F8:
			return _staff_key(keycode)
		KEY_Z:
			return _mock_ball("left")
		KEY_M:
			return _mock_ball("right")
	return false

## Staff keys of the practice (function keys: not hit by accident). F6 = this step again,
## F7 = on to the next step, F8 = leave the practice out. A capsule on its way through the
## practice is never left behind: F7 / F8 wait until it is back. Dials waiting for the
## practice capsule are disarmed before the round's countdown (in which nothing is taken).
func _staff_key(keycode: int) -> bool:
	if phase != "TUTORIAL":
		return false
	if practice_busy():
		tutorial.guide = "カプセルが もどるまで まってね"
		return true
	match keycode:
		KEY_F6:
			tutorial.retry_step()
		KEY_F7, KEY_F8:
			if practice == "open":
				# the Dials are waiting for a capsule: they are closed first (a capsule that lands
				# meanwhile goes straight back out), and only then does the round start
				_practice_skip = true
				_practice_close()
				tutorial.guide = "ポータルを とじているよ…"
			elif practice == "closing":
				pass  # already on its way
			elif keycode == KEY_F7 and tutorial.kind() != "practice":
				tutorial.skip_step()
			else:
				tutorial.skip_all()
	return true

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

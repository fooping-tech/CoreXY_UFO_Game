class_name GameModeController
extends Node
## SUMMON THE UFO, the 150 s score game (#138; the rules are docs/game_mode_spec.md).
##
## The player grabs real capsules with the crane and drops them into the M5Dial on the
## left of the screen (Dial 1, 0x20): the only portal (#200; there was a second one on the
## right, Dial 2, 0x21: nothing is sent to it and nothing of it is read any more). A capsule
## the Dial reports (BALL_RECEIVED) appears to come into the screen through its port, flies to
## UFOくん and is dropped from where the UFO was at that moment into the pinball field.
## When it leaves the field it goes back out through its own side's port, and the same
## Dial is told to let the real one go (RELEASE_BALL).
##
## This controller owns the experience: the clock, the lanes (one per Dial, each with its
## own state machine; since #200 the left one only), the score. It is separate from RobotState and from the crane:
## it never sends a robot command and never reads the arm's position; the player keeps
## the usual manual controls. The devices are reached only through GameModeDevices.
##
## What it never does:
##  - blindly retry a release: a rejected command, a missing RELEASE_DONE, or a new session
##    never triggers an automatic resend. Only after RELEASE_DONE and a verified switch-on
##    (capsule still inside) may the lane send a NEW release command, at most
##    game_mode.timing.release_retries times (#185, Dial firmware >= 0.4).
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

## #185: the practice is at a step that only asks for the pinch (not for moving): the main
## scene lets the hand stick move nothing meanwhile (a hand is never quite still while its
## fingers close, and the arm ran sideways).
func hand_holds_still() -> bool:
	return _active and phase == "TUTORIAL" and tutorial.active() and tutorial.kind() == "pinch"

## #183: the practice's finger steps show the carry: the main scene is asked to move the arm
## over the Dial (1). The backend moves XY only, with its own checks.
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
	# #188: three balls on the screen for this Dial's one capsule. The front strip only (the
	# transfer strip keeps its role); NORMAL so it may replace a running INTAKE; RETURN_FLOW ends it
	"MULTI_BALL": {"effect": "COMET", "direction": "TO_DIAL", "duration_ms": 0, "priority": "NORMAL", "target": "FRONT"},
	"FAULT": {"effect": "FLASH", "direction": "NONE", "duration_ms": 1500, "priority": "HIGH", "target": "BOTH", "color": [255, 0, 0]},
	"CLEAR": {"effect": "NONE", "direction": "NONE", "duration_ms": 0, "priority": "HIGH", "target": "BOTH"},
}
## answers that mean "this firmware has no such command" (Dial 0.2: UNSUPPORTED, Hub 0.2: BAD_REQUEST)
const LED_UNKNOWN := ["UNSUPPORTED", "BAD_REQUEST"]
## #200: the portal is on the left only (Dial 1). The lanes stay keyed by their side.
const SIDES := ["left"]

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
	## how many more RELEASE_BALL this capsule got because it did not leave the Dial (#185)
	var re_releases := 0

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
## #266: the capsule kinds (fire / water / green / normal) and the arm camera's colour votes
var kinds := CapsuleKinds.new()
var colour_reader := CapsuleKinds.Reader.new()
var kinds_enabled := true
## what a capsule is when no camera saw it and the Dials are mock ones ("random", a kind,
## "normal"; config game_mode.capsule_kinds.mock_kind). Never with the real Dials.
var mock_kind := "random"
## where the colour frames come from: func() -> Image (null = none now). Unset: the arm
## camera (CameraHub's focus role) when it shows a real picture. The tests set it.
var colour_source := Callable()
## the kind of the capsule taken in last (tests, the trace)
var last_kind := ""
var _sample_left := 0.0
var _kind_trail_t := 0.0
var _easy_was := ""
var _kind_rng := RandomNumberGenerator.new()
var powerups := PowerUpManager.new()
## MULTI BALL (#188): one real capsule, up to three balls on the screen.
##   _virtual_root   ball id on the field -> the real capsule's id (the capsule's own ball too)
##   _multi_balls    real capsule's id -> the ids of its balls still on the field
##   _multi_pending  splits asked for inside a physics callback: made in the next tick
## The real capsule goes back to its Dial when the list of its balls is empty. The list is
## made from the balls that were really put on the field, and checked against the field
## every tick, so a ball that never appeared (or vanished) cannot hold the capsule back.
var _virtual_root: Dictionary = {}
var _multi_balls: Dictionary = {}
var _multi_pending: Array[Dictionary] = []
## game_mode.powerups: the items appear at all / the big notice and the burst on the screen /
## the pickup's sounds (and the music turned down under them) / the Dial's front LED and
## the gold exhibition light / the staff's keys F2 F3 F4 (take one now)
var powerups_on := true
var power_notice := true
var power_sounds := true
var power_lights := true
var power_debug_keys := true
var power_duck_db := -8.0
var power_duck_s := 0.7
## the exhibition light's base mode that was last sent ({} = none of the game's)
var _light_sent: Dictionary = {}
var _light_override := {}  # #277: the light of a capsule's entrance while _light_override_left > 0
var _light_override_left := 0.0
var _light_session := -1  # the hub session _light_sent went to (a new session = send again)
var _light_devices: GameModeDevices = null
## What the screen is while this mode is closed (main.gd sets it every frame): "title" (the
## app's title / mode choice), "study" (the study mode), "" (anything else: the light is left).
var scene_outside := ""
## The shelf's light outside a round. The title: the Illumination's lively IDLE show (many
## colours). Study: the bright desk light (the warm COB tape full, the WS2811 a bright white).
const TITLE_LIGHT := {"mode": "IDLE", "brightness": 200, "speed": 128, "transition_ms": 600}
const STUDY_LIGHT := {"mode": "STUDY", "brightness": 255, "speed": 128, "transition_ms": 800}
## The Illumination's mist (config game_mode.mist): a capsule taken in (the portal opens), the
## result's score settling (FINAL SCORE), the study mode's reward. Seconds of continuous mist;
## the Illumination stops it by itself (and at its own maximum, at STOP_ALL, at a lost hub
## link). 0 = no mist for that one.
var mist_enabled := true
var mist_capsule_s := 3
var mist_result_s := 8
var mist_study_s := 6
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
## how the ranking comes up after a round, and today's best (the flow's own step and timer)
var ranking_flow := GameModeRankingFlow.new(self)
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
## the hand window (#258): 1 = full, 0 = stepped aside (small in the corner, faint) while a
## capsule comes in and plays
var _guide_k := 1.0

# ---- tuning (config game_mode; docs/game_mode_spec.md §5) ----
var duration_s := 150.0
var countdown_s := 3.0
var hurry_s := 30.0
var warning_s := 10.0
var settle_max_s := 30.0
var absorb_s := 1.95  # #258: the collection show
var drop_s := 0.25
var return_s := 0.9
var release_sync_s := 0.6
var release_timeout_s := 8.0
var command_timeout_s := 5.0
var arm_retry_s := 3.0
var verify_retry_s := 0.5
var verify_tries := 4
## #185: after a release the capsule is still in the Dial (its switch stays on for the whole
## check): RELEASE_BALL once more, at most this many times, then FAULT. The Dial accepts a
## second release only while its switch is on (UFO-DeviceHub's Dial firmware from 0.4); an
## older Dial refuses it, which is a FAULT as before. Never after a release whose end was
## not reported (RELEASE_DONE lost): then nobody knows what the servo did.
var release_retries := 2
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
## How the round is played (#169): "easy" = pinch for XY, a fist = catch by itself, one / two
## fingers = carry to Dial 1 / 2; "hard" = the manual hand control. Since #198 nobody chooses:
## it is always easy (no config, no key, no hand shape, no option), and the manual control is
## only what is played where the easy mode cannot be used (easy_block). set_difficulty stays
## for the tests of that manual control. What the hand does with it is the main scene's
## EasyModeControl. This controller still sends nothing to the crane.
var difficulty := "easy"
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
## UFOくん's voice in the practice: the wait for the helper's link, the request, the answer
var tutorial_voice := GameModeTutorialVoice.new(self)
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
	field.configure_powerups(cfg.get("powerups", {}) if cfg.get("powerups") is Dictionary else {})
	layer.add_child(field)
	field.target_hit.connect(_on_target_hit)
	field.capsule_exited.connect(_on_capsule_exited)
	field.powerup_collected.connect(_on_powerup_collected)
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
	tutorial_speech.voice_request = tutorial_voice.request
	tutorial_speech.voice_wait_s = 6.0  # a line VOICEVOX makes for the first time (after that: its cache, #171)
	tutorial.say.connect(tutorial_voice.say)
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
		l.device = int(d.get("device", GameModeDevices.DIAL_1))
		var c = d.get("color")
		l.color = Color8(int(c[0]), int(c[1]), int(c[2])) if c is Array and c.size() == 3 else fx.colors[side]
		fx.colors[side] = l.color
		backdrop.side_colors[side] = l.color
		backdrop.ports[side] = fx.port(side)
		field.wall_colors[0] = l.color  # the wall on the portal's side; the right one keeps its own neon
		lanes[side] = l

func _configure(cfg: Dictionary) -> void:
	duration_s = float(cfg.get("duration_s", duration_s))
	_full_duration_s = duration_s
	var rk: Dictionary = cfg.get("ranking", {}) if cfg.get("ranking") is Dictionary else {}
	ranking_enabled = bool(rk.get("enabled", ranking_enabled))
	rank_hold_s = clampf(float(rk.get("hold_s", rank_hold_s)), 0.0, 20.0)
	rank_record_s = clampf(float(rk.get("record_s", rank_record_s)), 0.0, 20.0)
	board_exit_hold_s = clampf(float(rk.get("exit_hold_s", board_exit_hold_s)), 0.5, 20.0)
	countdown_s = float(cfg.get("countdown_s", countdown_s))
	hurry_s = float(cfg.get("hurry_s", hurry_s))
	warning_s = float(cfg.get("warning_s", warning_s))
	settle_max_s = float(cfg.get("settle_max_s", settle_max_s))
	lights = bool(cfg.get("lights", lights))
	var mc: Dictionary = cfg.get("mist", {}) if cfg.get("mist") is Dictionary else {}
	mist_enabled = bool(mc.get("enabled", mist_enabled))
	mist_capsule_s = clampi(int(mc.get("capsule_s", mist_capsule_s)), 0, 60)
	mist_result_s = clampi(int(mc.get("result_s", mist_result_s)), 0, 60)
	mist_study_s = clampi(int(mc.get("study_s", mist_study_s)), 0, 60)
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
	release_retries = maxi(int(t.get("release_retries", release_retries)), 0)
	if cfg.get("score") is Dictionary:
		score.configure(cfg.score)
	var ck: Dictionary = cfg.get("capsule_kinds", {}) if cfg.get("capsule_kinds") is Dictionary else {}
	kinds.configure(ck)
	kinds_enabled = bool(ck.get("enabled", kinds_enabled))
	mock_kind = str(ck.get("mock_kind", mock_kind))
	colour_reader.memory_s = clampf(float(ck.get("memory_s", colour_reader.memory_s)), 2.0, 120.0)
	var pw: Dictionary = cfg.get("powerups", {}) if cfg.get("powerups") is Dictionary else {}
	powerups.configure(pw)
	powerups_on = bool(pw.get("enabled", powerups_on))
	power_notice = bool(pw.get("notice", power_notice))
	power_sounds = bool(pw.get("sounds", power_sounds))
	power_lights = bool(pw.get("lights", power_lights))
	power_debug_keys = bool(pw.get("debug_keys", power_debug_keys))
	power_duck_db = clampf(float(pw.get("duck_db", power_duck_db)), -40.0, 0.0)
	power_duck_s = clampf(float(pw.get("duck_s", power_duck_s)), 0.0, 5.0)
	_result_bonus_cfg = cfg.get("result_bonus", {}) if cfg.get("result_bonus") is Dictionary else {}
	if cfg.get("result_show") is Dictionary:
		result_show.configure(cfg.result_show)
	_tutorial_cfg = cfg.get("tutorial", {}) if cfg.get("tutorial") is Dictionary else {}
	tutorial_auto = bool(_tutorial_cfg.get("enabled", tutorial_auto))
	# #198: game_mode.difficulty / tutorial.mode of an older config are not read: always easy
	tutorial.configure(_tutorial_cfg)
	tutorial_voice.link_wait_s = clampf(float(_tutorial_cfg.get("voice_link_wait_s", tutorial_voice.link_wait_s)), 0.0, 10.0)
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
## Not reachable by a player or the staff since #198 (see `difficulty`): the tests' way to the
## manual control.
func set_difficulty(d: String) -> void:
	difficulty = "easy" if d == "easy" else "hard"

## The easy mode is what is played: asked for, and usable here.
func easy_on() -> bool:
	return difficulty == "easy" and easy_block == ""

## #183: the game mode's title by hand. An open hand held title_start_hold_s starts (as Enter).
## A shape counts only after the hand was seen in another shape (or not at all) since the
## title came up. (#198: one / two fingers no longer choose a difficulty.)
var title_start_hold_s := 3.0
const TITLE_HAND := {"open": "start"}
var title_hand := ""  # what the hand holds now: "start" / ""
var title_hand_progress := 0.0
var _title_hand_armed := false
var _title_hand_entry := "?"  # the shape seen when the title came up ("?" = not looked yet)

func tick_title_hand(dt: float, hand: Dictionary) -> void:
	if phase != "IDLE" or ranking_view != "":
		title_hand = ""
		title_hand_progress = 0.0
		_title_hand_entry = "?"
		_title_hand_armed = false
		return
	var pose := str(hand.get("pose", "")) if bool(hand.get("fresh", false)) and bool(hand.get("detected", false)) else ""
	if _title_hand_entry == "?":
		_title_hand_entry = pose
	if pose != _title_hand_entry or not TITLE_HAND.has(pose):
		_title_hand_armed = true
		_title_hand_entry = ""
	var what := str(TITLE_HAND.get(pose, "")) if _title_hand_armed else ""
	if what != title_hand:
		title_hand = what
		title_hand_progress = 0.0
	if what == "":
		return
	title_hand_progress = minf(title_hand_progress + dt / maxf(title_start_hold_s, 0.05), 1.0)
	if title_hand_progress < 1.0:
		return
	title_hand = ""
	title_hand_progress = 0.0
	begin()

## #253: the high scores' board by hand: an open hand held board_exit_hold_s goes back to the
## top title (as Esc), so the next player needs no keyboard. As on the title, an open hand
## counts only after the hand was seen in another shape (or not at all) since the board came up.
var board_exit_hold_s := 3.0
var board_hand_progress := 0.0
var _board_hand_armed := false
var _board_hand_entry := "?"
var _board_exit_pending := false

func tick_board_hand(dt: float, hand: Dictionary) -> void:
	if ranking_view != "board" or not _active:
		board_hand_progress = 0.0
		_board_hand_entry = "?"
		_board_hand_armed = false
		return
	var pose := str(hand.get("pose", "")) if bool(hand.get("fresh", false)) and bool(hand.get("detected", false)) else ""
	if _board_hand_entry == "?":
		_board_hand_entry = pose
	if pose != _board_hand_entry or pose != "open":
		_board_hand_armed = true
		_board_hand_entry = ""
	if not _board_hand_armed or pose != "open":
		board_hand_progress = 0.0
		return
	board_hand_progress = minf(board_hand_progress + dt / maxf(board_exit_hold_s, 0.05), 1.0)
	if board_hand_progress < 1.0:
		return
	board_hand_progress = 0.0
	_board_hand_armed = false
	_board_hand_entry = "?"
	_trace("board_exit", null, {"result": "open hand -> title"})
	_board_exit_pending = true  # the next tick goes (show_title closes this mode: not inside its tick)

## #183: the best score of today (GameModeRankingFlow); the title's HUD reads it here.
func today_best() -> int:
	return ranking_flow.today_best()

## The line over START on the title: nothing when the easy mode is played (#198: there is no
## choice to show), or why it is not and what is played instead.
func difficulty_text() -> String:
	if easy_on():
		return ""
	return (easy_block + "\n" if easy_block != "" else "") + "→ てで ぜんぶ そうさして あそぶ"

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
	# every visit needs a fresh hand shape (the title's is not ticked while the screen is closed)
	title_hand = ""
	title_hand_progress = 0.0
	_title_hand_armed = false
	_title_hand_entry = "?"
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
	ranking_flow.flush()
	_active = false
	sounds.set_bgm(false)
	sounds.ending_on = false
	field.clear()
	_clear_powerups()
	fx.reset()
	_clear_result()
	ranking_flow.clear_view()
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
	var hw := tutorial_voice.client()
	if hw != null and hw.has_method("_ensure_link"):
		hw._ensure_link()  # the voice comes over the helper's link (it may be off until now)
	tutorial_mode = "easy" if easy_on() else "hard"  # the practice shows what the round will be
	tutorial.begin(GestureTutorialSteps.resolve(_tutorial_cfg, tutorial_mode, scheme_id, claw), hand_on or demo)
	_trace("tutorial_start", null, {"result": tutorial_mode})

func _end_tutorial() -> void:
	tutorial.cancel()
	tutorial_voice.pending = []
	tutorial_speech.clear()
	practice = ""

## The practice capsule: the Dial is prepared and armed as in a round; the clock stays.
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
	# the claw first, then the carry (#266: one step shows both; the main scene sends the carry
	# only once the claw's request is answered, review on #268)
	if bool(step.get("claw_demo", false)):
		_demo_claw_closed = true
		tutorial_claw.emit("closed")
	if int(step.get("goto_demo", 0)) == 1:
		tutorial_goto.emit(int(step.goto_demo))
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
	_sync_light()
	_trace("game_start", null, {})

func _reset_round() -> void:
	_light_override_left = 0.0
	ranking_flow.flush()
	score.reset()
	_clear_powerups()
	capsules.reset()
	ufo.reset()
	field.clear()
	field.set_frozen(false)
	fx.reset()
	particles.clear()
	_clear_result()
	ranking_flow.clear_view()
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
		l.re_releases = 0

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
	if _board_exit_pending:  # #253: the open hand's hold on the board ended in the last tick
		_board_exit_pending = false
		if main != null and main.has_method("show_title"):
			main.show_title()  # as Esc: this mode is closed, nothing more of it this tick
			return
	devices.tick(dt)
	_expire_commands(dt)
	fx.advance(dt)
	particles.advance(dt)
	_read_colours(dt)
	_kind_particles(dt)
	result_screen.advance(dt)
	ranking_hud.advance(dt)
	result_show.advance(dt)  # the result's timeline: its cues come out of this, in this tick
	ranking_flow.tick(dt)
	backdrop.advance(dt)
	if phase in ["PLAYING", "SETTLING"]:
		powerups.advance(dt)
		_apply_multiball()
		_watch_multiball()
	score.power_multiplier = 2.0 if powerups.active("double") else 1.0
	fx.power_status.clear()
	if powerups.active("speed"):
		fx.power_status.append("SPD %dS" % powerups.seconds("speed"))
	if powerups.active("double"):
		fx.power_status.append("x2 %dS" % powerups.seconds("double"))
	if not _multi_balls.is_empty():
		var balls := 0
		for live in _multi_balls.values():
			balls += (live as Array).size()
		fx.power_status.append("MULTI %d BALL" % balls)
	if _light_override_left > 0.0:
		_light_override_left = maxf(_light_override_left - dt, 0.0)
	_sync_light()  # a power that ended, the last stretch: the light follows the state
	# #258: the hand window steps aside (small in the corner, faint) while a capsule comes in and plays
	_guide_k = move_toward(_guide_k, 0.0 if capsule_in_play() else 1.0, dt * 4.0)
	# #258: UFOくん waits where it is while a capsule is collected and dropped from it
	if phase != "STOPPED" and not capsule_arriving():
		ufo.advance(dt)
	fx.ufo_pos = ufo.position()
	fx.ufo_visible = phase != "IDLE"  # on the title screen the UFO is the big one in the middle
	var menu_hand: Dictionary = main.hand_for_menus() if main != null and main.has_method("hand_for_menus") and not demo else {}
	tick_title_hand(dt, menu_hand)
	tick_board_hand(dt, menu_hand)
	match phase:
		"TUTORIAL":
			if practice != "":
				clock += dt  # the practice capsule's own time (combos); the 150 s clock stands still
				_tick_practice()
				if demo and practice == "open" and devices.can_mock_ball() and tutorial.t > 2.0 and not practice_busy() \
						and lanes["left"].state == "READY":
					_mock_ball("left")  # the rehearsal puts the practice capsule in by itself
			tutorial_voice.tick(dt)
			_tick_gauge_sound(dt)
			tutorial.tick(dt, _hand_snapshot(), {"speech_busy": tutorial_speech.busy() or not tutorial_voice.pending.is_empty(), "practice": practice,
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
	field.set_powerups_enabled(powerups_on)
	fx.react("start")
	particles.burst(ufo.position(), Color("ffe03c"), 24, 260.0)
	particles.ring(ufo.position(), Color("3ff0ff"), 110.0, 0.5)
	sounds.play("go")
	sounds.set_bgm(true)
	_sync_light()
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
		devices.mock_ball(lanes["left"].device)

func _clock_cues() -> void:
	if not _hurry_done and time_left <= hurry_s:
		_hurry_done = true
		fx.react("hurry")
		sounds.play("hurry")
		sounds.set_bgm(true, true)
		backdrop.pulse(Color("ff4fd8"), 0.8)
		_sync_light()  # the faster rainbow, or still the gold of a DOUBLE SCORE
		_trace("hurry", null, {})
	var s := int(ceil(time_left))
	if time_left <= warning_s and s < _warned_at and s > 0:
		_warned_at = s
		sounds.play("warning")

## 0 s: nothing new is taken. Capsules in play finish (their score counts) and go out.
func _time_up() -> void:
	_set_phase("SETTLING")
	field.set_powerups_enabled(false)
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
	_clear_powerups()
	sounds.set_bgm(false)
	sounds.ending_on = true  # the result's music (#173), until the next round or the title
	for side in SIDES:
		var l: Lane = lanes[side]
		if l.state == "CLOSED":  # a faulted Dial is left as it is for a person to look at
			_led(l, "CLEAR")
			_send(l, "standby", "SET_MODE", {"mode": "STANDBY"})
	_sync_light()
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
			mist_burst(mist_result_s)  # the score is settled: the shelf fills with mist
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
				mist_burst(mist_result_s)  # the score settled without its show: the mist all the same

## Paper falls from the top of the screen in the three neon colours.
func _confetti(bursts: int) -> void:
	var cols := [Color("ffe03c"), Color("3ff0ff"), Color("ff4fd8")]
	for i in bursts:
		result_screen.particles.burst(Vector2(_rng.randf_range(60.0, GameModeLayout.SCREEN.x - 60.0), _rng.randf_range(-10.0, 160.0)),
			cols[(i + _rng.randi()) % 3], 14, 300.0, PI * 0.5, PI * 0.9, 0.15)

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
			var before := l.t
			l.t -= dt
			# #266: the capsule comes up big (the show's "show" part): its sound
			var reveal_at := absorb_s * (1.0 - GameModeVFX.COLLECT_RISE)
			if before > reveal_at and l.t <= reveal_at:
				var rk := str(l.capsule.get("kind", "normal"))
				sounds.play("reveal" if rk == "normal" else "reveal_" + rk)
				_capsule_light(l, l.t + drop_s)  # #277: the shelf in the capsule's colour
			# #277: UFOくん shines (the show's "light" part): the shelf flashes with it
			var shine_at := absorb_s * (1.0 - GameModeVFX.COLLECT_UP)
			if before > shine_at and l.t <= shine_at:
				_light("TRIGGER_EFFECT", {"effect": "SCORE", "duration_ms": int(shine_at * 1000.0) + 200, "intensity": 255})
			if l.t <= 0.0:
				l.t = drop_s
				_set_lane(l, "DROPPING")
				fx.collect_kind = str(l.capsule.get("kind", "normal"))
				fx.play("capsule_materialize", l.side, Vector2(l.capsule.drop_x, PinballField.SPAWN_Y), drop_s)
				fx.react("drop")
				particles.burst(Vector2(l.capsule.drop_x, PinballField.SPAWN_Y), capsule_color(l), 10, 180.0, PI * 0.5, 1.4)
				sounds.play("drop")
		"DROPPING":
			l.t -= dt
			if l.t <= 0.0:
				var kind := str(l.capsule.get("kind", "normal"))
				field.spawn_capsule(l.capsule.capsule_id, l.capsule.drop_x, capsule_color(l), kind, kinds.of(kind))
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

# ------------------------------------------------------------------ the capsule kinds (#266)
## The colour of the capsule a lane has: its kind's, or the Dial's for a normal one.
func capsule_color(l: Lane) -> Color:
	return CapsuleKinds.color_of(str(l.capsule.get("kind", "normal")), l.color) if not l.capsule.is_empty() else l.color

## The kind of the capsule taken in now: what the arm camera's frames said; with no camera
## and mock Dials, mock_kind (so the rehearsal shows the kinds). Off: always normal.
func decide_kind() -> String:
	if not kinds_enabled:
		return "normal"
	var k := colour_reader.decide(int(kinds.read.min_votes), float(kinds.read.min_ratio))
	if k == "normal" and colour_reader.count() == 0 and not _camera_live() and devices.can_mock_ball():
		if mock_kind == "random":
			return ["fire", "water", "green"][_kind_rng.randi() % 3]
		if CapsuleKinds.known(mock_kind):
			return mock_kind
	return k

## The arm camera shows a real picture (not the static of no camera).
func _camera_live() -> bool:
	if colour_source.is_valid():
		return true
	var cams = main.get("cameras") if main != null else null
	return cams != null and (cams.has_feed("focus") or cams.external_live("focus"))

## A capsule may hang in front of the arm camera now: the easy mode's catch coming up and
## its carry (a new catch starts the votes over); by hand, all the time the Dials take one.
func _reading_colours() -> bool:
	if not kinds_enabled or not _active or not _taking():
		return false
	var e = main.get("easy") if main != null else null
	if easy_on() and e != null:
		if e.state == "AUTO_GRAB":
			return e.step in ["CLOSE_CLAW", "RAISE_WITH_ITEM"]
		return e.state in ["WAIT_DESTINATION", "DELIVER_DIAL_1"]
	return true

func _read_colours(dt: float) -> void:
	colour_reader.advance(dt)
	var e = main.get("easy") if main != null else null
	var es: String = str(e.state) if e != null else ""
	if es == "AUTO_GRAB" and _easy_was != "AUTO_GRAB":
		colour_reader.clear()  # a new catch: what was seen before is not this capsule
	_easy_was = es
	if not _reading_colours():
		_sample_left = 0.0
		return
	_sample_left -= dt
	if _sample_left > 0.0:
		return
	_sample_left = 1.0 / maxf(float(kinds.read.sample_hz), 0.5)
	var img := _colour_frame()
	if img != null:
		colour_reader.add(str(CapsuleKinds.classify(img, kinds.read).kind))

## One frame of the arm camera (null: none, or a headless run where nothing is drawn).
func _colour_frame() -> Image:
	if colour_source.is_valid():
		return colour_source.call()
	if DisplayServer.get_name() == "headless" or not _camera_live():
		return null
	var tex: Texture2D = main.cameras.texture("focus")
	return tex.get_image() if tex != null else null

## The kinds' particles on the field: a few for each capsule of a kind, every few frames.
func _kind_particles(dt: float) -> void:
	_kind_trail_t -= dt
	if _kind_trail_t > 0.0 or not effects:
		return
	_kind_trail_t = 0.06
	for id in field.capsule_ids():
		var k := field.capsule_kind(id)
		if k != "normal" and not field.capsule_held(id):
			particles.kind_trail(k, field.capsule_position(id))

## A capsule is on its way in (the collection show, the drop from UFOくん): the UFO waits.
func capsule_arriving() -> bool:
	return lanes.values().any(func(l): return l.state in ["ABSORBING", "DROPPING"])

## A capsule comes in or is on the field: the hand window turns faint (#258).
func capsule_in_play() -> bool:
	return lanes.values().any(func(l): return l.state in ["ABSORBING", "DROPPING", "SIMULATING"])

## #258: the hand window shows while the round is played (the countdown, the round, the
## settling) and with the practice capsule (a banner over the field). Not on the score game's
## title and result / ranking screens (its corner would cover their cards and lines), nor in
## the practice's steps (they show the hand camera beside their hand pictures).
func guide_hidden() -> bool:
	if phase == "TUTORIAL":
		return practice == ""
	return not (phase in ["COUNTDOWN", "PLAYING", "SETTLING"]) or ranking_view != ""

## How much of the hand window shows now (1 = all; GUIDE_FAINT while a capsule plays).
func guide_alpha() -> float:
	return lerpf(GameModeLayout.GUIDE_FAINT, 1.0, _guide_k)

## How big the hand window is now (1; GUIDE_SMALL in the bottom right corner while a capsule plays).
func guide_scale() -> float:
	var e := _guide_k * _guide_k * (3.0 - 2.0 * _guide_k)
	return lerpf(GameModeLayout.GUIDE_SMALL, 1.0, e)

## A capsule is taken in: the drop point is where the UFO is now, and it never changes (the
## UFO waits there until the capsule is dropped, #258).
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
	# #266: what the arm camera saw of it: its kind (normal when nothing sure)
	c.kind = decide_kind()
	last_kind = c.kind
	colour_reader.clear()
	_trace("capsule_kind", l, {"effect_id": c.kind})
	l.t = absorb_s
	_set_lane(l, "ABSORBING")
	mist_burst(mist_capsule_s)  # the portal opens in a cloud
	backdrop.side_pulse(l.side)
	fx.react("call")
	fx.play("capsule_portal_open", l.side, Vector2.ZERO, absorb_s)
	fx.play("capsule_absorb", l.side, Vector2.ZERO, absorb_s)
	# #258: up from the port, big in the middle (カプセル回収！), up into UFOくん, its light
	fx.collect_kind = c.kind
	fx.play("capsule_collect", l.side, Vector2(c.drop_x, PinballField.SPAWN_Y), absorb_s)
	sounds.play("absorb")
	_led(l, "INTAKE")
	_light("TRIGGER_EFFECT", {"effect": "BALL_RECEIVED", "duration_ms": 800, "intensity": 200})

## One real capsule may own three virtual balls. Each virtual ID gets its own hit
## cooldown, but all score goes to the same physical capsule's result.
## Acquire a visible pickup. The field guarantees one pickup per spawned item;
## this controller guarantees one physical Dial cycle even with 3 virtual balls.
func _on_powerup_collected(capsule_id: String, kind: String, pos: Vector2) -> void:
	if capsules.get_capsule(str(_virtual_root.get(capsule_id, capsule_id))) != null:
		_collect_powerup(capsule_id, kind, pos)

## The staff's "take this one now" (F2 SPEED UP / F3 MULTI BALL / F4 DOUBLE SCORE, and the
## tests): the same path as a ball touching the item. MULTI BALL needs a ball on the field.
func force_powerup(kind: String) -> bool:
	if phase != "PLAYING" or not kind in PowerUpManager.KINDS:
		return false
	var ball := ""
	for side in SIDES:
		var l: Lane = lanes[side]
		if l.state != "SIMULATING" or l.capsule.is_empty():
			continue
		var root := str(l.capsule.capsule_id)
		if kind == "multiball" and (_multi_balls.has(root) or _multi_asked(root) or not field.has_capsule(root)):
			continue
		ball = root
		break
	if kind == "multiball" and ball == "":
		return false
	var pos := field.capsule_position(ball) if ball != "" and field.has_capsule(ball) \
		else Vector2(GameModeLayout.CX, PinballField.STAR.y - 200.0)
	_collect_powerup(ball, kind, pos)
	return true

func _multi_asked(root_id: String) -> bool:
	return _multi_pending.any(func(p): return str(p.root) == root_id)

func _collect_powerup(capsule_id: String, kind: String, pos: Vector2) -> void:
	if phase != "PLAYING":
		return
	var root_id := str(_virtual_root.get(capsule_id, capsule_id))
	var cap = capsules.get_capsule(root_id)
	var l: Lane = _lane_of(cap.source_dial) if cap != null else null
	if kind == "multiball" and (l == null or l.state != "SIMULATING" or _multi_balls.has(root_id) or _multi_asked(root_id)):
		return
	if not powerups.collect(kind):
		return
	if power_notice:
		fx.powerup_notice(kind)
		particles.burst(pos, Color("ffe03c"), 32, 380.0)
		particles.ring(pos, Color("3ff0ff"), 120.0, 0.5)
		backdrop.pulse(Color("ffe03c"), 0.9)
		_shake(0.5)
	if power_lights:  # the shelf flashes with the screen's pickup
		_light("TRIGGER_EFFECT", {"effect": "CATCH", "duration_ms": 600, "intensity": 230})
	if power_sounds:
		sounds.play({"speed": "power_speed", "multiball": "power_multi", "double": "power_double"}[kind])
		sounds.duck(power_duck_s, power_duck_db)  # the tune steps back under the pickup's sound
	match kind:
		"multiball":
			# Bodies are never added inside a physics callback (the item's Area2D reports
			# from one): the split is made in the next tick, from the ball that is there then.
			_multi_pending.append({"ball": capsule_id, "root": root_id})
			if not Engine.is_in_physics_frame():
				_apply_multiball()
		"double":
			score.power_multiplier = 2.0
			_sync_light()  # gold, until it ends
		"speed":
			pass  # main.gd reads the timer: the hand's and the keys' XY speed, the backend's jog_boost
	_trace("powerup", l, {"effect_id": kind, "physics_position": [pos.x, pos.y]})

## The splits asked for: two more balls beside the one that took the item, if that ball is
## still on the field and its capsule still in play. What is listed is what was really made.
func _apply_multiball() -> void:
	if _multi_pending.is_empty():
		return
	var todo := _multi_pending.duplicate()
	_multi_pending.clear()
	for p in todo:
		var root_id := str(p.root)
		var ball := str(p.ball)
		var cap = capsules.get_capsule(root_id)
		var l: Lane = _lane_of(cap.source_dial) if cap != null else null
		if l == null or l.state != "SIMULATING" or l.capsule.is_empty() or str(l.capsule.capsule_id) != root_id \
				or _multi_balls.has(root_id) or not field.has_capsule(ball):
			_trace("multiball_skipped", l, {})  # the ball left first: nothing to wait for
			continue
		var made: Array[String] = field.split_capsule(ball, [root_id + "-mb1", root_id + "-mb2"])
		if made.is_empty():
			continue
		var live: Array[String] = [ball]
		live.append_array(made)
		_multi_balls[root_id] = live
		for id in live:
			_virtual_root[id] = root_id
		fx.set_power_portal(l.side, true)
		if power_lights:
			_led(l, "MULTI_BALL")

## A MULTI BALL whose balls are not on the field any more (none of them reported leaving)
## still ends: the capsule goes back to its Dial instead of waiting for ever.
func _watch_multiball() -> void:
	for root_id in _multi_balls.keys():
		var live: Array = _multi_balls[root_id]
		for id in live.duplicate():
			if not field.has_capsule(str(id)):
				live.erase(id)
				_virtual_root.erase(id)
		if not live.is_empty():
			continue
		var cap = capsules.get_capsule(str(root_id))
		var l: Lane = _lane_of(cap.source_dial) if cap != null else null
		_end_multiball(str(root_id), l)
		if l != null and l.state == "SIMULATING" and not l.capsule.is_empty() and str(l.capsule.capsule_id) == str(root_id):
			_trace("multiball_lost", l, {})
			_begin_return(l, PinballField.STAR)

func _end_multiball(root_id: String, l: Lane) -> void:
	_multi_balls.erase(root_id)
	for id in _virtual_root.keys():
		if str(_virtual_root[id]) == root_id:
			_virtual_root.erase(id)
	if l != null:
		fx.set_power_portal(l.side, false)

## Every power ends here: the round's end, a stop, the title.
func _clear_powerups() -> void:
	powerups.reset()
	_virtual_root.clear()
	_multi_balls.clear()
	_multi_pending.clear()
	score.power_multiplier = 1.0
	if fx != null:
		fx.power_status.clear()
		for side in SIDES:
			fx.set_power_portal(side, false)

func _on_target_hit(capsule_id: String, kind: String, target: String, pos: Vector2) -> void:
	var root_id := str(_virtual_root.get(capsule_id, capsule_id))
	var c = capsules.get_capsule(root_id)
	if c == null or not running():
		return
	var ck := str(c.get("kind", "normal"))
	var r := score.hit(capsule_id, kind, target, clock, float(kinds.of(ck).hit_k))  # #266: the kind's hits
	if int(r.points) <= 0:
		return
	if ck != "normal" and kind in ["bumper", "pop", "sling", "spinner", "target"]:
		particles.kind_hit(ck, pos)
	c.score += int(r.points)
	field.flash_capsule(capsule_id)
	var l: Lane = _lane_of(c.source_dial)
	_present_score(r, pos, l)
	_trace("score", l, {"score_delta": r.points, "effect_id": kind, "physics_position": [pos.x, pos.y]})

func _on_capsule_exited(capsule_id: String, goal: String, pos: Vector2) -> void:
	var root_id := str(_virtual_root.get(capsule_id, capsule_id))
	var c = capsules.get_capsule(root_id)
	if c == null:
		return
	var l: Lane = _lane_of(c.source_dial)
	if l == null or l.state != "SIMULATING":
		return
	c.goal = goal
	if goal != "timeout":
		var r := score.goal(capsule_id, goal, clock, float(kinds.of(str(c.get("kind", "normal"))).goal_k))  # #266
		if int(r.points) > 0:
			c.score += int(r.points)
			_present_score(r, pos, l)
			_trace("score", l, {"score_delta": r.points, "effect_id": r.kind, "physics_position": [pos.x, pos.y]})
	else:
		_trace("stay_timeout", l, {"physics_position": [pos.x, pos.y]})
		fx.react("miss")  # it ran out of time on the field: no goal
	field.remove_capsule(capsule_id)
	score.forget(capsule_id)
	if _multi_balls.has(root_id):
		var live: Array = _multi_balls[root_id]
		live.erase(capsule_id)
		_virtual_root.erase(capsule_id)
		if not live.is_empty():
			return  # the real Dial still holds its one capsule
		_end_multiball(root_id, l)
	_begin_return(l, pos)

## The capsule's time on the field is over (its last ball left): back to its Dial.
func _begin_return(l: Lane, pos: Vector2) -> void:
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

## The initial RELEASE_BALL for this capsule. A later release is permitted only after
## RELEASE_DONE and a positive switch-on verification (#185). Not sent when the hub's session changed since the
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
	l.re_releases = 0
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
		var root := str(l.capsule.capsule_id)
		capsules.finish(root, "failed")
		field.remove_capsule(root)
		# A physical Dial failure ends every virtual ball of that capsule.
		for vid in _virtual_root.keys():
			if str(_virtual_root[vid]) == root:
				field.remove_capsule(str(vid))
		_end_multiball(root, l)
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
			elif l.state == "RELEASING" and l.re_releases > 0 and result == "REJECTED_STATE":
				_fault(l, "カプセルが Dial から出ていない。もういちどの排出を Dial が受け付けない（Dial のファームウェアが古い）")
			elif l.state == "RELEASING":
				_fault(l, "排出の命令が通らなかった（%s）" % result)
		"status":
			if l.state != "VERIFYING":
				return
			var st: Dictionary = data.get("status", {}) if data.get("status") is Dictionary else {}
			var ds := str(st.get("dial_state", st.get("state", "")))
			var still_in := bool(st.get("switch_on", false))
			_trace("verify", l, {"result": "%s switch_on=%s" % [ds if ok else result, still_in]})  # what the Dial said (#185)
			if ok and ds in ["COMPLETE", "READY"] and not bool(st.get("switch_on", false)):
				_released(l)
			else:
				l.verify_tries -= 1
				if l.verify_tries <= 0 and ok and still_in and not l.release_timed_out and l.re_releases < release_retries \
						and not l.capsule.is_empty():
					# the capsule is still in the Dial: the release once more (#185)
					l.re_releases += 1
					l.release_cid = 0
					_trace("release", l, {"release_status": "again %d/%d" % [l.re_releases, release_retries]})
					_release(l)
				elif l.verify_tries <= 0:
					_fault(l, ("RELEASE_DONE が来ない（排出できたか分からない。Dial: %s）" if l.release_timed_out
						else ("排出のあと、カプセルが Dial から出ていない（スイッチが ON のまま。Dial: %s）" if ok and still_in
						else "排出のあと、Dial が次の準備にならない（%s）")) % (ds if ok else result))
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
	if not name in ["BALL_RECEIVED", "RELEASE_STARTED", "RELEASE_DONE", "RELEASE_FAILED"]:
		return
	if l == null:
		# not a Dial of the game (#200: Dial 2 may still be plugged in). Nothing is played and
		# nothing is sent to it; the trace says so, so that a capsule left in it can be found.
		_trace("event_ignored", null, {"effect_id": name, "result": "not_a_game_dial", "source_dial": ev.get("source")})
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
	_light_override_left = 0.0  # #277: a stop ends a capsule's light too
	_demo_claw_closed = false  # a stop: nothing more is asked of the claw
	devices.stop_all()
	_cmds.clear()
	_end_tutorial()
	field.set_powerups_enabled(false)
	_clear_powerups()
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
			elif phase == "RESULT" and ranking_enabled and ranking_flow.state != "done":
				# the final score, or NEW RECORD!, is still up: on to the board (the score is
				# offered to the ranking first if it was not yet); Enter on the board plays
				if ranking_flow.state == "":
					ranking_flow.tick(0.0)
				ranking_flow.show_board()
			elif not running():
				begin()
			return true
		KEY_T:
			if not running():
				start_tutorial()
				return true
			return false
		KEY_R:
			if phase == "IDLE" and ranking_enabled:
				ranking_flow.toggle()
				return true
			return false
		KEY_F2, KEY_F3, KEY_F4:
			# the staff's / the developer's: take that power now (#188)
			if not power_debug_keys or phase != "PLAYING":
				return false
			force_powerup({KEY_F2: "speed", KEY_F3: "multiball", KEY_F4: "double"}[keycode])
			return true
		KEY_Z:
			return _mock_ball("left")
	return false

## The staff's steps of the practice (#260: StaffControl; F6 = "next" on to the next step,
## F7 = "all" the practice left out, Shift+F6 = "retry" this step again). A capsule on its way
## through the practice is never left behind: next / all wait until it is back. Dials waiting
## for the practice capsule are disarmed before the round's countdown (nothing is taken then).
func staff_step(kind: String) -> bool:
	if phase != "TUTORIAL":
		return false
	if practice_busy():
		tutorial.guide = "カプセルが もどるまで まってね"
		return true
	match kind:
		"retry":
			tutorial.retry_step()
		"next", "all":
			if practice == "open":
				# the Dials are waiting for a capsule: they are closed first (a capsule that lands
				# meanwhile goes straight back out), and only then does the round start
				_practice_skip = true
				_practice_close()
				tutorial.guide = "ポータルを とじているよ…"
			elif practice == "closing":
				pass  # already on its way
			elif kind == "next" and tutorial.kind() != "practice":
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
func _light(name: String, params: Dictionary) -> bool:
	if not lights:
		return false
	return _illumination(name, params)

func _illumination(name: String, params: Dictionary) -> bool:
	if not devices.available():
		return false
	var rid := devices.command(GameModeDevices.ILLUMINATION, name, params)
	_cmds[rid] = {"lane": null, "what": "light", "left": command_timeout_s}
	return true

## The exhibition light's base mode is a function of the game's state, and of nothing else:
## which phase, whether it is the last stretch, whether a DOUBLE SCORE runs. Nothing
## remembers "what to go back to": when the gold ends in the last 30 s the answer is the
## fast rainbow, because that is what the state says. {} = not the game's to set.
static func light_mode_for(phase_now: String, last_stretch: bool, gold: bool) -> Dictionary:
	match phase_now:
		"IDLE":  # the score game's own title
			return TITLE_LIGHT
		"COUNTDOWN":
			return {"mode": "GAME_READY", "brightness": 160, "speed": 128, "transition_ms": 300}
		"PLAYING", "SETTLING":
			if gold:
				return {"mode": "CUSTOM", "color": [255, 174, 32], "brightness": 190, "speed": 190, "transition_ms": 250}
			if last_stretch:
				return {"mode": "GAME_PLAY", "brightness": 220, "speed": 230, "transition_ms": 200}
			return {"mode": "GAME_PLAY", "brightness": 180, "speed": 128, "transition_ms": 300}
		"RESULT":
			return {"mode": "RESULT", "brightness": 180, "speed": 128, "transition_ms": 500}
	return {}

func light_mode() -> Dictionary:
	if not _active:
		return light_scene_for(scene_outside)
	if _light_override_left > 0.0 and not _light_override.is_empty():
		return _light_override  # #277: a capsule's entrance
	return light_mode_for(phase, phase in ["PLAYING", "SETTLING"] and time_left <= hurry_s,
		power_lights and powerups.active("double"))

## The light of a screen outside the score game ({} = not the game's to set).
static func light_scene_for(scene: String) -> Dictionary:
	match scene:
		"title":
			return TITLE_LIGHT
		"study":
			return STUDY_LIGHT
	return {}

## The mist for `seconds` (the result here; main.gd: the study mode's reward). Decoration like
## the lights: sent and forgotten, never waited for. false = not sent (off, 0 s, no hub).
func mist_burst(seconds: int) -> bool:
	if not mist_enabled or seconds <= 0:
		return false
	if not _active:
		use_devices(devices_wanted)
	return _illumination("SET_MIST", {"pattern": "CONTINUOUS", "duration_s": seconds})

## While this mode is closed (main.gd, every frame): the title's and the study mode's light.
## Nothing else of the mode runs; the answers to the light commands still time out here.
func lights_tick(dt: float) -> void:
	if _active:
		return
	use_devices(devices_wanted)
	devices.tick(dt)
	_expire_commands(dt)
	_sync_light()

## The one place SET_LIGHT_MODE is sent from: when what the state asks for is not what was
## last sent. Called at every change of phase and once a tick. Best effort, like all lights.
## A new hub session (the Illumination went back to its own light) or another hub (mock /
## backend) sends it again.
## #277: the shelf in the colour of the capsule coming in, for `secs` (to the end of its drop),
## then the round's light again (light_mode() goes back by itself). Decoration, like all lights.
func _capsule_light(l: Lane, secs: float) -> void:
	var c := capsule_color(l)
	_light_override = {"mode": "CUSTOM", "brightness": 255, "speed": 200, "transition_ms": 120,
		"color": [int(round(c.r * 255.0)), int(round(c.g * 255.0)), int(round(c.b * 255.0))]}
	_light_override_left = maxf(secs, 0.1)
	_sync_light()

func _sync_light() -> void:
	if devices != _light_devices or devices.session_id() != _light_session:
		_light_devices = devices
		_light_session = devices.session_id()
		_light_sent = {}
	var want := light_mode()
	if want.is_empty():
		_light_sent = {}
		return
	if want == _light_sent:
		return
	if _light("SET_LIGHT_MODE", want.duplicate(true)):
		_light_sent = want

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

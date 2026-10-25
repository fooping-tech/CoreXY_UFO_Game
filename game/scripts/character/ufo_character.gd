class_name UfoCharacter
extends Node2D
## The blue UFO. Pure presentation: it is told where its rope attachment point
## is on screen, how the rope end is tilted and how fast it moves, and it picks
## expressions/poses from that plus the game mood. It never influences physics.
##
## Node origin == rope attachment point, so rotating this node swings the body
## around the knot. If the sprite sheets are missing it draws a placeholder.

const META_PATH := "res://assets/ufo/ufo_metadata.json"
## Sheets that are played whole as one looping animation.
const SHEET_ANIMATIONS := ["idle", "telescope"]

## Game-level mood (set by the main scene from GameState). One of:
## IDLE, MOVING_XY, MOVING_FORWARD, MOVING_BACKWARD, Z_LOWERING, Z_RAISING,
## GRABBING, SUCCESS, FAILURE, ERROR, DISCONNECTED
var mood: String = "IDLE":
	set(v):
		if v != mood:
			mood = v
			_on_mood_changed()
## Pixel scale (1 sprite pixel = pixel_scale screen pixels).
var pixel_scale: float = 3.0:
	set(v):
		pixel_scale = v
		_apply_frame()
## How much the body tilts with the rope end (1 = exactly follows the rope).
var tilt_follow: float = 0.85
## Extra tilt from lateral velocity (radians per screen-px/s).
var tilt_from_velocity: float = 0.0004
var max_tilt_deg: float = 35.0
## Accelerations above this (screen px/s^2) trigger the panic pose.
var panic_accel_threshold: float = 2600.0
var manual_expression: String = "" # debug override, "" = automatic
## Peering through the spyglass while the scope view is up (set by the main scene).
var peering := false
## Look through it to the left (the telescope frames are mirrored).
var peer_left := false:
	set(v):
		if v != peer_left:
			peer_left = v
			_apply_frame()
## Draw the `action_effects` overlay (speed lines, sweat...) on top of action
## poses. The pose art itself is character-only.
var show_pose_effects: bool = true:
	set(v):
		show_pose_effects = v
		_apply_frame()

var _meta: Dictionary = {}
var _textures: Dictionary = {}  # sheet name -> Texture2D
var _frame_size := Vector2i(64, 64)
var _default_attach := Vector2(32, 5)
var _sprite: Sprite2D
var _fx_sprite: Sprite2D
var _has_assets := false
var _current_sheet := ""
var _current_frame := 0
var _anim_frames: Array = []
var _anim_fps := 0.0
var _anim_loop := false
var _anim_time := 0.0
var _anim_done := false
var _blink_timer := 2.0
var _blink_left := 0.0
var _panic_left := 0.0
var _panic_dir := 1
var _tilt := 0.0
var _depth_scale := 1.0
var _lateral_vel := 0.0
var _depth_vel := 0.0
var _bob_phase := 0.0
var _last_expr_shown := ""

func _ready() -> void:
	_sprite = Sprite2D.new()
	_sprite.name = "Body"
	_sprite.centered = false
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_sprite)
	_fx_sprite = Sprite2D.new()
	_fx_sprite.name = "PoseEffects"
	_fx_sprite.centered = false
	_fx_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_fx_sprite.region_enabled = true
	_fx_sprite.visible = false
	add_child(_fx_sprite)
	_load_meta()
	_set_expression("normal")

func _load_meta() -> void:
	if not FileAccess.file_exists(META_PATH):
		push_warning("UFO metadata missing; using placeholder drawing")
		return
	var f := FileAccess.open(META_PATH, FileAccess.READ)
	var parsed = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return
	_meta = parsed
	_frame_size = Vector2i(int(_meta.frame_size.width), int(_meta.frame_size.height))
	_default_attach = Vector2(float(_meta.rope_attachment_local.x), float(_meta.rope_attachment_local.y))
	var any := false
	for sheet_name in _meta.sheets.keys():
		var path: String = _meta.sheets[sheet_name].file
		if ResourceLoader.exists(path):
			_textures[sheet_name] = load(path)
			any = true
	_has_assets = any
	if _has_assets:
		_sprite.visible = true
	else:
		push_warning("UFO sprite sheets missing; using placeholder drawing")

# ------------------------------------------------------------ frame lookup
func _frame_rect(sheet: String, index: int) -> Rect2:
	var s: Dictionary = _meta.sheets[sheet]
	var entries: Array = s.get("frames", s.get("layout", []))
	for e in entries:
		if int(e.index) == index:
			return Rect2(float(e.x), float(e.y), _frame_size.x, _frame_size.y)
	var cols := int(s.columns)
	return Rect2(float((index % cols) * _frame_size.x), float((index / cols) * _frame_size.y), _frame_size.x, _frame_size.y)

func _frame_attach(sheet: String, index: int) -> Vector2:
	if _meta.is_empty():
		return _default_attach
	var s: Dictionary = _meta.sheets[sheet]
	for e in s.get("frames", []):
		if int(e.index) == index and e.has("rope_attachment_local"):
			return Vector2(float(e.rope_attachment_local.x), float(e.rope_attachment_local.y))
	return _default_attach

func _find_named(sheet: String, name: String) -> int:
	if not _meta.has("sheets") or not _meta.sheets.has(sheet):
		return -1
	for e in _meta.sheets[sheet].get("frames", []):
		if e.get("name", e.get("expression", "")) == name:
			return int(e.index)
	return -1

func _show(sheet: String, index: int) -> void:
	_current_sheet = sheet
	_current_frame = index
	_apply_frame()

func _apply_frame() -> void:
	if not _has_assets or _current_sheet == "" or not _textures.has(_current_sheet):
		if _fx_sprite != null:
			_fx_sprite.visible = false
		queue_redraw()
		return
	_sprite.texture = _textures[_current_sheet]
	_sprite.region_enabled = true
	_sprite.region_rect = _frame_rect(_current_sheet, _current_frame)
	_sprite.scale = Vector2.ONE * pixel_scale
	var attach := _frame_attach(_current_sheet, _current_frame)
	_sprite.flip_h = peer_left and _current_sheet == "telescope"
	if _sprite.flip_h:
		attach.x = _frame_size.x - attach.x
	_sprite.position = -attach * pixel_scale
	# action_effects cells line up 1:1 with action_poses cells, so the overlay
	# reuses the pose's frame index and attachment offset.
	var fx := show_pose_effects and _current_sheet == "action_poses" and _textures.has("action_effects")
	_fx_sprite.visible = fx
	if fx:
		_fx_sprite.texture = _textures["action_effects"]
		_fx_sprite.region_rect = _frame_rect("action_effects", _current_frame)
		_fx_sprite.scale = _sprite.scale
		_fx_sprite.position = _sprite.position

## Static expression from the `expressions` sheet (normal, blink, happy, ...).
func _set_expression(name: String) -> void:
	_anim_frames = []
	var idx := _find_named("expressions", name)
	if idx >= 0:
		_show("expressions", idx)
	else:
		_show("expressions", 0)
	_last_expr_shown = name

## Pose from the `action_poses` sheet (move_right, panic_left, strain_up, ...).
func _set_pose(name: String) -> void:
	_anim_frames = []
	var idx := _find_named("action_poses", name)
	if idx >= 0:
		_show("action_poses", idx)
	else:
		_set_expression("normal")
	_last_expr_shown = name

## Animation from `actions` (swing, pull, release, move, success, failure, recover)
## or a looping sheet of its own (idle, telescope).
func _play_animation(name: String) -> void:
	if name in SHEET_ANIMATIONS and _meta.has("sheets") and _meta.sheets.has(name):
		var s: Dictionary = _meta.sheets[name]
		_anim_frames = range(int(s.frame_count))
		_anim_fps = float(s.fps)
		_anim_loop = bool(s.loop)
		_current_sheet = name
	elif _meta.has("sheets") and _meta.sheets.has("actions") and _meta.sheets.actions.animations.has(name):
		var a: Dictionary = _meta.sheets.actions.animations[name]
		_anim_frames = a.frames
		_anim_fps = float(a.fps)
		_anim_loop = bool(a.loop)
		_current_sheet = "actions"
	else:
		_set_expression("normal")
		return
	_anim_time = 0.0
	_anim_done = false
	_show(_current_sheet, int(_anim_frames[0]))
	_last_expr_shown = name

# ------------------------------------------------------------ mood logic
func _on_mood_changed() -> void:
	match mood:
		"SUCCESS":
			_play_animation("success")
		"FAILURE":
			_play_animation("failure")
		"GRABBING":
			_play_animation("pull")
		_:
			pass

## Called every frame by the main scene with physics-derived cues.
## `tangent_angle` is the screen-space angle of the last rope segment
## (0 = straight down, +right). Velocities are in screen px/s.
func update_motion(tangent_angle: float, lateral_vel: float, depth_vel: float, anchor_accel: Vector2, depth_scale: float, dt: float) -> void:
	_lateral_vel = lateral_vel
	_depth_vel = depth_vel
	_depth_scale = depth_scale
	var target_tilt := tangent_angle * tilt_follow + lateral_vel * tilt_from_velocity
	target_tilt = clampf(target_tilt, -deg_to_rad(max_tilt_deg), deg_to_rad(max_tilt_deg))
	_tilt = lerpf(_tilt, target_tilt, clampf(dt * 14.0, 0.0, 1.0))
	rotation = _tilt
	scale = Vector2.ONE * depth_scale
	if anchor_accel.length() > panic_accel_threshold and _panic_left <= 0.0 and mood in ["IDLE", "MOVING_XY", "MOVING_FORWARD", "MOVING_BACKWARD"]:
		_panic_left = 0.7
		_panic_dir = 1 if anchor_accel.x < 0.0 else -1 # thrown opposite to the kick
	_panic_left -= dt
	_tick_face(dt)

func _tick_face(dt: float) -> void:
	# animation playback
	if not _anim_frames.is_empty() and _anim_fps > 0.0 and not _anim_done:
		_anim_time += dt
		var i := int(_anim_time * _anim_fps)
		if i >= _anim_frames.size():
			if _anim_loop:
				i = i % _anim_frames.size()
			else:
				i = _anim_frames.size() - 1
				_anim_done = true
		_show(_current_sheet, int(_anim_frames[i]))
	if manual_expression != "":
		if _last_expr_shown != manual_expression:
			_apply_named(manual_expression)
		return
	# panic overrides everything briefly
	if _panic_left > 0.0:
		var p := "panic_right" if _panic_dir > 0 else "panic_left"
		if _last_expr_shown != p:
			_set_pose(p)
		return
	if peering and mood in ["IDLE", "Z_LOWERING", "Z_RAISING"]:
		_want_anim("telescope")
		return
	match mood:
		"SUCCESS", "FAILURE", "GRABBING":
			if _anim_done and mood == "FAILURE" and _last_expr_shown == "failure":
				_play_animation("recover")
			return
		"ERROR":
			_want("surprised")
		"DISCONNECTED":
			_want("worried")
		"Z_RAISING":
			_want("straining")
		"Z_LOWERING":
			_want_pose("strain_up")
		"MOVING_XY":
			if absf(_lateral_vel) > 40.0:
				_want_pose("move_right" if _lateral_vel > 0.0 else "move_left")
			else:
				_want("normal")
		"MOVING_FORWARD", "MOVING_BACKWARD":
			_want_anim("move")
		_:
			_idle(dt)

func _want(expr: String) -> void:
	if _last_expr_shown != expr:
		_set_expression(expr)

func _want_pose(p: String) -> void:
	if _last_expr_shown != p:
		_set_pose(p)

func _want_anim(a: String) -> void:
	if _last_expr_shown != a:
		_play_animation(a)

func _idle(dt: float) -> void:
	_blink_timer -= dt
	if _blink_left > 0.0:
		_blink_left -= dt
		_want("blink")
		return
	if _blink_timer <= 0.0:
		_blink_timer = randf_range(2.0, 4.5)
		_blink_left = 0.12
		return
	if absf(_lateral_vel) > 120.0:
		_want_pose("move_right" if _lateral_vel > 0.0 else "move_left")
	else:
		_want_anim("idle")

func _apply_named(name: String) -> void:
	if _find_named("expressions", name) >= 0:
		_set_expression(name)
	elif _find_named("action_poses", name) >= 0:
		_set_pose(name)
	else:
		_play_animation(name)

func available_expressions() -> Array[String]:
	var out: Array[String] = []
	if _meta.is_empty():
		return out
	for e in _meta.sheets.expressions.frames:
		out.append(str(e.name))
	for e in _meta.sheets.action_poses.frames:
		out.append(str(e.name))
	for a in _meta.sheets.actions.animations.keys():
		out.append(str(a))
	for a in SHEET_ANIMATIONS:
		if _meta.sheets.has(a):
			out.append(a)
	return out

func current_face() -> String:
	return _last_expr_shown

## The spyglass lens relative to the rope knot, in sprite pixels: frame pixel
## (62, 30) against the knot (32, 5), mirrored when looking left.
func lens_offset() -> Vector2:
	return Vector2(-31.0 if peer_left else 30.0, 25.0) * pixel_scale

func pose_effects_visible() -> bool:
	return _fx_sprite != null and _fx_sprite.visible

# ------------------------------------------------------------ placeholder
func _draw() -> void:
	if _has_assets:
		return
	var s := pixel_scale
	var c := Vector2(0.0, 27.0 * s) # body centre relative to knot
	draw_rect(Rect2(Vector2(-2 * s, 0), Vector2(4 * s, 6 * s)), Color(0.03, 0.1, 0.3))
	draw_circle(c + Vector2(0, -4 * s), 16 * s, Color(0.22, 0.65, 0.98))
	draw_circle(c + Vector2(-5 * s, -8 * s), 4 * s, Color(0.75, 0.95, 1.0))
	draw_rect(Rect2(c + Vector2(-26 * s, 2 * s), Vector2(52 * s, 12 * s)), Color(0.1, 0.33, 0.8))
	for i in range(6):
		draw_circle(c + Vector2((-20 + i * 8) * s, 12 * s), 2 * s, Color(1.0, 0.85, 0.2))
	draw_circle(c + Vector2(-6 * s, -5 * s), 2.5 * s, Color(0.03, 0.1, 0.3))
	draw_circle(c + Vector2(6 * s, -5 * s), 2.5 * s, Color(0.03, 0.1, 0.3))

extends Node
## Autoload "VFXManager": plays the pixelfx effects baked into res://assets/vfx
## (catalog.json + one PNG sheet and Aseprite-style JSON per effect, made by
## tools/build_vfx.py). Pure presentation: never reads or writes RobotState.
##
##   VFXManager.spawn_fx("grab_burst", pos, {"scale": 2.0, "layer": "front"})
##
## Each effect is an AnimatedSprite2D on `layer` (the main scene, so it shakes
## with the picture). Its SpriteFrames are built once per effect and shared.
## The sheet's pivot sits on `position`. One-shots free themselves when they
## end; loops run until stop_fx(), `duration` runs out, or what they follow goes.
##
## options (all optional; defaults from the catalog entry):
##   scale: float, speed: float (1 = the sheet's own timing), loop: bool,
##   alpha: float, color: Color (multiplied), layer: "front" / "back",
##   flip_h: bool, duration: float (seconds, then freed),
##   follow: Node2D + offset: Vector2 (kept at follow's position + offset)

const DIR := "res://assets/vfx/"
## Draw order: behind the rope and the UFO (above the starfield) / in front of
## everything in the world, the old particle bursts included.
const Z_BACK := -1
const Z_FRONT := 6
const LOG_MAX := 64

## Off: spawn_fx does nothing (returns null) and the running ones are stopped.
var enabled := true:
	set(v):
		enabled = v
		if not v:
			stop_all()
## Parent for new effects; when unset (tests, no main scene) they go under this node.
var layer: Node
## id -> catalog entry
var catalog: Dictionary = {}
## Ids spawned lately, newest last (tests / debug panel).
var spawned_log: Array[String] = []
var _frames: Dictionary = {}  # "id|loop" -> SpriteFrames
var _meta: Dictionary = {}  # id -> meta.pixelfx

func _ready() -> void:
	var f := FileAccess.open(DIR + "catalog.json", FileAccess.READ)
	if f == null:
		push_warning("VFX: no catalog (%s)" % DIR)
		return
	var c = JSON.parse_string(f.get_as_text())
	if c is Dictionary and c.get("effects") is Dictionary:
		catalog = c.effects

func ids() -> Array:
	return catalog.keys()

func has_fx(id: String) -> bool:
	return catalog.has(id)

## The sheet's meta.pixelfx (fps, loop, frames, frameSize, pivot), {} if unknown.
func meta(id: String) -> Dictionary:
	if not _meta.has(id) and catalog.has(id):
		_load(id, false)
	return _meta.get(id, {})

func spawn_fx(id: String, position: Vector2, options: Dictionary = {}) -> AnimatedSprite2D:
	if not enabled or not catalog.has(id):
		if enabled:
			push_warning("VFX: unknown effect %s" % id)
		return null
	var e: Dictionary = catalog[id]
	var m := meta(id)
	if m.is_empty():
		return null
	var loop := bool(options.get("loop", e.get("loop", m.get("loop", false))))
	var sf := _load(id, loop)
	if sf == null:
		return null
	var s := VfxSprite.new()
	s.name = "vfx_" + id
	s.sprite_frames = sf
	s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var size := Vector2(m.frameSize[0], m.frameSize[1])
	var pivot := Vector2(m.pivot[0], m.pivot[1])
	s.offset = size * 0.5 - pivot  # centered sprite: the pivot lands on `position`
	var k := float(options.get("scale", e.get("scale", 1.0)))
	s.scale = Vector2(-k if bool(options.get("flip_h", false)) else k, k)
	s.speed_scale = maxf(float(options.get("speed", 1.0)), 0.01)
	var col: Color = options.get("color", Color.WHITE)
	col.a *= float(options.get("alpha", e.get("alpha", 1.0)))
	s.modulate = col
	s.z_index = Z_FRONT if str(options.get("layer", e.get("layer", "front"))) == "front" else Z_BACK
	s.follow = options.get("follow", null)
	s.follow_offset = options.get("offset", Vector2.ZERO)
	s.position = position if s.follow == null else s.follow.global_position + s.follow_offset
	s.add_to_group("vfx")
	(layer if is_instance_valid(layer) else self).add_child(s)
	if s.follow != null:
		s.global_position = s.follow.global_position + s.follow_offset
	if not loop:
		s.animation_finished.connect(s.queue_free)
	var secs := float(options.get("duration", 0.0))
	if secs > 0.0:
		get_tree().create_timer(secs).timeout.connect(func(): stop_fx(s))
	s.play("default")
	spawned_log.append(id)
	if spawned_log.size() > LOG_MAX:
		spawned_log.remove_at(0)
	return s

func stop_fx(s: Node) -> void:
	if is_instance_valid(s) and not s.is_queued_for_deletion():
		s.queue_free()

func stop_all() -> void:
	if not is_inside_tree():
		return
	for s in get_tree().get_nodes_in_group("vfx"):
		stop_fx(s)

func active_count() -> int:
	if not is_inside_tree():
		return 0
	var n := 0
	for s in get_tree().get_nodes_in_group("vfx"):
		if not s.is_queued_for_deletion():
			n += 1
	return n

## SpriteFrames for `id` (one animation "default"), built from the sheet once and
## reused; each frame keeps its own duration relative to the sheet's fps.
func _load(id: String, loop: bool) -> SpriteFrames:
	var key := "%s|%s" % [id, loop]
	if _frames.has(key):
		return _frames[key]
	var jf := FileAccess.open(DIR + id + ".json", FileAccess.READ)
	if jf == null or not ResourceLoader.exists(DIR + id + ".png"):
		push_warning("VFX: missing sheet for %s (run tools/build_vfx.py)" % id)
		return null
	var sheet = JSON.parse_string(jf.get_as_text())
	if not (sheet is Dictionary) or not (sheet.get("meta", {}).get("pixelfx") is Dictionary):
		push_warning("VFX: bad sheet JSON for %s" % id)
		return null
	var m: Dictionary = sheet.meta.pixelfx
	_meta[id] = m
	var tex: Texture2D = load(DIR + id + ".png")
	var fps := maxf(float(m.get("fps", 30.0)), 1.0)
	var sf := SpriteFrames.new()
	sf.set_animation_speed("default", fps)
	sf.set_animation_loop("default", loop)
	var frames = sheet.frames
	var list: Array = frames.values() if frames is Dictionary else frames
	for fr in list:
		var r: Dictionary = fr.frame
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(r.x, r.y, r.w, r.h)
		# duration in ms -> relative to one frame at fps; the JSON rounds to whole ms
		# (33 at 30 fps), so within 1 ms of the nominal frame time is exactly one frame
		var ms := float(fr.get("duration", 1000.0 / fps))
		sf.add_frame("default", at, 1.0 if absf(ms - 1000.0 / fps) <= 1.0 else ms * fps / 1000.0)
	_frames[key] = sf
	return sf

## An effect sprite; when following a node, keeps to it each frame (the only
## per-frame work, and only while following). Frees itself if that node goes.
class VfxSprite extends AnimatedSprite2D:
	var follow: Node2D:
		set(v):
			follow = v
			set_process(v != null)
	var follow_offset := Vector2.ZERO

	func _ready() -> void:
		set_process(follow != null)

	func _process(_dt: float) -> void:
		if not is_instance_valid(follow):
			queue_free()
			return
		global_position = follow.global_position + follow_offset

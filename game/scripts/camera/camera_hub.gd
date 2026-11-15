class_name CameraHub
extends Node
## USB cameras through Godot's CameraServer, by role:
##   overview - looks down on the desk (also meant for gesture detection later)
##   focus    - mounted on the end of the arm
## Each role picks a feed by a name substring from the config (`camera.<role>.match`),
## or by hand from the debug panel. A role without a camera shows static.
##
## Each role converts its feed to RGB once, in a SubViewport (macOS delivers
## YCbCr in two planes; shaders/camera_feed.gdshader converts it). Views show
## `texture(role)`, a plain RGB texture: the debug panel at full frame, the
## scope cropped round (shaders/camera_view.gdshader).
##
## #118: the focus camera may come stabilized from the backend (FocusStream, its own port):
## while those frames arrive the focus role shows them and this hub switches its own focus
## feed off (one reader of the camera); when they stop it opens the feed again.
##
## Presentation only: frames are drawn on screen, never saved, sent anywhere or
## used for robot commands.

signal feeds_changed

const ROLES := ["overview", "focus"]
const FEED_SHADER := preload("res://shaders/camera_feed.gdshader")
const VIEW_SHADER := preload("res://shaders/camera_view.gdshader")
## Viewport size until the first frames tell the real one.
const DEFAULT_SIZE := Vector2i(640, 480)

var enabled := true
var _match := {"overview": "", "focus": ""}
var _flip := {"overview": Vector2i.ZERO, "focus": Vector2i.ZERO}
var _feed_id := {"overview": -1, "focus": -1}
var _manual := {"overview": false, "focus": false}
## role -> {"y": CameraTexture, "cbcr": ..., "rgb": ...}
var _tex := {}
var _viewport := {}  # role -> SubViewport
var _convert := {}   # role -> ShaderMaterial (YCbCr -> RGB)
var _activated := {}  # feed id -> true: feeds this hub switched on
var _last_sig := {}   # role -> "mode/size" of the last update
## The stabilized focus camera from the backend (#118), or null.
var stream: FocusStream = null
var _stream_live := false

func _init() -> void:
	# built here, not in _ready, so views can take the textures right away
	for role in ROLES:
		var t := {}
		for k in ["y", "cbcr", "rgb"]:
			t[k] = CameraTexture.new()
		t.y.which_feed = CameraServer.FEED_Y_IMAGE
		t.cbcr.which_feed = CameraServer.FEED_CBCR_IMAGE
		t.rgb.which_feed = CameraServer.FEED_RGBA_IMAGE
		_tex[role] = t
		var vp := SubViewport.new()
		vp.name = "Camera_" + role
		vp.size = DEFAULT_SIZE
		vp.disable_3d = true
		vp.transparent_bg = false
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var rect := ColorRect.new()
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		var m := ShaderMaterial.new()
		m.shader = FEED_SHADER
		m.set_shader_parameter("y_tex", t.y)
		m.set_shader_parameter("cbcr_tex", t.cbcr)
		m.set_shader_parameter("rgb_tex", t.rgb)
		rect.material = m
		vp.add_child(rect)
		add_child(vp)
		_viewport[role] = vp
		_convert[role] = m

func _ready() -> void:
	enabled = bool(GameConfig.get_value("camera", "enabled", true))
	for role in ROLES:
		var c = GameConfig.get_value("camera", role, {})
		if c is Dictionary:
			_match[role] = str(c.get("match", ""))
			_convert[role].set_shader_parameter("flip_h", bool(c.get("flip_h", false)))
			_convert[role].set_shader_parameter("flip_v", bool(c.get("flip_v", false)))
	var fc = GameConfig.get_value("camera", "focus", {})
	var stab = fc.get("stabilize", {}) if fc is Dictionary else {}
	# headless (tests, CI) has no cameras and must not ask for camera access
	if enabled and DisplayServer.get_name() != "headless":
		CameraServer.camera_feed_added.connect(func(_id): _refresh.call_deferred())
		CameraServer.camera_feed_removed.connect(func(_id): _refresh.call_deferred())
		CameraServer.monitoring_feeds = true
		_refresh.call_deferred()
		if stab is Dictionary and bool(stab.get("enabled", false)):
			stream = FocusStream.new()
			stream.name = "FocusStream"
			stream.url = FocusStream.url_for(str(GameConfig.get_value("network", "websocket_url", "ws://127.0.0.1:8765")),
				int(stab.get("port", 8766)))
			add_child(stream)
	_apply_feeds()

func _exit_tree() -> void:
	for id in _activated.keys():
		var f := _feed(int(id))
		if f != null:
			f.feed_is_active = false

## RGB image of `role`'s camera (static when there is none).
func texture(role: String) -> Texture2D:
	return _viewport[role].get_texture()

## A material for a TextureRect showing a camera texture cropped to fill it,
## optionally as a disc (see camera_view.gdshader for the parameters).
func view_material(circle: bool = true) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = VIEW_SHADER
	m.set_shader_parameter("circle", circle)
	return m

## {id, name} of every camera the OS reports.
func feed_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for f in CameraServer.feeds():
		out.append({"id": f.get_id(), "name": f.get_name()})
	return out

## First feed whose name contains `pattern` (case-insensitive) and is not in
## `taken`; -1 when the pattern is empty or nothing matches.
static func pick_feed(feeds: Array, pattern: String, taken: Array = []) -> int:
	var p := pattern.strip_edges().to_lower()
	if p == "":
		return -1
	for f in feeds:
		if not taken.has(int(f.id)) and str(f.name).to_lower().contains(p):
			return int(f.id)
	return -1

func feed_id(role: String) -> int:
	return int(_feed_id.get(role, -1))

func feed_name(role: String) -> String:
	if external_live(role):
		return "%s（揺れ補正%s）" % [str(_match.get(role, "")), "" if bool(stream.header.get("stabilized", true)) else "オフ"]
	var f := _feed(feed_id(role))
	return f.get_name() if f != null else ""

func has_feed(role: String) -> bool:
	return external_live(role) or _feed(feed_id(role)) != null

## True while `role` shows the backend's stabilized frames (#118).
func external_live(role: String) -> bool:
	return role == "focus" and stream != null and stream.live()

## Frame size in pixels (zero until frames arrive).
func feed_size(role: String) -> Vector2:
	if external_live(role):
		return stream.texture.get_size()
	var mode := _mode_for(role)
	if mode == 0:
		return Vector2.ZERO
	var t: Dictionary = _tex[role]
	return t.y.get_size() if mode == 2 else t.rgb.get_size()

## Aspect (w/h) of `role`'s frames, 4:3 until known.
func feed_aspect(role: String) -> float:
	var s := feed_size(role)
	return s.x / s.y if s.y > 0.0 else 4.0 / 3.0

## Use feed `id` (-1 = none) for `role`, overriding the name match.
func assign(role: String, id: int) -> void:
	_manual[role] = true
	_feed_id[role] = id
	_apply_feeds()

func _feed(id: int) -> CameraFeed:
	if id < 0:
		return null
	for f in CameraServer.feeds():
		if f.get_id() == id:
			return f
	return null

func _refresh() -> void:
	var feeds := feed_list()
	for role in ROLES:
		if feed_id(role) >= 0 and _feed(feed_id(role)) == null:
			_manual[role] = false  # unplugged: back to the name match
	_feed_id = fill_roles(feeds, _feed_id, _match, _manual)
	_apply_feeds()

## New role -> feed id map: roles whose camera is still plugged in keep it
## (all of them reserved first, so a vacant role never takes another role's
## camera); vacant roles not picked by hand take the first free name match.
static func fill_roles(feeds: Array, current: Dictionary, patterns: Dictionary, manual: Dictionary) -> Dictionary:
	var present := {}
	for f in feeds:
		present[int(f.id)] = true
	var out := {}
	var taken: Array = []
	for role in ROLES:
		var id := int(current.get(role, -1))
		out[role] = id if present.has(id) else -1
		if out[role] >= 0:
			taken.append(out[role])
	for role in ROLES:
		if out[role] < 0 and not bool(manual.get(role, false)):
			out[role] = pick_feed(feeds, str(patterns.get(role, "")), taken)
			if out[role] >= 0:
				taken.append(out[role])
	return out

func _apply_feeds() -> void:
	var used := {}
	for role in ROLES:
		var id := feed_id(role)
		var t: Dictionary = _tex[role]
		for k in t.keys():
			t[k].camera_feed_id = maxi(id, 0)
		var f := _feed(id)
		if f != null and not external_live(role):  # the stream reads that camera now
			used[id] = true
			if not f.feed_is_active:
				f.feed_is_active = true
				_activated[id] = true
		_last_sig.erase(role)
		_update_role(role)
	for id in _activated.keys():
		if not used.has(id):
			var f := _feed(int(id))
			if f != null:
				f.feed_is_active = false
			_activated.erase(id)
	feeds_changed.emit()

## 0 none, 1 RGB, 2 YCbCr planes, 3 YCbCr packed (see camera_feed.gdshader).
func _mode_for(role: String) -> int:
	if external_live(role):
		return 1
	var f := _feed(feed_id(role))
	if f == null:
		return 0
	match f.get_datatype():
		CameraFeed.FEED_RGB:
			return 1
		CameraFeed.FEED_YCBCR_SEP:
			return 2
		CameraFeed.FEED_YCBCR:
			return 3
	return 0

## Conversion mode and viewport size follow the feed (the datatype switches
## RGB -> YCbCr and the size appears once frames flow).
func _update_role(role: String) -> void:
	var mode := _mode_for(role)
	var size := feed_size(role)
	var sig := "%d/%s" % [mode, size]
	if _last_sig.get(role, "") == sig:
		return
	_last_sig[role] = sig
	_convert[role].set_shader_parameter("mode", mode if size != Vector2.ZERO else 0)
	_viewport[role].size = Vector2i(size) if size != Vector2.ZERO else DEFAULT_SIZE

func _process(_dt: float) -> void:
	var live := external_live("focus")
	if live != _stream_live:
		_stream_live = live
		_apply_feeds()  # switch the focus feed off while the stream shows it, on again after
	for role in ROLES:
		_update_role(role)
		if external_live(role):
			_convert[role].set_shader_parameter("rgb_tex", stream.texture)
		elif has_feed(role):
			# The feed replaces its textures when frames start and when the format
			# changes, and a material keeps the texture it resolved when a parameter
			# was last set: set them again every frame or it shows a stale one.
			var t: Dictionary = _tex[role]
			var m: ShaderMaterial = _convert[role]
			m.set_shader_parameter("y_tex", t.y)
			m.set_shader_parameter("cbcr_tex", t.cbcr)
			m.set_shader_parameter("rgb_tex", t.rgb)

class_name GameModeVFX
extends Node2D
## What the game mode (#138) shows around the field: UFOくん on its rail, the two transfer
## ports (bottom-left = Dial 1, bottom-right = Dial 2), the capsule flying from a port to
## the UFO and back, the light running between a port and its Dial's side of the screen,
## and the score pop-ups. The sheets are the project's pixelfx ones through VFXManager
## (no second VFX system): the six capsule_* sheets are baked in grey and multiplied by the
## Dial's colour here, so the same sheets serve both sides. The port's frame and the light
## to the Dial are drawn here in that colour. Left and right are independent: both, and opposite directions, at once.
##
## Presentation only: it is told what happened (play(moment, side)) and never decides
## anything. Time moves in advance(dt).

## moment -> [sheet id, scale, offset of the picture's centre from the sheet's pivot (sheet px),
## playback speed]. The capsule_* sheets are grey (the Dial's colour is multiplied in as
## it is); the others are the crane game's cyan sheets (tint() shifts them).
const SHEETS := {
	"capsule_portal_open": ["capsule_portal_open", 1.0, Vector2(0, 48), 1.0],
	"capsule_absorb": ["capsule_absorb", 0.8, Vector2(0, 58), 1.5],
	"capsule_transfer_trail": ["capsule_transfer_trail", 1.5, Vector2(0, 20), 1.5],
	"capsule_materialize": ["capsule_materialize", 1.0, Vector2(0, 49), 2.0],
	"capsule_release_burst": ["capsule_release_burst", 1.0, Vector2(0, 0), 1.6],
	"capsule_portal_close": ["capsule_portal_close", 0.6, Vector2(0, 0), 2.2],
	"capsule_fault": ["fail_poof", 1.5],
	"hit_bumper": ["grab_burst", 1.2],
	"hit_star": ["success_sparkle", 2.0],
	"bonus": ["success_confetti", 2.0],
}
const MOMENTS := ["capsule_portal_open", "capsule_absorb", "capsule_transfer_trail", "capsule_materialize",
	"capsule_release_burst", "capsule_portal_close"]
const PORTS := {"left": Vector2(75, 640), "right": Vector2(1205, 640)}
const UFO_SHEET := "res://assets/ufo/ufo_idle.png"
const UFO_SCALE := 2.0
const UFO_FACES_SHEET := "res://assets/ufo/ufo_expressions.png"
## the expression sheet's frames in order (5 columns; assets/ufo/ufo_metadata.json)
const UFO_FACES := ["normal", "blink", "happy", "surprised", "straining", "worried", "sad", "wink", "sleepy", "excited"]
## UFOくん's reactions (#144): what happened -> [face, seconds, how it moves, rank]. A
## reaction of a lower rank does not cut a running one of a higher rank short.
const REACTIONS := {
	"start": ["excited", 1.0, "jump", 3],  # GO!
	"call": ["surprised", 0.45, "hop", 1],  # a capsule is on its way up
	"drop": ["wink", 0.45, "dip", 1],  # it lets the capsule go
	"score": ["happy", 0.5, "hop", 1],
	"big": ["excited", 1.0, "jump", 3],  # the star, the alien, the centre goal, a bonus
	"miss": ["sad", 1.0, "shake", 3],  # a capsule ran out of time, a Dial failed
	"hurry": ["surprised", 0.7, "shake", 2],  # the last 30 seconds begin
	"stop": ["surprised", 1.0, "shake", 4],
}
## the face it wears between reactions, by mood ("" = the idle animation)
const MOODS := {"normal": "", "hurry": "worried", "over": "sleepy", "happy": "happy", "sad": "sad", "stopped": "surprised"}
## the sheets are baked in cyan: this is what a full-bright pixel of them looks like
const SHEET_REF := Color(0.31, 0.82, 0.93)
const LOG_MAX := 64
const POPUP_S := 1.1
const BANNER_S := 1.0
const BANNER_COLORS := [Color("3ff0ff"), Color("3ff0ff"), Color("ffe03c"), Color("ff4fd8")]
## the light to the Dial during a release ends with the port; this only bounds it
const RELEASE_STREAM_MAX_S := 12.0

## UFO-DeviceHub's default unit colours (the Dials' LEDs): cyan and magenta
var colors := {"left": Color("00ffff"), "right": Color("ff00ff")}
var ufo_pos := Vector2(640, 92)
var ufo_visible := true
## normal / hurry / over / happy / sad / stopped (the controller sets it from the round)
var ufo_mood := "normal"
## reactions asked for, newest last (tests)
var reactions: Array[String] = []
var _react := ""
var _react_t := 0.0
var _faces_tex: Texture2D
## "moment:side", newest last (tests, the debug view)
var played: Array[String] = []
## side -> the port's looping sheet while it is open (freed ones are checked for)
var _port_fx := {"left": null, "right": null}
var _port_open := {"left": 0.0, "right": 0.0}
var _port_want := {"left": 0.0, "right": 0.0}
var _flights: Array[Dictionary] = []
var _streams: Array[Dictionary] = []
var _popups: Array[Dictionary] = []
var _banner := {"text": "", "t": 9.0, "level": 0}
## false: the pop-ups do not jump or blink (a debug switch)
var effects := true
var _marks: Array[Dictionary] = []
var _ufo_tex: Texture2D
var _top: Node2D
var _t := 0.0

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_top = Node2D.new()
	_top.name = "Top"
	_top.z_index = VFXManager.Z_FRONT + 1
	_top.draw.connect(_draw_top)
	add_child(_top)
	if ResourceLoader.exists(UFO_SHEET):
		_ufo_tex = load(UFO_SHEET)
	if ResourceLoader.exists(UFO_FACES_SHEET):
		_faces_tex = load(UFO_FACES_SHEET)

func reset() -> void:
	_port_open = {"left": 0.0, "right": 0.0}
	_port_want = {"left": 0.0, "right": 0.0}
	_flights.clear()
	_streams.clear()
	_popups.clear()
	_banner.t = 9.0
	_react = ""
	reactions.clear()
	ufo_mood = "normal"
	_marks.clear()
	played.clear()
	_port_fx = {"left": null, "right": null}
	for c in get_children():
		if c.is_in_group("vfx"):
			VFXManager.stop_fx(c)
		elif c.has_meta("flight"):
			c.queue_free()

func port(side: String) -> Vector2:
	return PORTS[side]

## The screen edge on the Dial's side, level with the port.
func dial_edge(side: String) -> Vector2:
	return Vector2(-10.0 if side == "left" else 1290.0, PORTS[side].y)

func tint(side: String) -> Color:
	var c: Color = colors[side]
	return Color(minf(c.r / SHEET_REF.r, 3.5), minf(c.g / SHEET_REF.g, 3.5), minf(c.b / SHEET_REF.b, 3.5))

## A moment of the transfer on one side. `at` is where on the field it happens (the drop
## point, the exit); `secs` how long the moving parts take.
func play(moment: String, side: String, at := Vector2.ZERO, secs := 0.5) -> void:
	played.append("%s:%s" % [moment, side])
	if played.size() > LOG_MAX:
		played.remove_at(0)
	var p: Vector2 = PORTS[side]
	match moment:
		"capsule_portal_open":
			_stream(side, true, secs)  # the light comes from the Dial to the screen
			_open_port(side)
		"capsule_absorb":  # the pull at the port, for as long as the capsule is on its way
			_sheet(moment, side, p, {"duration": secs})
		"capsule_transfer_trail":  # port -> the drop point under the UFO
			_fly(p, at, secs, side, -160.0, 0.5, 1.0)
		"capsule_materialize":
			_marks.append({"pos": at, "t": 0.0, "dur": 0.45, "side": side})
			_sheet(moment, side, at)
		"capsule_return":  # the exit -> the port, then the light runs to the Dial
			_open_port(side)
			_sheet("capsule_absorb", side, p, {"duration": secs})
			_fly(at, p, secs, side, 40.0, 1.0, 0.4)
			_stream(side, false, secs + 0.8)
		"capsule_release_burst":  # the light keeps running to the Dial until the port closes
			_sheet(moment, side, Vector2(clampf(dial_edge(side).x, 40.0, 1240.0), p.y - 30.0))
			_stream(side, false, RELEASE_STREAM_MAX_S)
		"capsule_portal_close":
			_close_port(side)
			_sheet(moment, side, p)
		"capsule_fault":
			_close_port(side)
			_sheet(moment, side, p)

## UFOくん reacts (see REACTIONS). A weaker reaction waits while a stronger one runs.
func react(kind: String) -> void:
	if not REACTIONS.has(kind):
		return
	reactions.append(kind)
	if reactions.size() > LOG_MAX:
		reactions.remove_at(0)
	if _react != "" and int(REACTIONS[kind][3]) < int(REACTIONS[_react][3]):
		return
	_react = kind
	_react_t = 0.0

## The reaction running now ("" = none).
func reaction() -> String:
	return _react

## The face shown now: the reaction's, else the mood's, else "" (the idle animation).
func ufo_face() -> String:
	if _react != "":
		return str(REACTIONS[_react][0])
	return str(MOODS.get(ufo_mood, ""))

## How the reaction moves the UFO now (px; nothing when effects are off).
func ufo_offset() -> Vector2:
	if _react == "" or not effects:
		return Vector2.ZERO
	var k := clampf(_react_t / float(REACTIONS[_react][1]), 0.0, 1.0)
	match str(REACTIONS[_react][2]):
		"hop":
			return Vector2(0, -10.0 * sin(PI * k))
		"jump":  # twice, the second lower
			return Vector2(0, -22.0 * absf(sin(TAU * k)) * (1.0 - 0.4 * k))
		"dip":
			return Vector2(0, 8.0 * sin(PI * k))
		"shake":
			return Vector2(6.0 * sin(k * TAU * 4.0) * (1.0 - k), 0)
	return Vector2.ZERO

func hit(kind: String, at: Vector2, color: Color) -> void:
	match kind:
		"bumper", "pop", "target", "gem":
			_spawn("hit_bumper", at, color)
		"star", "alien", "warp":
			_spawn("hit_star", at, Color.WHITE)
		"switch_bonus", "jackpot":
			_spawn("bonus", Vector2(640, 300), Color.WHITE)
			_spawn("hit_star", at, Color.WHITE)

## The points just scored, shown for a moment where they were scored. `level` (the combo,
## 0..3) makes it bigger. Words PixelText cannot draw are not shown.
func popup(text: String, at: Vector2, color: Color, big := false, level := 0) -> void:
	if not PixelText.supports(text):
		return
	_popups.append({"text": text, "pos": at, "t": 0.0, "color": color, "big": big, "level": level})
	if _popups.size() > 24:
		_popups.remove_at(0)

func popups() -> int:
	return _popups.size()

## The dot size of a pop-up: small, bigger for the big scores and as the combo climbs.
static func popup_scale(big: bool, level: int) -> float:
	return 2.0 * clampi((2 if big else 1) + (1 if level >= 2 else 0), 1, 3)

## A line across the middle for a moment (the combo climbed a step).
func banner(text: String, level := 0) -> void:
	if PixelText.supports(text):
		_banner = {"text": text, "t": 0.0, "level": level}

func banner_text() -> String:
	return _banner.text if _banner.t < BANNER_S else ""

func flights() -> int:
	return _flights.size()

func port_open(side: String) -> float:
	return _port_open[side]

func streaming(side: String, to_screen: bool) -> bool:
	for s in _streams:
		if s.side == side and s.to_screen == to_screen:
			return true
	return false

## The streams of one side fade out now (the port closes).
func _end_streams(side: String) -> void:
	for s in _streams:
		if s.side == side:
			s.left = minf(s.left, 0.25)

func _stream(side: String, to_screen: bool, secs: float) -> void:
	_streams.append({"side": side, "to_screen": to_screen, "left": secs, "dur": secs})

## The port opens: its looping sheet runs until the port closes (one per side).
func _open_port(side: String) -> void:
	_port_want[side] = 1.0
	if not is_instance_valid(_port_fx[side]) or (_port_fx[side] as Node).is_queued_for_deletion():
		_port_fx[side] = _sheet("capsule_portal_open", side, PORTS[side])

func _close_port(side: String) -> void:
	_port_want[side] = 0.0
	_end_streams(side)
	VFXManager.stop_fx(_port_fx[side])
	_port_fx[side] = null

func port_sheet_running(side: String) -> bool:
	return is_instance_valid(_port_fx[side]) and not (_port_fx[side] as Node).is_queued_for_deletion()

## A capsule in transit; the trail sheet follows it (a node moved along the path).
func _fly(a: Vector2, b: Vector2, secs: float, side: String, arc: float, k0: float, k1: float) -> void:
	var node := Node2D.new()
	node.set_meta("flight", true)
	node.position = a
	add_child(node)
	_flights.append({"a": a, "b": b, "t": 0.0, "dur": maxf(secs, 0.05), "side": side, "arc": arc, "k0": k0, "k1": k1, "node": node})
	var s: Array = SHEETS["capsule_transfer_trail"]
	VFXManager.spawn_fx(s[0], a, {"parent": self, "scale": s[1], "speed": s[3], "color": colors[side], "layer": "back",
		"follow": node, "offset": (s[2] as Vector2) * float(s[1])})

func _sheet(moment: String, side: String, at: Vector2, more: Dictionary = {}) -> AnimatedSprite2D:
	return _spawn(moment, at, colors[side] if str(SHEETS[moment][0]).begins_with("capsule_") else tint(side), more)

func _spawn(moment: String, at: Vector2, color: Color, more: Dictionary = {}) -> AnimatedSprite2D:
	if not SHEETS.has(moment):
		return null
	var s: Array = SHEETS[moment]
	var opts := {"parent": self, "scale": s[1], "color": color}
	if s.size() > 2:  # the picture's centre, not the sheet's pivot (its ground line), goes on `at`
		at += (s[2] as Vector2) * float(s[1])
		opts["speed"] = s[3]
	else:
		opts["layer"] = "front"
	opts.merge(more)
	return VFXManager.spawn_fx(s[0], at, opts)

func advance(dt: float) -> void:
	_t += dt
	for side in _port_open.keys():
		_port_open[side] = move_toward(_port_open[side], _port_want[side], dt * 4.0)
	for list in [_flights, _marks]:
		for f in list.duplicate():
			f.t += dt
			var node = f.get("node")
			if f.t >= f.dur:
				list.erase(f)
				if is_instance_valid(node):
					node.queue_free()  # its trail sheet goes with it
			elif is_instance_valid(node):
				node.position = _along(f, clampf(f.t / f.dur, 0.0, 1.0))
	for s in _streams.duplicate():
		s.left -= dt
		if s.left <= 0.0:
			_streams.erase(s)
	for p in _popups.duplicate():
		p.t += dt
		if p.t >= POPUP_S:
			_popups.erase(p)
	_banner.t += dt
	if _react != "":
		_react_t += dt
		if _react_t >= float(REACTIONS[_react][1]):
			_react = ""

func _process(_dt: float) -> void:
	queue_redraw()
	if _top != null:
		_top.queue_redraw()

func _draw() -> void:
	# the light between each Dial's side of the screen and its port
	for s in _streams:
		var a: Vector2 = dial_edge(s.side) if s.to_screen else PORTS[s.side]
		var b: Vector2 = PORTS[s.side] if s.to_screen else dial_edge(s.side)
		var col: Color = colors[s.side]
		var fade := clampf(s.left / 0.25, 0.0, 1.0)
		for i in 7:
			var k := fmod(_t * 2.2 + i / 7.0, 1.0)
			var q := a.lerp(b, k)
			var sz := 10.0 - 6.0 * absf(k - 0.5)
			draw_rect(Rect2((q - Vector2(sz, sz) * 0.5).snapped(Vector2(2, 2)), Vector2(sz, sz)), Color(col.r, col.g, col.b, fade))
			draw_rect(Rect2((q - Vector2(2, 2)).snapped(Vector2(2, 2)), Vector2(4, 4)), Color(1, 1, 1, fade))
	# the ports
	for side in PORTS.keys():
		var p: Vector2 = PORTS[side]
		var col: Color = colors[side]
		var o: float = _port_open[side]
		# the socket: a dark well with a neon rim and tick marks, named after its Dial (#141)
		draw_circle(p, 37.0, Color(col.r, col.g, col.b, 0.08 + 0.1 * o))
		draw_circle(p, 34.0, Color("050818"))
		draw_arc(p, 31.0, 0, TAU, 32, Color(col.r, col.g, col.b, 0.55 + 0.45 * o), 4.0)
		draw_arc(p, 28.0, PI * 1.1, PI * 1.7, 10, Color(1, 1, 1, 0.5), 2.0)
		draw_circle(p, 25.0, Color(0.02, 0.03, 0.12, 0.95))
		for i in 8:
			var ta := TAU * i / 8.0 + _t * 0.3
			draw_rect(Rect2((p + Vector2(cos(ta), sin(ta)) * 31.0 - Vector2(2, 2)).snapped(Vector2(1, 1)), Vector2(4, 4)),
				Color.WHITE if (i + int(_t * 4.0)) % 8 == 0 else Color(col.r, col.g, col.b, 0.9))
		PixelText.draw_centered(self, "DIAL 1" if side == "left" else "DIAL 2", p + Vector2(0, 52), 2.0, col, Color("050818"))
		if o > 0.01:
			draw_circle(p, 28.0 * o, Color(col.r, col.g, col.b, 0.25))  # a glow under the port's sheet
	# the drop marks: a short beam where the capsule appears
	for m in _marks:
		var k: float = 1.0 - m.t / m.dur
		var col: Color = colors[m.side]
		draw_rect(Rect2(m.pos.x - 10.0 * k, ufo_pos.y + 20.0, 20.0 * k, m.pos.y - ufo_pos.y - 20.0), Color(col.r, col.g, col.b, 0.45 * k))

## Above the sheets (z 7): the capsules in transit, UFOくん and the pop-ups stay readable.
func _draw_top() -> void:
	var top := _top
	for f in _flights:
		var col: Color = colors[f.side]
		for j in 6:
			var kk := clampf(f.t / f.dur - 0.035 * j, 0.0, 1.0)
			var q := _along(f, kk)
			if j == 0:
				PinballField.draw_capsule_at(top, q, _t * 9.0, col, lerpf(f.k0, f.k1, kk))
			else:
				var sz := 9.0 - j
				top.draw_rect(Rect2((q - Vector2(sz, sz) * 0.5).snapped(Vector2(2, 2)), Vector2(sz, sz)), Color(col.r, col.g, col.b, 0.7 - 0.1 * j))
	# UFOくん
	if ufo_visible and _ufo_tex != null:
		var size := Vector2(64, 64) * UFO_SCALE
		var bob := Vector2(0, sin(_t * (4.8 if ufo_mood == "hurry" else 2.4)) * 4.0)
		# on the dot grid, so the sprite's 64 x 64 dots are the canvas's dots one to one
		var at := (ufo_pos - size * 0.5 + bob + ufo_offset()).snapped(Vector2(2, 2))
		var face := ufo_face()
		var fi := UFO_FACES.find(face)
		if face == "" and int(_t * 0.7) % 4 == 3 and fmod(_t * 0.7, 1.0) < 0.12:
			fi = UFO_FACES.find("blink")  # it blinks now and then while idle
		if fi >= 0 and _faces_tex != null:
			top.draw_texture_rect_region(_faces_tex, Rect2(at, size), Rect2(64 * (fi % 5), 64 * (fi / 5), 64, 64))
		else:
			top.draw_texture_rect_region(_ufo_tex, Rect2(at, size), Rect2(64 * (int(_t * 3.0) % 4), 0, 64, 64))
	# score pop-ups: pixel numbers that jump in, rise and blink out
	for p in _popups:
		var k: float = p.t / POPUP_S
		if effects and k > 0.75 and int(p.t * 20.0) % 2 == 0:
			continue
		var sc := popup_scale(p.big, p.level) + (2.0 if effects and p.t < 0.08 else 0.0)
		var rise := 56.0 * (1.0 - (1.0 - k) * (1.0 - k))
		var pos: Vector2 = (p.pos + Vector2(0, -24.0 - rise)).snapped(Vector2(2, 2))
		pos.x = clampf(pos.x, 150.0 + PixelText.width(p.text, sc) * 0.5, 1130.0 - PixelText.width(p.text, sc) * 0.5)
		var col: Color = p.color if not (p.big and int(p.t * 12.0) % 2 == 0) else Color.WHITE
		PixelText.draw_centered(top, p.text, pos, sc, col, Color("050818"))
	if _banner.t < BANNER_S:
		var bk: float = _banner.t / BANNER_S
		if not (bk > 0.7 and int(_banner.t * 20.0) % 2 == 0):
			var bs := 4.0 + (2.0 if _banner.level >= 3 else 0.0) + (2.0 if _banner.t < 0.08 else 0.0)
			var bc: Color = BANNER_COLORS[clampi(_banner.level, 0, 3)]
			var bp := Vector2(640, 250.0 - 20.0 * bk).snapped(Vector2(2, 2))
			PixelText.draw_centered(top, _banner.text, bp + Vector2(4, 4), bs, Color(0.02, 0.03, 0.1, 0.8))
			PixelText.draw_centered(top, _banner.text, bp, bs, bc if int(_banner.t * 10.0) % 2 == 0 else Color.WHITE, Color("050818"))

func _along(f: Dictionary, k: float) -> Vector2:
	var e := k * k * (3.0 - 2.0 * k)
	var a: Vector2 = f.a
	var b: Vector2 = f.b
	return a.lerp(b, e) + Vector2(0, float(f.arc) * sin(PI * e))

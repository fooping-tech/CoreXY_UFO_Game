class_name GestureTutorialHud
extends Control
## The screen of the practice before the score game (#149): one step at a time, a big
## picture, one big line, a smaller one, and what the camera sees of the hand in plain
## words. A step really done gets one big "OK". Drawn in the game's dot size (2 px) with
## rectangles: no picture files. It only shows what GestureTutorialController says.

## Portrait (#157): the panel fills the screen under the status row, and each step is laid
## out down it: the hand on top, what it does below, then the words.
const SCREEN := GameModeLayout.SCREEN
const PANEL := Rect2(20, 250, 680, 830)
## where the two halves of a step's picture are centred: the hand (top), its effect (below)
const TOP_AT := Vector2(360, 470)
## #183: with the hand camera's picture beside it, the hand's picture stands to the left
const TOP_AT_CAM := Vector2(250, 470)
## where the hand camera's picture goes: beside the hand, and (the catch's art fills the
## right side) small in the corner
const CAM_RECT := Rect2(420, 372, 264, 198)
const CAM_RECT_SMALL := Rect2(516, 322, 168, 126)
const LOW_AT := Vector2(360, 720)
## where each line of words sits: [the steps, the practice capsule]
const LINES := {
	"progress": [Rect2(40, 262, 320, 36), Rect2(24, 8, 320, 30)],
	"mode": [Rect2(380, 266, 300, 28), Rect2(380, 10, 316, 26)],
	"speech": [Rect2(40, 302, 640, 32), Rect2(20, 250, 680, 32)],
	"title": [Rect2(30, 826, 660, 90), Rect2(20, 36, 680, 44)],
	"sub": [Rect2(30, 916, 660, 52), Rect2(190, 1128, 340, 72)],
	"guide": [Rect2(30, 968, 660, 40), Rect2(20, 80, 680, 34)],
	"status": [Rect2(30, 1010, 660, 62), Rect2(190, 1204, 340, 60)],
}
## the practice capsule: only a banner, so the field and the ports are in view
const BANNER := Rect2(8, 4, 704, 114)
const YELLOW := Color("ffe03c")
const CYAN := Color("3ff0ff")
const MAGENTA := Color("ff4fd8")
const PURPLE := Color("8a5cff")
const DARK := Color("050818")
const GLASS := Color(0.02, 0.03, 0.13, 0.93)
const OK_RED := Color("ff4466")
const SKIN := Color("ffd9a8")
const SKIN_SHADE := Color("e2a878")
const INK := Color("2a1830")
const DOT := 2.0
## the hand shapes that can be drawn
const HAND_POSES := ["open", "fist", "peace", "point", "thumb", "pinch"]
## finger lengths in hand dots: index, middle, ring, little (stretched)
const FINGER_LEN := [9, 10, 9, 7]
const FINGERS_UP := {"open": [1, 1, 1, 1], "fist": [0, 0, 0, 0], "peace": [1, 1, 0, 0], "point": [1, 0, 0, 0],
	"thumb": [0, 0, 0, 0], "pinch": [2, 1, 1, 1]}
const POSE_WORDS := {"open": "パー", "fist": "グー", "peace": "チョキ", "point": "ゆびさし", "thumb": "おやゆび", "other": "？", "": "？"}
const RULE_TAGS := ["カプセルを\nつかむ", "ポータルに\nいれる", "がめんで\nピンボール", "とくてん！", "おなじ ポータル\nから かえる"]

var ctl: GameModeController
var _title: Label
var _sub: Label
var _guide: Label
var _status: Label
var _progress: Label
var _mode: Label
var _speech: Label
var _tags: Array[Label] = []
var _ufo_tex: Texture2D
var _faces_tex: Texture2D
var _t := 0.0
var _ok_t := 9.0
## what was drawn last (tests)
var shown_art := ""
var top_at := TOP_AT
var _cam: TextureRect
var _cam_overlay: GestureCameraOverlay
var _hub: CameraHub

func setup(c: GameModeController) -> void:
	ctl = c
	size = SCREEN
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	z_index = 30  # over the field, the score panels' labels and the title
	visible = false
	if ResourceLoader.exists(GameModeVFX.UFO_SHEET):
		_ufo_tex = load(GameModeVFX.UFO_SHEET)
	if ResourceLoader.exists(GameModeVFX.UFO_FACES_SHEET):
		_faces_tex = load(GameModeVFX.UFO_FACES_SHEET)
	_progress = _label(26, YELLOW, LINES.progress[0], HORIZONTAL_ALIGNMENT_LEFT)
	_mode = _label(18, Color("b8c6ff"), LINES.mode[0], HORIZONTAL_ALIGNMENT_RIGHT)
	# what UFOくん is saying now, as words (the voice may be off or missing)
	_speech = _label(20, Color("9ff3ff"), LINES.speech[0], HORIZONTAL_ALIGNMENT_CENTER)
	_title = _label(30, Color.WHITE, LINES.title[0], HORIZONTAL_ALIGNMENT_CENTER)
	_sub = _label(22, Color("cfe0ff"), LINES.sub[0], HORIZONTAL_ALIGNMENT_CENTER)
	_guide = _label(26, YELLOW, LINES.guide[0], HORIZONTAL_ALIGNMENT_CENTER)
	_status = _label(18, Color("9fb4d8"), LINES.status[0], HORIZONTAL_ALIGNMENT_CENTER)
	for l in [_title, _sub, _status]:
		l.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY  # a long line wraps inside the screen
	for i in 6:
		var tag := _label(17, Color.WHITE, Rect2(0, 0, 190, 50), HORIZONTAL_ALIGNMENT_CENTER)
		tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_tags.append(tag)
	ctl.tutorial.step_succeeded.connect(func(_i, _s): _ok_t = 0.0)
	ctl.tutorial.step_started.connect(func(_i, _s): _ok_t = 9.0)

func _label(font_size: int, color: Color, r: Rect2, align: int) -> Label:
	var l := StudyHud.label("", font_size, color, 6)
	l.position = r.position
	l.size = r.size
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.clip_text = false
	add_child(l)
	return l

## #183: the hand camera's picture (the overview role, what the hand detection sees) beside
## the hand's picture, with the detected hand drawn over it. Display only.
func attach(hub: CameraHub, gesture: GestureControl, flip_h := false, flip_v := false) -> void:
	_hub = hub
	if _cam == null:
		_cam = TextureRect.new()
		_cam.name = "HandCamera"
		_cam.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_cam.stretch_mode = TextureRect.STRETCH_SCALE
		_cam.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_cam.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		_cam.visible = false
		add_child(_cam)
		_cam_overlay = GestureCameraOverlay.new()
		_cam_overlay.compact = true
		_cam.add_child(_cam_overlay)
	_cam.texture = hub.texture("overview")
	_cam_overlay.gesture = gesture
	_cam_overlay.flip_h = flip_h
	_cam_overlay.flip_v = flip_v

## Where the camera's picture shows now (no area = not shown): a hand step that is judged,
## and a camera that gives a picture.
func camera_rect() -> Rect2:
	if not showing() or _hub == null or not _hub.has_feed("overview"):
		return Rect2()
	var tut := ctl.tutorial
	if not GestureTutorialController.is_hand_kind(tut.kind()) or tut.no_hand:
		return Rect2()
	return CAM_RECT_SMALL if str(tut.step().get("art", "")) in ["grab", "release"] else CAM_RECT

## The practice is on the screen now.
func showing() -> bool:
	return ctl != null and ctl.active() and ctl.phase == "TUTORIAL" and ctl.tutorial.active()

## The line that says where the player is ("れんしゅう 2 / 6"; "" for the spell).
func progress_text() -> String:
	var tut := ctl.tutorial
	var n := GestureTutorialSteps.number_of(tut.steps, tut.index)
	return "れんしゅう %d / %d" % [n, GestureTutorialSteps.counted(tut.steps)] if n > 0 else ""

## What the camera sees of the hand, in plain words ("" when the step has no hand).
func status_text(hand: Dictionary) -> String:
	var tut := ctl.tutorial
	if not GestureTutorialController.is_hand_kind(tut.kind()):
		return ""
	if bool(hand.get("demo", false)):
		return "デモ: つくった ての うごきで みせているよ（カメラも ロボットも つかっていない）"
	if not bool(hand.get("enabled", false)):
		return "てのカメラ: つかっていない"
	if not bool(hand.get("fresh", false)) or not bool(hand.get("camera_ok", true)):
		return "てのカメラ: みつからない"
	if not bool(hand.get("detected", false)):
		return "て: みえないよ"
	var shape := "つまんでる" if bool(hand.get("pinch", false)) else str(POSE_WORDS.get(str(hand.get("pose", "")), "？"))
	var out := "て: みえてるよ    かたち: %s" % shape
	if bool(hand.get("active", false)) and float(hand.get("speed", 0.0)) > 0.05:
		out += "    うごかしてる！"
	return out

## What UFOくん is saying now, as words ("" when silent, or when it is the big line itself).
func speech_text() -> String:
	var line := ctl.tutorial_speech.current
	if line == "" or line.replace("、", " ").replace(" ", "") == str(ctl.tutorial.step().get("title", "")).replace(" ", ""):
		return ""
	return "UFOくん「%s」" % line

## The small line under the big one: the step's own, or why the robot does not move.
func sub_text() -> String:
	var tut := ctl.tutorial
	var s := tut.step()
	var sub := str(s.get("sub", ""))
	if tut.kind() in ["move", "grab"] and tut.hand_only and tut.state == "judging":
		sub = "ての れんしゅうだけ するよ（いま ロボットは うごかない）"
	if tut.kind() == "practice":
		if ctl.easy_on() and s.has("sub_easy"):
			sub = str(s.sub_easy)
		match ctl.practice:
			"closing", "done":
				sub = "かえしたよ。でてこなかったら かかりの ひとに いってね"
	return sub

func _process(dt: float) -> void:
	var on := showing()
	visible = on
	if not on:
		return
	_t += dt
	_ok_t += dt
	var tut := ctl.tutorial
	var s := tut.step()
	var practice := tut.kind() == "practice"
	_progress.text = progress_text()
	_mode.text = str(GestureTutorialSteps.MODE_NAMES.get(ctl.tutorial_mode, "")) if not practice else ""
	_title.text = str(s.get("title", ""))
	_sub.text = sub_text()
	_guide.text = tut.guide
	_speech.text = speech_text()
	_status.text = status_text(ctl._hand_snapshot()) if not practice else ""
	var which := 1 if practice else 0
	var labels := {"progress": _progress, "mode": _mode, "speech": _speech, "title": _title, "sub": _sub, "guide": _guide, "status": _status}
	for key in labels.keys():
		var r: Rect2 = LINES[key][which]
		labels[key].position = r.position
		labels[key].size = r.size
	_title.add_theme_font_size_override("font_size", 30)
	_guide.pivot_offset = _guide.size * 0.5
	_guide.scale = Vector2.ONE * (1.0 + 0.03 * sin(_t * 5.0))
	for tag in _tags:
		tag.visible = false
	var cr := camera_rect()
	top_at = TOP_AT_CAM if cr == CAM_RECT else TOP_AT
	if _cam != null:
		_cam.visible = cr.has_area()
		if cr.has_area():
			_cam.position = cr.position
			_cam.size = cr.size
			_cam_overlay.position = Vector2.ZERO
			_cam_overlay.size = cr.size
	queue_redraw()

func _tag(i: int, text: String, centre: Vector2, color := Color.WHITE, width := 190.0) -> void:
	if i >= _tags.size():
		return
	var tag := _tags[i]
	tag.visible = true
	tag.text = text
	tag.size = Vector2(width, 50)
	tag.position = centre - tag.size * 0.5
	tag.add_theme_color_override("font_color", color)

# ------------------------------------------------------------------ drawing
func _draw() -> void:
	if not showing():
		return
	var tut := ctl.tutorial
	var s := tut.step()
	var kind := tut.kind()
	var practice := kind == "practice"
	var r := BANNER if practice else PANEL
	if not practice:
		draw_rect(Rect2(0, PANEL.position.y - 6.0, SCREEN.x, SCREEN.y - PANEL.position.y + 6.0), Color(0.01, 0.02, 0.08, 0.55))
	PinballField.glow_rect(self, r, PURPLE, 0.6)
	draw_rect(r.grow(4.0), DARK)
	draw_rect(r, GLASS)
	draw_rect(r, CYAN, false, 2.0)
	draw_rect(Rect2(r.position + Vector2(6, 6), Vector2(r.size.x - 12.0, 2)), Color(1, 1, 1, 0.16))
	for c in [r.position, r.position + Vector2(r.size.x - 8.0, 0), r.position + Vector2(0, r.size.y - 8.0), r.end - Vector2(8, 8)]:
		draw_rect(Rect2(c, Vector2(8, 8)), YELLOW)
	shown_art = str(s.get("art", ""))
	match shown_art:
		"summon":
			_draw_summon()
		"open", "point", "pinch":
			_draw_hand_step(shown_art)
		"move":
			_draw_move("pinch")
		"point_move":
			_draw_move("point")
		"grab", "release":
			_draw_grab(s)
		"z_pinch":
			_draw_hand_step("pinch")
			_tag(0, "てのこうを カメラに むける", top_at + Vector2(0, 122), YELLOW, 420.0)
		"z_move":
			_draw_z_move()
		"easy_grab":
			_draw_easy_grab()
		"easy_one":
			_draw_easy_number("point", "1", CYAN)
		"rules":
			_draw_rules()
		"practice":
			_draw_practice()
	var cr := camera_rect()
	if cr.has_area():  # the camera's frame (its picture is a child, drawn over this)
		draw_rect(cr.grow(6.0), DARK)
		draw_rect(cr.grow(3.0), CYAN, false, 2.0)
	if not practice and GestureTutorialController.is_hand_kind(kind) and tut.state == "judging" and not tut.telling():
		_draw_bar(Rect2(SCREEN.x * 0.5 - 130.0, top_at.y + 136.0, 260, 14), tut.progress)
	if tut.telling() and kind != "summon":
		_chip(Rect2(r.end.x - 150.0, r.position.y + 50.0, 130, 30), "せつめい", Color("b8c6ff"), 5)
	if bool(s.get("future", false)):
		_chip(Rect2(SCREEN.x * 0.5 - 90.0, PANEL.position.y + 90.0, 180, 34), "じゅんびちゅう", YELLOW, 4)
	if _ok_t < ctl.tutorial.ok_s + 0.2 and tut.state == "success":
		_draw_ok(Vector2(SCREEN.x * 0.5, 600) if not practice else GameModeLayout.CENTRE)

## A small framed word (a Label from the pool inside a pixel frame).
func _chip(r: Rect2, text: String, color: Color, tag_index: int) -> void:
	draw_rect(r.grow(2.0), DARK)
	draw_rect(r, Color(0.08, 0.08, 0.24, 0.95))
	draw_rect(r, color, false, 2.0)
	_tag(tag_index, text, r.get_center(), color)

func _draw_bar(r: Rect2, k: float) -> void:
	draw_rect(r.grow(2.0), DARK)
	draw_rect(r, Color(0.1, 0.12, 0.3))
	draw_rect(Rect2(r.position, Vector2(snappedf(r.size.x * clampf(k, 0.0, 1.0), DOT), r.size.y)), YELLOW)
	draw_rect(r, Color.WHITE, false, 2.0)

## The one "OK" of a step: a big ring (the Japanese "correct" mark), OK!, stars flying out.
func _draw_ok(c: Vector2) -> void:
	var k := clampf(_ok_t / 0.25, 0.0, 1.0)
	var radius := 60.0 + 70.0 * (1.0 - (1.0 - k) * (1.0 - k))
	for w in [[18.0, DARK], [12.0, Color.WHITE], [8.0, OK_RED]]:
		draw_arc(c, radius, 0.0, TAU, 48, w[1], w[0])
	var blink := int(_ok_t * 10.0) % 2 == 0
	PixelText.draw_centered(self, "OK!", c + Vector2(4, 4), 12.0, Color(0, 0, 0, 0.6))
	PixelText.draw_centered(self, "OK!", c, 12.0, YELLOW if blink else Color.WHITE, DARK)
	for i in 14:  # stars and confetti: a fixed set, placed by the time
		var a := TAU * i / 14.0 + 0.3
		var d := radius + 30.0 + 260.0 * _ok_t + 14.0 * sin(i * 2.1)
		var q := (c + Vector2(cos(a), sin(a) * 0.8) * d).snapped(Vector2(DOT, DOT))
		var col: Color = [YELLOW, CYAN, MAGENTA][i % 3]
		col.a = clampf(1.6 - _ok_t, 0.0, 1.0)
		draw_rect(Rect2(q - Vector2(4, 4), Vector2(8, 8)), col)
		draw_rect(Rect2(q - Vector2(12, 1), Vector2(24, 2)), Color(col.r, col.g, col.b, col.a * 0.6))
		draw_rect(Rect2(q - Vector2(1, 12), Vector2(2, 24)), Color(col.r, col.g, col.b, col.a * 0.6))

## UFOくん, big: the idle animation, or a face of the expression sheet.
func _draw_ufo(c: Vector2, scale: float, face := "") -> void:
	var size := Vector2(64, 64) * scale
	var at := (c - size * 0.5).snapped(Vector2(DOT, DOT))
	var fi := GameModeVFX.UFO_FACES.find(face)
	if fi >= 0 and _faces_tex != null:
		draw_texture_rect_region(_faces_tex, Rect2(at, size), Rect2(64 * (fi % 5), 64 * (fi / 5), 64, 64))
	elif _ufo_tex != null:
		draw_texture_rect_region(_ufo_tex, Rect2(at, size), Rect2(64 * (int(_t * 3.0) % 4), 0, 64, 64))

## The face for the step's moment: glad at an OK, worried when the hand is lost.
func _face() -> String:
	var tut := ctl.tutorial
	if tut.state == "success":
		return "wink" if int(_ok_t * 3.0) % 2 == 0 else "happy"
	if tut.state == "blocked" or tut.guide.contains("かかりの"):
		return "worried"
	if tut.guide.contains("みせてね"):
		return "surprised"
	return ""

## A hand in dots, fingers up, seen from the palm. `at` = the top-left of its 20 x 32 box,
## `d` = the size of one hand dot. pose: open / fist / peace / point / thumb / pinch.
func draw_hand(at: Vector2, d: float, pose: String) -> void:
	paint_hand(self, at, d, pose)
	if pose == "pinch":  # the two fingertips meet: a spark
		_spark(at + Vector2(3.0, 11.5) * d, d * 1.2, YELLOW)

## The same hand on any canvas item (the easy mode's screen draws them too).
static func paint_hand(ci: CanvasItem, at: Vector2, d: float, pose: String) -> void:
	var up: Array = FINGERS_UP.get(pose, FINGERS_UP["open"])
	var parts: Array = []  # [Rect2 in hand dots, colour]
	parts.append([Rect2(6, 16, 11, 12), SKIN])  # the palm
	parts.append([Rect2(8, 28, 8, 4), SKIN_SHADE])  # the wrist
	for i in 4:
		var x := 6.0 + 3.0 * i
		var n := int(up[i])
		if n == 1:
			var ln := float(FINGER_LEN[i])
			parts.append([Rect2(x, 15.0 - ln, 2, ln), SKIN])  # a dot apart: the ink line shows between them
		elif n == 2:  # the index bent over to the thumb
			parts.append([Rect2(x, 10, 2, 5), SKIN])
			parts.append([Rect2(x - 3.0, 10, 4, 2), SKIN])
		else:  # curled: only the knuckle
			parts.append([Rect2(x, 12, 2, 4), SKIN])
	match pose:
		"open":
			parts.append([Rect2(2, 18, 5, 3), SKIN])
			parts.append([Rect2(0, 15, 3, 5), SKIN])
		"thumb":
			parts.append([Rect2(3, 17, 4, 4), SKIN])
			parts.append([Rect2(3, 7, 3, 11), SKIN])
		"pinch":
			parts.append([Rect2(3, 18, 4, 4), SKIN])
			parts.append([Rect2(2, 13, 2, 6), SKIN])
		_:  # folded over the fingers
			parts.append([Rect2(7, 19, 8, 3), SKIN_SHADE])
	for p in parts:  # the ink line first, then the skin: one outline round the whole hand
		var o: Rect2 = p[0]
		ci.draw_rect(Rect2((at + (o.position - Vector2(1, 1)) * d).snapped(Vector2(DOT, DOT)), (o.size + Vector2(2, 2)) * d), INK)
	for p in parts:
		var q: Rect2 = p[0]
		ci.draw_rect(Rect2((at + q.position * d).snapped(Vector2(DOT, DOT)), q.size * d), p[1])

func _spark(c: Vector2, sz: float, col: Color) -> void:
	var k := 0.6 + 0.4 * sin(_t * 9.0)
	var q := c.snapped(Vector2(DOT, DOT))
	draw_rect(Rect2(q - Vector2(sz, sz) * 0.5, Vector2(sz, sz)), col)
	draw_rect(Rect2(q - Vector2(sz * 2.2 * k, DOT * 0.5), Vector2(sz * 4.4 * k, DOT)), col)
	draw_rect(Rect2(q - Vector2(DOT * 0.5, sz * 2.2 * k), Vector2(DOT, sz * 4.4 * k)), col)

## A dotted arrow from a to b (a pixel staircase), with a head.
func _arrow(a: Vector2, b: Vector2, col: Color, w := 6.0) -> void:
	var n := int(a.distance_to(b) / (w * 2.0))
	var shift := fmod(_t * 2.0, 1.0)
	for i in n:
		var q := a.lerp(b, (i + shift) / maxf(n, 1.0)).snapped(Vector2(DOT, DOT))
		draw_rect(Rect2(q - Vector2(w, w) * 0.5, Vector2(w, w)), col)
	var dir := (b - a).normalized()
	var side := Vector2(-dir.y, dir.x)
	for j in 4:
		for sgn in [-1.0, 1.0]:
			var h: Vector2 = (b - dir * (j * w) + side * sgn * (j * w)).snapped(Vector2(DOT, DOT))
			draw_rect(Rect2(h - Vector2(w, w) * 0.5, Vector2(w, w)), col)

## The hand's picture is drawn from its top-left corner: this puts its middle on `c`.
func _hand_at(c: Vector2, d := 8.0) -> Vector2:
	return c - Vector2(11.0, 16.0) * d

func _draw_hand_step(pose: String) -> void:
	var bob := snappedf(sin(_t * 3.0) * 4.0, DOT)
	var hand := _hand_at(top_at + Vector2(0, bob))
	draw_hand(hand, 8.0, pose)
	var ufo := LOW_AT + Vector2(0, 20.0 + sin(_t * 2.2) * 8.0)
	_draw_ufo(ufo, 4.0, _face())
	if pose == "pinch":  # the light runs from the fingertips to UFOくん: in sync
		var a := hand + Vector2(28, 84)
		var b := ufo + Vector2(-20, -90)
		for i in 9:
			var k := fmod(i / 9.0 + _t * 0.6, 1.0)
			var q := a.lerp(b, k) + Vector2(sin(k * PI) * -60.0, 0)
			_spark(q, 6.0, CYAN.lerp(YELLOW, k))

func _draw_move(pose: String) -> void:
	var sway := Vector2(sin(_t * 1.6) * 44.0, sin(_t * 0.8) * 12.0).snapped(Vector2(DOT, DOT))
	draw_hand(_hand_at(top_at) + sway, 8.0, pose)
	for dir in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
		var d: Vector2 = dir
		var c := top_at + d * Vector2(150.0 if top_at != TOP_AT else 200.0, 128)
		_arrow(c - d * 34.0, c + d * 10.0, CYAN)
	var ufo := LOW_AT + Vector2(0, 30)
	_draw_ufo(ufo + sway * Vector2(1.6, 1.6), 4.0, _face())
	draw_rect(Rect2(ufo.x - 140.0, ufo.y + 92.0, 280, 4), Color(1, 1, 1, 0.25))

## The up / down mode: the pinched hand goes up and down, and UFOくん with it.
func _draw_z_move() -> void:
	var sway := Vector2(0, sin(_t * 1.6) * 40.0).snapped(Vector2(DOT, DOT))
	draw_hand(_hand_at(top_at) + sway, 8.0, "pinch")
	for d in [Vector2(0, -1), Vector2(0, 1)]:
		var near := top_at != TOP_AT  # the camera's picture is beside the hand
		var c: Vector2 = top_at + Vector2(130.0 if near else 190.0, 0) + d * 70.0
		_arrow(c - d * 34.0, c + d * 10.0, CYAN)
	var side := Vector2(-150.0 if top_at != TOP_AT else -210.0, 60)
	var wide := 170.0 if top_at != TOP_AT else 220.0
	_tag(0, "うえ = あがる", top_at + side * Vector2(1, -1), CYAN, wide)
	_tag(1, "した = さがる", top_at + side, CYAN, wide)
	var ufo := LOW_AT + Vector2(0, 30)
	_draw_ufo(ufo + sway * Vector2(0, 1.2), 4.0, _face())

## The claw of the arm, open (k = 0) to closed (k = 1), over a capsule.
func _draw_claw(c: Vector2, k: float, col: Color) -> void:
	var metal := Color("c8d6ff")
	draw_rect(Rect2((c + Vector2(-4, -74)).snapped(Vector2(DOT, DOT)), Vector2(8, 34)), metal)
	draw_rect(Rect2((c + Vector2(-22, -44)).snapped(Vector2(DOT, DOT)), Vector2(44, 8)), metal)
	var open := lerpf(34.0, 16.0, k)
	for sgn in [-1.0, 1.0]:
		draw_line(c + Vector2(sgn * 18.0, -40), c + Vector2(sgn * open, 8), INK, 12.0)
		draw_line(c + Vector2(sgn * 18.0, -40), c + Vector2(sgn * open, 8), metal, 8.0)
		draw_line(c + Vector2(sgn * open, 8), c + Vector2(sgn * (open - 10.0), 24), metal, 8.0)
	PinballField.draw_capsule_at(self, c + Vector2(0, 14), 0.3, col, 1.0)

func _draw_grab(s: Dictionary) -> void:
	var pose := str(s.get("art_pose", "fist"))
	draw_hand(_hand_at(Vector2(190, 470)), 8.0, pose if pose in HAND_POSES else "fist")
	_arrow(Vector2(318, 470), Vector2(388, 470), YELLOW)
	_draw_claw(Vector2(480, 500), 0.5 + 0.5 * sin(_t * 3.0), CYAN)
	if not camera_rect().has_area():  # the camera's picture has that corner
		_draw_ufo(Vector2(610, 390 + sin(_t * 2.2) * 6.0), 2.0, _face())
	# the hand scheme's other shapes, small
	var hints: Array = s.get("hints", [])
	for i in mini(hints.size(), 2):
		var at := Vector2(96.0, 660.0 + 76.0 * i)
		var art := str(hints[i][0])
		draw_hand(at, 1.75, "pinch" if art == "pinch_down" else (art if art in HAND_POSES else "open"))
		_tag(i, str(hints[i][1]), at + Vector2(280, 28), Color("cfe0ff"), 460.0)

## The easy mode's catch as three frames: down, catch, up (what the round does by itself).
func _draw_easy_grab() -> void:
	draw_hand(_hand_at(top_at + Vector2(0, -10)), 8.0, "fist")
	for i in 3:
		var c := Vector2(190.0 + 170.0 * i, 716.0)
		var fr := Rect2(c - Vector2(72, 100), Vector2(144, 190))
		draw_rect(fr, Color(0.06, 0.08, 0.24, 0.9))
		draw_rect(fr, PURPLE, false, 2.0)
		_draw_claw(c + Vector2(0, [-20.0, 20.0, -20.0][i]), [0.0, 1.0, 1.0][i], CYAN)
		if i != 1:
			_arrow(c + Vector2(52, -40.0 if i == 0 else 40.0), c + Vector2(52, 40.0 if i == 0 else -40.0), YELLOW, 4.0)
		_tag(i, ["おりる", "つかむ", "あがる"][i], c + Vector2(0, 110), Color("cfe0ff"))

## The easy mode's carry: the finger shown, and the portal it means (Dial 1, on the left).
func _draw_easy_number(pose: String, number: String, col: Color) -> void:
	var side := -1.0
	draw_hand(_hand_at(top_at + Vector2(0, -10)), 8.0, pose)
	var dial := Vector2(360.0 + side * 190.0, 740.0)
	_arrow(Vector2(360, 610), dial + Vector2(-side * 40.0, -70.0), YELLOW)
	_draw_dial(dial, col, number)
	_tag(0, "ひだりの ポータル", dial + Vector2(0, 80), col)

## A Dial's port: a ring in its colour with its number.
func _draw_dial(c: Vector2, col: Color, number: String) -> void:
	draw_circle(c, 52.0, DARK)
	draw_arc(c, 46.0, 0.0, TAU, 32, col, 8.0)
	draw_arc(c, 30.0, _t * 2.0, _t * 2.0 + PI * 1.3, 16, Color(col.r, col.g, col.b, 0.6), 4.0)
	PixelText.draw_centered(self, number, c, 6.0, Color.WHITE, DARK)

## The spell: a summoning circle, UFOくん coming down in its beam.
func _draw_summon() -> void:
	var c := Vector2(SCREEN.x * 0.5, 640)
	var rise := clampf(ctl.tutorial.t / 1.6, 0.0, 1.0)
	for i in 3:  # the circle, seen at a slant: rings of dots turning
		var rad := 120.0 + 60.0 * i
		var n := 18 + 8 * i
		for j in n:
			var a := TAU * j / n + _t * (0.5 if i % 2 == 0 else -0.4)
			var q := (c + Vector2(cos(a) * rad, sin(a) * rad * 0.32 + 70.0)).snapped(Vector2(DOT, DOT))
			var col: Color = [MAGENTA, CYAN, YELLOW][i]
			col.a = 0.5 + 0.5 * sin(_t * 4.0 + j)
			draw_rect(Rect2(q - Vector2(4, 4), Vector2(8, 8)), col)
	for j in 6:  # a six-pointed sign inside it
		var a0 := TAU * j / 6.0 + _t * 0.3
		var a1 := TAU * (j + 2) / 6.0 + _t * 0.3
		draw_line(c + Vector2(cos(a0) * 170.0, sin(a0) * 54.0 + 70.0), c + Vector2(cos(a1) * 170.0, sin(a1) * 54.0 + 70.0), Color(PURPLE.r, PURPLE.g, PURPLE.b, 0.8), 4.0)
	var ufo := Vector2(c.x, lerpf(330.0, 540.0, rise * rise * (3.0 - 2.0 * rise)) + sin(_t * 2.2) * 6.0)
	var beam := PackedVector2Array([ufo + Vector2(-40, 50), ufo + Vector2(40, 50), c + Vector2(150, 96), c + Vector2(-150, 96)])
	draw_colored_polygon(beam, Color(CYAN.r, CYAN.g, CYAN.b, 0.12 + 0.06 * sin(_t * 5.0)))
	_draw_ufo(ufo, 4.0, "excited" if rise >= 1.0 and int(_t * 2.0) % 2 == 0 else "")
	for i in 10:  # stars of an old science-fiction poster
		var q := Vector2(50.0 + fmod(i * 197.0, 620.0), 350.0 + fmod(i * 83.0, 470.0))
		_spark(q, 4.0, Color(1, 1, 0.8, 0.5 + 0.5 * sin(_t * 3.0 + i)))
	PixelText.draw_centered(self, "SHOWA OCCULT X REIWA TECH", Vector2(c.x, 356), 2.0, Color(MAGENTA.r, MAGENTA.g, MAGENTA.b, 0.9), DARK)

## The rule as one picture: catch -> a port -> pinball on the screen -> points -> back out
## of the same port.
func _draw_rules() -> void:
	# five frames in two rows down the panel: 1 2 3, then 4 5
	var cs := [Vector2(130, 468), Vector2(360, 468), Vector2(590, 468), Vector2(245, 706), Vector2(475, 706)]
	for i in 5:
		var c: Vector2 = cs[i]
		var fr := Rect2(c - Vector2(82, 92), Vector2(164, 176))
		draw_rect(fr.grow(2.0), DARK)
		draw_rect(fr, Color(0.06, 0.08, 0.24, 0.92))
		draw_rect(fr, [CYAN, MAGENTA, PURPLE, YELLOW, MAGENTA][i], false, 2.0)
		var badge := Rect2(fr.position + Vector2(6, 6), Vector2(24, 24))
		draw_rect(badge, [CYAN, MAGENTA, PURPLE, YELLOW, MAGENTA][i])
		PixelText.draw_centered(self, str(i + 1), badge.get_center(), 2.0, DARK)
		match i:
			0:
				_draw_claw(c + Vector2(0, 26), 0.5 + 0.5 * sin(_t * 3.0), CYAN)
			1:  # into a port
				_draw_dial(c + Vector2(0, 20), MAGENTA, "")
				var k := fmod(_t * 0.9, 1.0)
				PinballField.draw_capsule_at(self, c + Vector2(0, -70.0 + 80.0 * k), _t * 3.0, MAGENTA, 1.0 - 0.5 * k)
			2:  # the screen: pins and a falling capsule
				draw_rect(Rect2(c - Vector2(60, 60), Vector2(120, 110)), DARK)
				draw_rect(Rect2(c - Vector2(60, 60), Vector2(120, 110)), CYAN, false, 2.0)
				for j in 9:
					draw_rect(Rect2(c + Vector2(-44.0 + 22.0 * (j % 4) + (11.0 if j / 4 % 2 == 1 else 0.0), -36.0 + 26.0 * (j / 4)), Vector2(6, 6)), YELLOW)
				var kk := fmod(_t * 0.7, 1.0)
				PinballField.draw_capsule_at(self, c + Vector2(sin(kk * 9.0) * 30.0, -50.0 + 90.0 * kk), _t * 5.0, MAGENTA, 0.6)
			3:
				var up := fmod(_t * 0.8, 1.0)
				PixelText.draw_centered(self, "+100", c + Vector2(0, 20.0 - 40.0 * up), 5.0, YELLOW, DARK)
				_spark(c + Vector2(-50, -40), 6.0, CYAN)
				_spark(c + Vector2(52, -20), 6.0, MAGENTA)
			4:  # back out of the same port
				_draw_dial(c + Vector2(0, -10), MAGENTA, "")
				var k2 := fmod(_t * 0.9, 1.0)
				PinballField.draw_capsule_at(self, c + Vector2(0, -10.0 + 80.0 * k2), _t * 3.0, MAGENTA, 0.5 + 0.5 * k2)
		_tag(i, RULE_TAGS[i], c + Vector2(0, 116), Color.WHITE)
		if i < 4 and is_equal_approx(cs[i].y, cs[i + 1].y):
			_arrow(Vector2(cs[i].x + 88.0, c.y), Vector2(cs[i + 1].x - 92.0, c.y), Color.WHITE, 4.0)

## The practice capsule: the field stays in view; an arrow shows the port.
func _draw_practice() -> void:
	var waiting := ctl.practice == "open" and not ctl.practice_busy()
	for side in GameModeController.SIDES:
		var l: GameModeController.Lane = ctl.lanes[side]
		var port: Vector2 = GameModeVFX.PORTS[side]
		var x: float = port.x
		# over the port (bottom left): an arrow down into it (its lane's words say "put it in here")
		if waiting and l.state == "READY":
			var bounce := snappedf(absf(sin(_t * 4.0)) * 16.0, DOT)
			_arrow(Vector2(x, port.y - 160.0 + bounce), Vector2(x, port.y - 90.0 + bounce), l.color, 8.0)

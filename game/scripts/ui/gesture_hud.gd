class_name GestureHud
extends Control
## Compact hand joystick panel, bottom-left of the play area: a small live view
## of the gesture camera with the tracked hand on it (where in the camera's view
## the hand is; yellow frame near an edge, blinking red frame and an arrow back
## when it left the view), hand / pinch state, the virtual stick ring with the
## hand's offset, the direction, a short speed gauge and a one-line hint.
## Quiet (dim) unless the stick is live.
## Presentation only: it reads the GestureControl, it never drives it.

const CYAN := Color(0.35, 0.95, 1.0)
const PINK := Color(1.0, 0.35, 0.72)
const GOLD := Color(1.0, 0.8, 0.25)
const NAVY := Color(0.02, 0.05, 0.16)
const RED := Color(1.0, 0.25, 0.25)
const SIZE := Vector2(460, 100)
const RING_R := 38.0
## The mini camera view (4:3).
const CAM_RECT := Rect2(8, 6, 117, 88)

var gesture: GestureControl
## Why the robot may not be moved now ("" = it may), from the main scene.
var gate := ""
var _flash := ""
var _flash_left := 0.0
var _t := 0.0
var _cam: TextureRect
var _overlay: GestureCameraOverlay
var _cam_fx: Control
var _hub: CameraHub

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = SIZE
	_cam = TextureRect.new()
	_cam.name = "MiniCamera"
	_cam.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cam.stretch_mode = TextureRect.STRETCH_SCALE
	_cam.position = CAM_RECT.position
	_cam.size = CAM_RECT.size
	_cam.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_cam)
	_overlay = GestureCameraOverlay.new()
	_overlay.compact = true
	_cam.add_child(_overlay)
	_overlay.position = Vector2.ZERO
	_overlay.size = CAM_RECT.size
	# drawn after the camera image: the frame and the edge warnings
	_cam_fx = Control.new()
	_cam_fx.position = CAM_RECT.position
	_cam_fx.size = CAM_RECT.size
	_cam_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_cam_fx)
	_cam_fx.draw.connect(_draw_cam_fx)

## The gesture camera (the overview role) for the mini view.
func attach(hub: CameraHub, flip_h := false, flip_v := false) -> void:
	_hub = hub
	_cam.texture = hub.texture("overview")
	_overlay.flip_h = flip_h
	_overlay.flip_v = flip_v

## Show `text` as the title for a moment ("操縦開始！", "停止").
func flash(text: String, secs := 0.9) -> void:
	_flash = text
	_flash_left = secs

func place(play_w: float, h: float) -> void:
	position = Vector2(16.0, h - SIZE.y - 16.0)
	size = SIZE

func step(dt: float) -> void:
	_t += dt
	_flash_left -= dt
	visible = gesture != null and gesture.enabled
	if visible:
		_overlay.gesture = gesture
		_cam.visible = _hub != null and _hub.has_feed("overview")
		queue_redraw()
		_cam_fx.queue_redraw()

## Robot-axes direction in words (+X 右, +Y 奥).
static func direction_text(v: Vector2) -> String:
	if v.length() < 0.5:
		return ""
	var a := v.normalized()
	var lr := "右" if a.x > 0.38 else ("左" if a.x < -0.38 else "")
	var fb := "奥" if a.y > 0.38 else ("手前" if a.y < -0.38 else "")
	return lr + fb + "へ移動"

## (title, hint) for the current state.
func texts() -> Array[String]:
	var g := gesture
	if _flash_left > 0.0:
		return [_flash, "" if g.state != GestureControl.State.ACTIVE else "手を動かすと進むよ"]
	var out_of_view := g.left_view and not g.detected
	match g.state:
		GestureControl.State.WAITING_HAND:
			if g.reason in ["no_events", "stale", "camera_lost"]:
				return ["カメラを待ってるよ", "backend を --gesture で起動"]
			if g.reason == "multiple_hands":
				return ["手は1つだけにしてね", ""]
			if g.reason == "outside_roi":
				return ["操作エリアに手を入れてね", ""]
			if out_of_view:
				return ["カメラの外に出たよ", "矢印の方へ手を戻してね"]
			return ["手が見えないよ", "カメラに手を見せてね"]
		GestureControl.State.HAND_DETECTED:
			if gate != "":
				return [gate, "準備ができたら、つまんで操縦"]
			return ["🤏 つまんで操縦", "親指と人差し指をつまむ"]
		GestureControl.State.ARMED:
			return ["操縦開始！", ""]
		GestureControl.State.ACTIVE:
			var d := direction_text(g.velocity)
			return [d if d != "" else "操縦中", "カメラの端に近いよ！" if g.edge != Vector2.ZERO else "離すと止まるよ"]
		GestureControl.State.WAITING_RELEASE:
			var title := "停止"
			match g.reason:
				"no_hand", "lost":
					title = "カメラの外に出たよ" if out_of_view else "手が見えないよ"
				"multiple_hands":
					title = "手は1つだけにしてね"
				"outside_roi":
					title = "操作エリアの外だよ"
				"stale", "camera_lost", "no_events":
					title = "認識が途切れたので停止"
				"ws_disconnect":
					title = "通信が切れたので停止"
				"stop_key":
					title = "停止（Space）"
				"manual":
					title = "キーボード操作に切替"
				"release_first", "released", "":
					title = "停止"
				_:
					title = g.reason  # a gate reason, already a sentence
			return [title, "指を離して、もう一度つまんでね"]
	return ["", ""]

func _draw() -> void:
	if gesture == null:
		return
	var g := gesture
	var live := g.state in [GestureControl.State.ARMED, GestureControl.State.ACTIVE]
	var a := 1.0 if live else 0.7
	# pixel-style panel: dark fill, 2 px border, notched corners
	var r := Rect2(Vector2.ZERO, SIZE)
	draw_rect(r, Color(NAVY, 0.78 * a))
	var border := Color(PINK if live else CYAN, (0.95 if live else 0.5))
	draw_rect(r.grow(-1.0), border, false, 2.0)
	for c in [Vector2(0, 0), Vector2(SIZE.x - 4, 0), Vector2(0, SIZE.y - 4), Vector2(SIZE.x - 4, SIZE.y - 4)]:
		draw_rect(Rect2(c, Vector2(4, 4)), Color(NAVY, 1.0))

	# mini camera: a dark frame when there is no picture (the hand dot still shows)
	if not _cam.visible:
		draw_rect(CAM_RECT, Color(0.0, 0.0, 0.0, 0.6))
		for i in range(1, 3):
			var x := CAM_RECT.position.x + CAM_RECT.size.x * i / 3.0
			var y := CAM_RECT.position.y + CAM_RECT.size.y * i / 3.0
			draw_line(Vector2(x, CAM_RECT.position.y), Vector2(x, CAM_RECT.end.y), Color(CYAN, 0.15), 1.0)
			draw_line(Vector2(CAM_RECT.position.x, y), Vector2(CAM_RECT.end.x, y), Color(CYAN, 0.15), 1.0)

	# stick ring
	var c0 := Vector2(CAM_RECT.end.x + 12.0 + RING_R, SIZE.y * 0.5)
	var ring_col := Color(PINK if live else CYAN, 0.9 if live else 0.45)
	for i in range(24):  # dashed, chunky
		var a0 := TAU * i / 24.0
		draw_arc(c0, RING_R, a0, a0 + TAU / 48.0, 3, ring_col, 3.0 if live else 2.0)
	draw_arc(c0, RING_R * g.joystick.deadzone, 0.0, TAU, 16, Color(CYAN, 0.35), 1.0)
	draw_arc(c0, RING_R * g.joystick.full, 0.0, TAU, 32, Color(CYAN, 0.18), 1.0)
	var dot := c0
	if g.joystick.has_anchor and g.detected:
		# the offset in robot axes (after invert / swap, like the arrow), robot +Y up on screen
		var off := g.joystick.to_robot((g.hand - g.joystick.anchor) / maxf(g.joystick.radius, 1e-6))
		dot = c0 + Vector2(off.x, -off.y).limit_length(1.15) * RING_R
	if g.state == GestureControl.State.ACTIVE and g.velocity.length() > 0.5:
		var dir := Vector2(g.velocity.x, -g.velocity.y).normalized()  # robot Y up = screen up
		var tip := c0 + dir * RING_R * 0.85
		draw_line(c0, tip, Color(GOLD, 0.9), 3.0)
		draw_colored_polygon(PackedVector2Array([tip + dir * 7.0, tip + dir.orthogonal() * 5.0, tip - dir.orthogonal() * 5.0]), Color(GOLD, 0.9))
	var dot_col := GOLD if g.pinch else (CYAN if g.detected else Color(0.5, 0.55, 0.7))
	var pulse := 1.0 + (0.25 * sin(_t * 10.0) if g.state == GestureControl.State.ARMED else 0.0)
	draw_rect(Rect2(dot - Vector2(5, 5) * pulse, Vector2(10, 10) * pulse), Color(dot_col, a))

	# texts
	var f := ThemeDB.fallback_font
	var tx := c0.x + RING_R + 14.0
	var t := texts()
	_text(f, Vector2(tx, 34), t[0], 18, Color(PINK if live else Color.WHITE, a))
	_text(f, Vector2(tx, 56), t[1], 12, Color(CYAN, 0.85 * a))
	# speed gauge: 10 chunky segments
	var frac := clampf(g.velocity.length() / maxf(g.joystick.max_speed, 1e-6), 0.0, 1.0)
	var n := int(roundf(frac * 10.0))
	for i in range(10):
		var on := i < n
		var col := (GOLD if i >= 7 else CYAN) if on else Color(CYAN, 0.18)
		draw_rect(Rect2(Vector2(tx + i * 15.0, 72.0), Vector2(11.0, 8.0)), Color(col, a if on else 0.6))
	_text(f, Vector2(tx + 152.0, 81.0), "%2d mm/s" % int(roundf(g.velocity.length())), 11, Color(CYAN, 0.8 * a))

## Over the mini camera: its frame (cyan; yellow when the hand is near an edge;
## blinking red when it left the view, with an arrow at that edge pointing back in).
func _draw_cam_fx() -> void:
	if gesture == null:
		return
	var g := gesture
	var r := Rect2(Vector2.ZERO, CAM_RECT.size)
	var out := g.left_view and not g.detected
	var near := g.detected and g.edge != Vector2.ZERO
	var col := Color(CYAN, 0.6)
	if out:
		col = Color(RED, 0.55 + 0.45 * sin(_t * 12.0))
	elif near:
		col = Color(GOLD, 0.95)
	_cam_fx.draw_rect(r.grow(-1.0), col, false, 3.0 if (out or near) else 1.5)
	if near or out:
		# a thick bar on each edge concerned
		var e := g.edge
		if _overlay.flip_h:
			e.x = -e.x
		if _overlay.flip_v:
			e.y = -e.y
		if e.x != 0.0:
			var x := 0.0 if e.x < 0.0 else r.size.x - 4.0
			_cam_fx.draw_rect(Rect2(x, 0.0, 4.0, r.size.y), col)
		if e.y != 0.0:
			var y := 0.0 if e.y < 0.0 else r.size.y - 4.0
			_cam_fx.draw_rect(Rect2(0.0, y, r.size.x, 4.0), col)
		if out:
			# where it was last seen, and an arrow from there back towards the middle
			var p := _overlay.to_px(g.last_seen).clamp(Vector2(6, 6), r.size - Vector2(6, 6))
			var d := (r.size * 0.5 - p).normalized()
			var tip := p + d * 22.0
			_cam_fx.draw_line(p, tip, Color.WHITE, 2.0)
			_cam_fx.draw_colored_polygon(PackedVector2Array([tip + d * 7.0, tip + d.orthogonal() * 5.0, tip - d.orthogonal() * 5.0]), Color.WHITE)
			_cam_fx.draw_circle(p, 3.0, RED)

func _text(f: Font, p: Vector2, s: String, size_: int, col: Color) -> void:
	if s == "":
		return
	draw_string(f, p + Vector2(1, 1), s, HORIZONTAL_ALIGNMENT_LEFT, SIZE.x - p.x - 6.0, size_, Color(0, 0, 0, col.a * 0.7))
	draw_string(f, p, s, HORIZONTAL_ALIGNMENT_LEFT, SIZE.x - p.x - 6.0, size_, col)

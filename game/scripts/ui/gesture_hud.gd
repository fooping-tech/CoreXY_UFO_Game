class_name GestureHud
extends Control
## Compact hand joystick panel, bottom-left of the play area: hand / pinch
## state, the virtual stick ring with the hand's offset, the direction, a short
## speed gauge and a one-line hint. Quiet (dim) unless the stick is live.
## Presentation only: it reads the GestureControl, it never drives it.

const CYAN := Color(0.35, 0.95, 1.0)
const PINK := Color(1.0, 0.35, 0.72)
const GOLD := Color(1.0, 0.8, 0.25)
const NAVY := Color(0.02, 0.05, 0.16)
const SIZE := Vector2(330, 100)
const RING_R := 38.0

var gesture: GestureControl
## Why the robot may not be moved now ("" = it may), from the main scene.
var gate := ""
var _flash := ""
var _flash_left := 0.0
var _t := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = SIZE

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
		queue_redraw()

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
	match g.state:
		GestureControl.State.WAITING_HAND:
			if g.reason in ["no_events", "stale", "camera_lost"]:
				return ["カメラを待ってるよ", "backend を --gesture で起動"]
			if g.reason == "multiple_hands":
				return ["手は1つだけにしてね", ""]
			if g.reason == "outside_roi":
				return ["操作エリアに手を入れてね", ""]
			return ["手が見えないよ", "カメラに手を見せてね"]
		GestureControl.State.HAND_DETECTED:
			if gate != "":
				return [gate, "準備ができたら、つまんで操縦"]
			return ["🤏 つまんで操縦", "親指と人差し指をつまむ"]
		GestureControl.State.ARMED:
			return ["操縦開始！", ""]
		GestureControl.State.ACTIVE:
			var d := direction_text(g.velocity)
			return [d if d != "" else "操縦中", "離すと止まるよ"]
		GestureControl.State.WAITING_RELEASE:
			var title := "停止"
			match g.reason:
				"no_hand", "lost":
					title = "手が見えないよ"
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

	# stick ring
	var c0 := Vector2(12.0 + RING_R, SIZE.y * 0.5)
	var ring_col := Color(PINK if live else CYAN, 0.9 if live else 0.45)
	for i in range(24):  # dashed, chunky
		var a0 := TAU * i / 24.0
		draw_arc(c0, RING_R, a0, a0 + TAU / 48.0, 3, ring_col, 3.0 if live else 2.0)
	draw_arc(c0, RING_R * g.joystick.deadzone, 0.0, TAU, 16, Color(CYAN, 0.35), 1.0)
	draw_arc(c0, RING_R * g.joystick.full, 0.0, TAU, 32, Color(CYAN, 0.18), 1.0)
	var dot := c0
	if g.joystick.has_anchor and g.detected:
		var off := (g.hand - g.joystick.anchor) / maxf(g.joystick.radius, 1e-6)
		dot = c0 + off.limit_length(1.15) * RING_R
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
	var tx := 12.0 + RING_R * 2.0 + 14.0
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

func _text(f: Font, p: Vector2, s: String, size_: int, col: Color) -> void:
	if s == "":
		return
	draw_string(f, p + Vector2(1, 1), s, HORIZONTAL_ALIGNMENT_LEFT, SIZE.x - p.x - 6.0, size_, Color(0, 0, 0, col.a * 0.7))
	draw_string(f, p, s, HORIZONTAL_ALIGNMENT_LEFT, SIZE.x - p.x - 6.0, size_, col)

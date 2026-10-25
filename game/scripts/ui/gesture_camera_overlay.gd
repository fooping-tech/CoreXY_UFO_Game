class_name GestureCameraOverlay
extends Control
## Drawn over the debug panel's full-frame view of the gesture camera: what the
## hand joystick sees. ROI, the 21 landmarks (when the backend sends them:
## --gesture-landmarks), the palm centre (grey = not detected, cyan = hand,
## gold = pinching), the stick centre with its dead-zone / full-speed / radius
## rings and the offset, and a status line. Debug only; it drives nothing.
##
## The backend's frame and the panel's view are the same camera at the same
## aspect, so normalised image coordinates map straight onto this rect.

const CYAN := Color(0.35, 0.95, 1.0)
const PINK := Color(1.0, 0.35, 0.72)
const GOLD := Color(1.0, 0.8, 0.25)
const GREY := Color(0.6, 0.65, 0.75)
## MediaPipe hand skeleton (landmark index pairs).
const BONES := [[0, 1], [1, 2], [2, 3], [3, 4], [0, 5], [5, 6], [6, 7], [7, 8], [5, 9], [9, 10], [10, 11], [11, 12],
	[9, 13], [13, 14], [14, 15], [15, 16], [13, 17], [0, 17], [17, 18], [18, 19], [19, 20]]

var gesture: GestureControl
## Mirror like the camera view (camera.<role>.flip_h / flip_v).
var flip_h := false
var flip_v := false
## The events come from the mouse, not this camera: draw only the status line.
var simulated := false
## Small version for the game HUD: smaller marks, no status line.
var compact := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not compact:  # the HUD sizes the compact one itself (anchors would override that)
		set_anchors_preset(Control.PRESET_FULL_RECT)

func _process(_dt: float) -> void:
	queue_redraw()

## Normalised image coords -> this rect.
func to_px(n: Vector2) -> Vector2:
	var p := Vector2(1.0 - n.x if flip_h else n.x, 1.0 - n.y if flip_v else n.y)
	return p * size

## Image short-side units (the joystick's) -> this rect.
func short_to_px(u: Vector2) -> Vector2:
	var ev: Dictionary = gesture.last_event
	var w := maxf(float(ev.get("frame_w", 4.0)), 1.0)
	var h := maxf(float(ev.get("frame_h", 3.0)), 1.0)
	var s := minf(w, h)
	return to_px(Vector2(u.x * s / w, u.y * s / h))

func _draw() -> void:
	if gesture == null or not gesture.enabled:
		return
	var g := gesture
	var ev: Dictionary = g.last_event
	var short_px := minf(size.x, size.y)
	if not simulated and not ev.is_empty():
		if g.roi_enabled:
			var a := to_px(g.roi.position)
			var b := to_px(g.roi.end)
			draw_rect(Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), (b - a).abs()), Color(PINK, 0.8), false, 1.5)
		var hands = ev.get("landmarks", [])
		if hands is Array:
			for hand in hands:
				if not (hand is Array) or hand.size() != 21:
					continue
				var pts: Array[Vector2] = []
				for p in hand:
					pts.append(to_px(Vector2(float(p[0]), float(p[1]))))
				var col := Color(GOLD if g.pinch else CYAN, 0.85) if g.detected else Color(GREY, 0.7)
				for bone in BONES:
					draw_line(pts[bone[0]], pts[bone[1]], col, 1.5, true)
				for i in [4, 8]:  # the pinching fingertips
					draw_circle(pts[i], 3.0, col)
		var seen := int(ev.get("hand_count", 0)) > 0 and str(ev.get("reason", "")) != "multiple_hands"
		if seen or g.detected:
			var c := to_px(g.hand_norm)
			var dot := GOLD if g.pinch else (CYAN if g.detected else GREY)
			draw_circle(c, 3.0 if compact else 5.0, dot)
			draw_arc(c, 4.5 if compact else 8.0, 0.0, TAU, 16, Color.BLACK, 1.0)
		if g.joystick.has_anchor:
			var a2 := short_to_px(g.joystick.anchor)
			var r := g.joystick.radius * short_px
			draw_arc(a2, r, 0.0, TAU, 40, Color(PINK, 0.9), 1.5, true)
			draw_arc(a2, r * g.joystick.full, 0.0, TAU, 32, Color(PINK, 0.4), 1.0, true)
			draw_arc(a2, r * g.joystick.deadzone, 0.0, TAU, 16, Color(PINK, 0.6), 1.0, true)
			if g.detected:
				draw_line(a2, to_px(g.hand_norm), Color(GOLD, 0.9), 2.0, true)
	if compact:
		return
	# status line (with a backing so it reads on any image)
	var f := ThemeDB.fallback_font
	var line := "%s%s  hands %d  pinch %s  ratio %.2f" % [g.state_name(), (" (%s)" % g.reason) if g.reason != "" else "",
		int(ev.get("hand_count", 0)), "YES" if g.pinch else "no", g.pinch_ratio]
	if simulated:
		line = "SIM (mouse)  " + line
	draw_rect(Rect2(Vector2.ZERO, Vector2(size.x, 16.0)), Color(0, 0, 0, 0.8))
	var col2 := GOLD if g.state == GestureControl.State.ACTIVE else (CYAN if g.detected else Color.WHITE)
	draw_string(f, Vector2(4.0, 12.0), line, HORIZONTAL_ALIGNMENT_LEFT, size.x - 8.0, 10, col2)

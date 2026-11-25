class_name StudyWorksheetView
extends Control
## The worksheet as it lies on the desk (the mock demo's "camera"), drawn from its
## data: corner marks, the 3 problems, their answer boxes and, once the tracker
## says a box is written, a pencil mark in it. Only the drawing: it never decides.

var worksheet: Dictionary = {}
var tracker: StudyQuestionTracker
var highlight := 0
var caption := ""
## #116: the real sheet from the overview camera, straightened by its four corner marks
## ({tl, tr, bl, br: Vector2 0..1 of the camera image}); empty = the drawn sheet.
var photo_texture: Texture2D
var marks: Dictionary = {}
## #232: read by the local LLM server, the sheet is shown as it is sent: the overview camera's
## frame cut out and turned upright (SheetFrame, the プリント tab's settings). Over the drawing.
var crop_texture: Texture2D
## #237: the answer check's marks, drawn on the picture: number -> {"verdict", "t" (msec shown)}.
## On a photo (crop_texture) a problem's place is mark_boxes[number] ([x1, y1, x2, y2], 0..1000 of
## the picture read); on the drawn sheet it is the worksheet's answer box.
## #237: until the sheet is found: the camera's whole picture (or a desk without one) and where
## to put the sheet (0..1 of the picture; no area = the middle), "ここへおいてね！"
var guide := false
var guide_texture: Texture2D
var guide_region := Rect2()
## #285: why the sheet cannot be read now (the watch's last error), shown under the guide for the
## adult: "" = nothing wrong
var guide_error := ""
const GUIDE_ERROR_MAX := 180
var answer_marks := {}
## #237: the reader is checking the answers now: a scanning beam and "答案を確認中！"
var scanning := false
## #237: the problem being looked at (HELP): its box in the picture ([l, t, r, b], 0..1) and its number
var focus_box: Array = []
var focus_number := 0
var mark_boxes := {}
const MARK_GROW_MS := 420.0
const RED := Color("ff2d2d")
const YELLOW := Color("ffd21f")
const PAGE := Vector2(210.0, 297.0)
const MARKS_MM := {"tl": Vector2(14, 14), "tr": Vector2(196, 14), "bl": Vector2(14, 283), "br": Vector2(196, 283)}
const RECTIFY := preload("res://shaders/sheet_rectify.gdshader")
var _photo: ColorRect
var _mat: ShaderMaterial

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = RECTIFY
	_photo = ColorRect.new()
	_photo.material = _mat
	_photo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_photo.visible = false
	_photo.show_behind_parent = true
	add_child(_photo)

## The real sheet shows (a camera texture and all four marks).
func showing_photo() -> bool:
	return photo_texture != null and marks.size() == 4

## Homography (3x3, as a Basis of its columns) taking the four src points to dst; null when
## they do not fix one (three on a line).
static func homography(src: Array, dst: Array) -> Variant:
	var a: Array = []
	for i in 4:
		var x: float = src[i].x
		var y: float = src[i].y
		var u: float = dst[i].x
		var v: float = dst[i].y
		a.append([x, y, 1.0, 0.0, 0.0, 0.0, -u * x, -u * y, u])
		a.append([0.0, 0.0, 0.0, x, y, 1.0, -v * x, -v * y, v])
	for c in 8:  # Gauss-Jordan with partial pivoting
		var piv := c
		for r in range(c + 1, 8):
			if absf(a[r][c]) > absf(a[piv][c]):
				piv = r
		if absf(a[piv][c]) < 1e-12:
			return null
		var tmp = a[c]
		a[c] = a[piv]
		a[piv] = tmp
		for r in 8:
			if r != c:
				var f: float = a[r][c] / a[c][c]
				for k in range(c, 9):
					a[r][k] -= f * a[c][k]
	var h: Array = []
	for r in 8:
		h.append(a[r][8] / a[r][r])
	# rows (h0 h1 h2 / h3 h4 h5 / h6 h7 1) -> a Basis of the columns (GLSL mat3 is column-major)
	return Basis(Vector3(h[0], h[3], h[6]), Vector3(h[1], h[4], h[7]), Vector3(h[2], h[5], 1.0))

## The page (0..1 across / down) -> the camera image (0..1).
func page_to_image() -> Variant:
	var src: Array = []
	var dst: Array = []
	for k in ["tl", "tr", "bl", "br"]:
		src.append(MARKS_MM[k] / PAGE)
		dst.append(marks[k])
	return homography(src, dst)

func _draw() -> void:
	if worksheet.is_empty():
		_photo.visible = false
		return
	var font := get_theme_default_font()
	var page := PAGE
	var top := 22.0
	if guide:
		_photo.visible = false
		_draw_guide(font, top)
		return
	if crop_texture != null:
		_photo.visible = false
		draw_string(font, Vector2(0, 16), caption, HORIZONTAL_ALIGNMENT_LEFT, size.x, 14, Color("5a2e1a"))
		var tex := Vector2(crop_texture.get_size())
		var k := minf((size.x - 2 * FRAME_PAD) / tex.x, (size.y - top - 2 * FRAME_PAD) / tex.y)
		var shown := Rect2(Vector2((size.x - tex.x * k) * 0.5, top + FRAME_PAD), tex * k)
		_draw_pixel_frame(shown)
		draw_texture_rect(crop_texture, shown, false)
		_draw_marks(func(n: int) -> Rect2: return box_on(shown, mark_boxes.get(n)))
		if scanning:
			_draw_scanning(shown)
		if focus_box.size() == 4:
			_draw_focus(shown)
		return
	var s := minf(size.x / page.x, (size.y - top) / page.y)
	var o := Vector2((size.x - page.x * s) * 0.5, top)
	draw_string(font, Vector2(o.x, 16), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("c8d6f0"))
	var h = page_to_image() if showing_photo() else null
	_photo.visible = h != null
	if h != null:  # the real sheet: the camera draws the paper, the problems and the writing
		_photo.position = o
		_photo.size = page * s
		_mat.set_shader_parameter("cam", photo_texture)
		_mat.set_shader_parameter("page_to_image", h)
		_draw_marks_only(o, s)
		return
	# the drop shadow only under the drawn sheet: the photo is drawn behind this node
	draw_rect(Rect2(o + Vector2(4, 4), page * s), Color(0, 0, 0, 0.35))
	draw_rect(Rect2(o, page * s), Color("fffdf6"))
	for c in [Vector2(14, 14), Vector2(196, 14), Vector2(14, 283), Vector2(196, 283)]:
		draw_rect(Rect2(o + (c - Vector2(6, 6)) * s, Vector2(12, 12) * s), Color.BLACK)
		draw_rect(Rect2(o + (c - Vector2(2, 2)) * s, Vector2(4, 4) * s), Color.WHITE)
	draw_string(font, o + Vector2(28, 28) * s, str(worksheet.get("grade_label", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("1d2433"))
	for p in worksheet.get("problems", []):
		var n := int(p.number)
		var r: Array = p.region_mm
		var rect := Rect2(o + Vector2(r[0], r[1]) * s, Vector2(r[2] - r[0], r[3] - r[1]) * s)
		var hard := str(p.get("difficulty", "")) == "challenge"
		var col := Color("e07a00") if hard else Color("9aa6bb")
		if n == highlight:
			draw_rect(rect.grow(3), Color(1.0, 0.85, 0.2, 0.55))
		draw_rect(rect, col, false, 2.0 if hard else 1.0)
		draw_circle(rect.position + Vector2(7, 8) * s, 5 * s, col if hard else Color("3b7dd8"))
		draw_string(font, rect.position + Vector2(5.2, 10.5) * s, str(n), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color.WHITE)
		draw_string(font, rect.position + Vector2(15, 11) * s, str(p.prompt), HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16 * s, 10, Color("1d2433"))
		var b: Array = p.answer_box_mm
		var box := Rect2(o + Vector2(b[0], b[1]) * s, Vector2(b[2] - b[0], b[3] - b[1]) * s)
		draw_rect(box, Color("1d2433"), false, 1.0)
		if tracker != null:
			var st := tracker.shown_state(n)
			if st == StudyQuestionTracker.FILLED or st == StudyQuestionTracker.WRITING:
				var ans := str(p.get("answer", "")) if st == StudyQuestionTracker.FILLED else "…"
				draw_string(font, box.position + Vector2(4, box.size.y * 0.65), ans, HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 6, 13, Color("3a3f9e"))
			if st == StudyQuestionTracker.HELD:
				draw_rect(box, Color(0.85, 0.65, 0.5, 0.75))
	_draw_marks(func(n: int) -> Rect2: return sheet_box(o, s, n))
	if scanning:
		_draw_scanning(Rect2(o, page * s))

## #237: a pixel-art frame round a camera picture: a wooden marquee with blinking bulbs.
const FRAME_PAD := 16.0
const FRAME_DOT := 4.0
func _draw_pixel_frame(shown: Rect2) -> void:
	var d := FRAME_DOT
	var outer := shown.grow(FRAME_PAD)
	draw_rect(outer.grow(d), Color("4a2412"))  # the dark rim
	draw_rect(outer, Color("c8692a"))  # wood
	for i in range(0, int(outer.size.x / d), 3):  # grain dots along the top and bottom
		draw_rect(Rect2(outer.position + Vector2(i * d, d), Vector2(d, d)), Color("e08a45"))
		draw_rect(Rect2(outer.position + Vector2(i * d + d, outer.size.y - 2 * d), Vector2(d, d)), Color("a9521f"))
	draw_rect(Rect2(outer.position, Vector2(outer.size.x, d)), Color("ffb36b"))  # light on the top edge
	draw_rect(shown.grow(d), Color("2a140a"))  # the picture's inner edge
	# bulbs round the frame, blinking in turn
	var t := Time.get_ticks_msec() / 1000.0
	var step := 26.0
	var n := 0
	var cols := [Color("fff07a"), Color("ff7ab8"), Color("7af0ff")]
	for side in 4:
		var a: Vector2 = [outer.position, outer.position + Vector2(outer.size.x, 0), outer.end, outer.position + Vector2(0, outer.size.y)][side]
		var b: Vector2 = [outer.position + Vector2(outer.size.x, 0), outer.end, outer.position + Vector2(0, outer.size.y), outer.position][side]
		var len := a.distance_to(b)
		var inward := (Vector2(-(b - a).y, (b - a).x).normalized()) * (FRAME_PAD * 0.5)
		var count := int(len / step)
		for j in count:
			var p := a.lerp(b, (j + 0.5) / count) + inward
			var on := int(t * 6.0 + n) % 3 == 0
			var col: Color = cols[n % cols.size()]
			draw_rect(Rect2(p - Vector2(d, d), Vector2(2 * d, 2 * d)), col if on else col.darkened(0.55))
			if on:
				draw_rect(Rect2(p - Vector2(d * 0.5, d * 0.5), Vector2(d, d)), Color.WHITE)
			n += 1
	for c in [outer.position, outer.position + Vector2(outer.size.x, 0), outer.end, outer.position + Vector2(0, outer.size.y)]:
		draw_rect(Rect2(c - Vector2(2 * d, 2 * d), Vector2(4 * d, 4 * d)), Color("ffd21f"))  # gold corners
		draw_rect(Rect2(c - Vector2(d, d), Vector2(2 * d, 2 * d)), Color("fff3a0"))

## Where the guide goes when no place is set (0..1 of the picture).
const GUIDE_DEFAULT := Rect2(0.18, 0.12, 0.64, 0.76)

## "ここへおいてね！" over `target` on any canvas item (the study mode's guide, and the settings
## screen's プリント tab shows exactly this over its live view, #298). `k` scales the lines and text.
static func draw_place(ci: CanvasItem, font: Font, target: Rect2, top: float, t: float, k := 1.0) -> void:
	var pulse := 0.5 + 0.5 * sin(t * 5.0)
	ci.draw_rect(target, Color(1.0, 0.95, 0.55, 0.18 + 0.12 * pulse))
	var col := Color("ff4fa3").lerp(Color("ffd21f"), pulse)
	var w := 6.0 * k
	var corners := [target.position, target.position + Vector2(target.size.x, 0), target.end, target.position + Vector2(0, target.size.y)]
	for i in 4:
		ci.draw_dashed_line(corners[i], corners[(i + 1) % 4], col, w, 14.0 * k)
	var arm := minf(target.size.x, target.size.y) * 0.18
	for i in 4:  # brackets at the corners
		var c: Vector2 = corners[i]
		var sx := 1.0 if i in [0, 3] else -1.0
		var sy := 1.0 if i in [0, 1] else -1.0
		ci.draw_line(c, c + Vector2(arm * sx, 0), Color.WHITE, w + 4.0 * k)
		ci.draw_line(c, c + Vector2(0, arm * sy), Color.WHITE, w + 4.0 * k)
	var bob := 8.0 * k * sin(t * 4.0)
	var text := "ここへおいてね！"
	var fs := maxi(roundi(40 * k), 10)
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var at := Vector2(target.get_center().x - tw * 0.5, target.position.y - 18.0 * k + bob)
	at.y = maxf(at.y, top + fs)
	ci.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, maxi(roundi(12 * k), 2), Color("5a1a3a"))
	ci.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color("fff3a0"))
	var ac := target.get_center() + Vector2(0, bob)  # an arrow into the place
	var a := k
	ci.draw_colored_polygon(PackedVector2Array([ac + Vector2(-26, -30) * a, ac + Vector2(26, -30) * a, ac + Vector2(0, 6) * a]), Color("ff4fa3"))
	ci.draw_colored_polygon(PackedVector2Array([ac + Vector2(-12, -62) * a, ac + Vector2(12, -62) * a, ac + Vector2(12, -30) * a, ac + Vector2(-12, -30) * a]), Color("ff4fa3"))

## Until the sheet is found: the camera's picture in the frame and, over it, where to put the sheet.
func _draw_guide(font: Font, top: float) -> void:
	var tex := Vector2(guide_texture.get_size()) if guide_texture != null else Vector2(4, 3)
	var k := minf((size.x - 2 * FRAME_PAD) / tex.x, (size.y - top - 2 * FRAME_PAD) / tex.y)
	var shown := Rect2(Vector2((size.x - tex.x * k) * 0.5, top + FRAME_PAD), tex * k)
	_draw_pixel_frame(shown)
	if guide_texture != null:
		draw_texture_rect(guide_texture, shown, false)
	else:  # no camera (the simulated mode): a desk
		draw_rect(shown, Color("e0a061"))
		for y in range(0, int(shown.size.y), 18):
			draw_rect(Rect2(shown.position + Vector2(0, y), Vector2(shown.size.x, 2)), Color("c98549"))
	var r := guide_region if guide_region.has_area() else GUIDE_DEFAULT
	var target := Rect2(shown.position + r.position * shown.size, r.size * shown.size)
	var t := Time.get_ticks_msec() / 1000.0
	var pulse := 0.5 + 0.5 * sin(t * 5.0)
	draw_place(self, font, target, top, t)
	# a magnifying glass wanders over the picture, looking for the sheet
	var wander := shown.get_center() + Vector2(sin(t * 0.9) * 0.36 * shown.size.x, sin(t * 1.37 + 1.0) * 0.32 * shown.size.y)
	draw_circle(wander + Vector2(-12, -12), 34.0, Color(1, 1, 1, 0.12 + 0.08 * pulse))
	PowerItemArt.draw(self, "magnifier", wander, 6.0)
	if guide_error != "":
		_draw_guide_error(shown)

## The text of the guide's error box: a line for the child, then the reason for the adult (cut short).
static func guide_error_text(reason: String) -> String:
	var why := reason.strip_edges()
	if why.length() > GUIDE_ERROR_MAX:
		why = why.substr(0, GUIDE_ERROR_MAX - 1) + "…"
	return "プリントを よみとれないよ（大人の人へ）\n" + why

## #285: the reading fails (no AI, a wrong certificate, ...): a red box at the bottom of the picture.
func _draw_guide_error(shown: Rect2) -> void:
	var font := UiFonts.body()
	var fs := 20
	var pad := 12.0
	var w := shown.size.x - 2 * pad - 24.0
	var text := guide_error_text(guide_error)
	var h := font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, w, fs).y
	var box := Rect2(shown.position.x + 12.0, shown.end.y - h - 2 * pad - 12.0, shown.size.x - 24.0, h + 2 * pad)
	draw_rect(box, Color(0.35, 0.03, 0.06, 0.88))
	draw_rect(box, Color("ff5a5a"), false, 3.0)
	draw_multiline_string(font, box.position + Vector2(pad, pad + fs), text, HORIZONTAL_ALIGNMENT_LEFT, w, fs, -1,
		Color("fff3f0"))

## The problem UFOくん goes to look at: a pulsing box on the picture and "Nばん ここ！".
func _draw_focus(shown: Rect2) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	var pulse := 0.5 + 0.5 * sin(t * 6.0)
	var a := Vector2(float(focus_box[0]), float(focus_box[1]))
	var b := Vector2(float(focus_box[2]), float(focus_box[3]))
	var r := Rect2(shown.position + a * shown.size, (b - a) * shown.size).abs().grow(6.0 + 4.0 * pulse)
	draw_rect(r, Color(1.0, 0.3, 0.65, 0.16 + 0.1 * pulse))
	var col := Color("ff4fa3").lerp(Color("7af0ff"), pulse)
	draw_rect(r, col, false, 5.0)
	var font := UiFonts.title()
	var text := "%dばん ここ！" % focus_number if focus_number > 0 else "ここ！"
	var at := Vector2(r.position.x, maxf(r.position.y - 10.0, shown.position.y + 30.0))
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, 10, Color("5a1a3a"))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color("fff3a0"))

## The answers being checked: a beam sweeping up and down the picture, a light veil over it, and
## "答案を確認中！" bouncing at its top (the dots counting).
func _draw_scanning(r: Rect2) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	draw_rect(r, Color(0.3, 0.9, 1.0, 0.08))
	var y := r.position.y + (0.5 + 0.5 * sin(t * 2.6)) * r.size.y
	for i in 6:  # a soft band, brightest in its middle
		var h := 4.0 + 6.0 * i
		draw_rect(Rect2(r.position.x, y - h * 0.5, r.size.x, h), Color(0.45, 0.95, 1.0, 0.07))
	draw_rect(Rect2(r.position.x, y - 2.0, r.size.x, 4.0), Color(0.75, 1.0, 1.0, 0.95))
	var font := UiFonts.title()
	var text := "答案を確認中！" + ".".repeat(1 + int(t * 3.0) % 3)
	var fs := 40
	var w := font.get_string_size("答案を確認中！...", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var at := Vector2(r.get_center().x - w * 0.5, r.position.y + fs + 14.0 + 6.0 * absf(sin(t * 5.0)))
	draw_rect(Rect2(at + Vector2(-18, -fs - 4), Vector2(w + 36, fs + 22)), Color(0.1, 0.05, 0.2, 0.75))
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 10, Color("1a1030"))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color("7af0ff"))

## A [x1, y1, x2, y2] box (0..1000 of a picture) on the picture as shown; no box: Rect2().
static func box_on(shown: Rect2, b) -> Rect2:
	if not b is Array or (b as Array).size() != 4:
		return Rect2()
	var a := Vector2(float(b[0]), float(b[1])) / 1000.0
	var c := Vector2(float(b[2]), float(b[3])) / 1000.0
	return Rect2(shown.position + a * shown.size, (c - a) * shown.size).abs()

## Problem n's answer box on the drawn sheet (page origin o, scale s).
func sheet_box(o: Vector2, s: float, n: int) -> Rect2:
	var p := WorksheetCatalog.problem(worksheet, n)
	if p.is_empty() or not p.get("answer_box_mm") is Array:
		return Rect2()
	var b: Array = p.answer_box_mm
	return Rect2(o + Vector2(b[0], b[1]) * s, Vector2(b[2] - b[0], b[3] - b[1]) * s)

## Where problem n's mark is, in the HUD's (the viewport's) coordinates: the VFX go there.
var _mark_rects := {}
func mark_point(n: int) -> Vector2:
	var r: Rect2 = _mark_rects.get(n, Rect2())
	return global_position + (r.get_center() if r.has_area() else size * 0.5)

## Still drawing a mark: the HUD keeps redrawing.
func animating() -> bool:
	var now := Time.get_ticks_msec()
	for n in answer_marks:
		if now - int(answer_marks[n].get("t", 0)) < MARK_GROW_MS + 50:
			return true
	return false

func _draw_marks(rect_of: Callable) -> void:
	_mark_rects.clear()
	var font := get_theme_default_font()
	var now := Time.get_ticks_msec()
	for n in answer_marks:
		var r: Rect2 = rect_of.call(int(n))
		_mark_rects[n] = r
		if not r.has_area():
			continue
		var k := clampf(float(now - int(answer_marks[n].get("t", now))) / MARK_GROW_MS, 0.0, 1.0)
		match str(answer_marks[n].get("verdict", "")):
			StudyGrading.CORRECT:
				_hand_circle(r, k, int(n))
			StudyGrading.REVIEW:
				draw_dashed_line(r.position, r.position + Vector2(r.size.x, 0), YELLOW, 3.0, 8.0)
				draw_dashed_line(r.end, r.position + Vector2(r.size.x, 0), YELLOW, 3.0, 8.0)
				draw_dashed_line(r.end, r.position + Vector2(0, r.size.y), YELLOW, 3.0, 8.0)
				draw_dashed_line(r.position, r.position + Vector2(0, r.size.y), YELLOW, 3.0, 8.0)
				var fs := int(clampf(r.size.y * 1.4, 28.0, 72.0) * (0.4 + 0.6 * ease(k, -2.0)))
				var at := r.get_center() + Vector2(-fs * 0.3, fs * 0.35)
				draw_string_outline(font, at, "？", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 8, Color("3a2a00"))
				draw_string(font, at, "？", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, YELLOW)
			_:
				var fs2 := int(clampf(r.size.y, 20.0, 40.0))
				draw_string(font, r.get_center() + Vector2(-fs2 * 0.3, fs2 * 0.35), "？", HORIZONTAL_ALIGNMENT_LEFT, -1, fs2,
					Color(0.6, 0.65, 0.75, 0.9))

## A big ○ as if drawn by hand: a slightly wobbly ellipse a little more than once round, growing
## along its stroke while k goes 0 -> 1.
func _hand_circle(r: Rect2, k: float, seed: int) -> void:
	var c := r.get_center()
	var rad := Vector2(maxf(r.size.x * 0.62, 18.0), maxf(r.size.y * 0.75, 18.0))
	var turns := 1.15 * ease(k, 0.4)
	var steps := maxi(int(56 * turns), 2)
	var start := -2.3 + 0.4 * float(seed % 3)
	var pts := PackedVector2Array()
	for i in steps + 1:
		var a := start + TAU * turns * float(i) / steps
		var w := 1.0 + 0.07 * sin(2.0 * a + seed) + 0.035 * sin(5.0 * a + 1.7 * seed)
		w *= 1.0 - 0.06 * float(i) / max(steps, 1)  # the pen ends a little inside where it began
		pts.append(c + Vector2(cos(a) * rad.x, sin(a) * rad.y) * w)
	draw_polyline(pts, Color(1, 1, 1, 0.85), 13.0, true)
	draw_polyline(pts, RED, 8.0, true)

## Over the real sheet: only what the game knows (the problem looked at, a covered answer box).
func _draw_marks_only(o: Vector2, s: float) -> void:
	for p in worksheet.get("problems", []):
		var n := int(p.number)
		var r: Array = p.region_mm
		var rect := Rect2(o + Vector2(r[0], r[1]) * s, Vector2(r[2] - r[0], r[3] - r[1]) * s)
		if n == highlight:
			draw_rect(rect.grow(2), Color(1.0, 0.85, 0.2, 0.9), false, 3.0)
		if tracker != null and tracker.shown_state(n) == StudyQuestionTracker.HELD:
			var b: Array = p.answer_box_mm
			draw_rect(Rect2(o + Vector2(b[0], b[1]) * s, Vector2(b[2] - b[0], b[3] - b[1]) * s), Color(0.85, 0.65, 0.5, 0.45))

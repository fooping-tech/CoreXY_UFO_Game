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

class_name StudyWorksheetView
extends Control
## The worksheet as it lies on the desk (the mock demo's "camera"), drawn from its
## data: corner marks, the 3 problems, their answer boxes and, once the tracker
## says a box is written, a pencil mark in it. Only the drawing: it never decides.

var worksheet: Dictionary = {}
var tracker: StudyQuestionTracker
var highlight := 0
var caption := ""

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	if worksheet.is_empty():
		return
	var font := get_theme_default_font()
	var page := Vector2(210.0, 297.0)
	var top := 22.0
	var s := minf(size.x / page.x, (size.y - top) / page.y)
	var o := Vector2((size.x - page.x * s) * 0.5, top)
	draw_string(font, Vector2(o.x, 16), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("c8d6f0"))
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

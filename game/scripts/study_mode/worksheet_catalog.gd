class_name WorksheetCatalog
extends RefCounted
## The study mode's sample worksheets (config/worksheets.json, made by
## tools/build_worksheets.py; shared with the backend). 12 grades, one worksheet
## each, always 3 problems (3 = the challenge, the HELP target). Millimetres on
## the A4 page, origin top-left.

var data: Dictionary = {}
var loaded_from := ""

static func load_default() -> WorksheetCatalog:
	var c := WorksheetCatalog.new()
	var root := ProjectSettings.globalize_path("res://")
	for path in [root.path_join("../config/worksheets.json").simplify_path(),
			OS.get_executable_path().get_base_dir().path_join("config/worksheets.json"),
			"res://config/worksheets.json"]:
		if FileAccess.file_exists(path):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
			if parsed is Dictionary:
				c.data = parsed
				c.loaded_from = path
				break
	return c

func ok() -> bool:
	return not data.is_empty()

func grades() -> Array:
	return data.get("grades", []) if data.get("grades") is Array else []

func grade_index(grade_id: String) -> int:
	var g := grades()
	for i in g.size():
		if str(g[i].get("id", "")) == grade_id:
			return i
	return -1

func for_grade(grade_id: String) -> Dictionary:
	for ws in data.get("worksheets", []):
		if str(ws.get("grade", "")) == grade_id:
			return ws
	return {}

static func problem(ws: Dictionary, number: int) -> Dictionary:
	for p in ws.get("problems", []):
		if int(p.get("number", 0)) == number:
			return p
	return {}

func paper_mm() -> Vector2:
	var p = data.get("paper_mm", [210.0, 297.0])
	return Vector2(float(p[0]), float(p[1]))

## Centre of a page box [x0, y0, x1, y1] (mm).
static func box_centre(box: Array) -> Vector2:
	return Vector2((float(box[0]) + float(box[2])) * 0.5, (float(box[1]) + float(box[3])) * 0.5)

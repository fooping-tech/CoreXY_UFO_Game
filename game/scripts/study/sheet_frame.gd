class_name SheetFrame
extends RefCounted
## A camera frame made ready for the worksheet reader (#230, #232): the part with the worksheet
## cut out (a rectangle, 0..1 of the frame) and turned upright (0 / 90 / 180 / 270° clockwise).
## Set per camera on the settings screen's プリント tab and kept in user://sheet_check.cfg; the
## study mode uses the same settings for its overview frames (#232).
##
## The reader answers in the image it got; `to_frame` puts such a point back on the whole frame
## (where the camera map and the arm work).

const SETTINGS_PATH := "user://sheet_check.cfg"
const ROTATIONS := [0, 90, 180, 270]
const MIN_REGION_PX := 32

## {role: {"rotation": int, "region": Rect2}} as saved ({} when nothing is).
static func load_settings(path := SETTINGS_PATH) -> Dictionary:
	var out := {}
	if path == "":
		return out
	var cf := ConfigFile.new()
	if cf.load(path) != OK:
		return out
	for role in cf.get_sections():
		var deg := int(cf.get_value(role, "rotation", 0))
		var v = cf.get_value(role, "region", Rect2())
		out[role] = {"rotation": deg if deg in ROTATIONS else 0, "region": v if v is Rect2 else Rect2()}
	return out

static func save_settings(settings: Dictionary, path := SETTINGS_PATH) -> void:
	if path == "":
		return
	var cf := ConfigFile.new()
	for role in settings:
		var s: Dictionary = settings[role]
		cf.set_value(role, "rotation", int(s.get("rotation", 0)))
		cf.set_value(role, "region", s.get("region", Rect2()))
	cf.save(path)

## The settings of one camera ({"rotation": 0, "region": Rect2()} = the whole frame as it is).
static func for_role(role: String, path := SETTINGS_PATH) -> Dictionary:
	return load_settings(path).get(role, {"rotation": 0, "region": Rect2()})

## Whether `part` is used for an image of `size` (a region too small sends the whole frame).
static func region_px(size: Vector2i, part: Rect2) -> Rect2i:
	var sz := Vector2(size)
	var r := Rect2i(Rect2(part.position * sz, part.size * sz).abs()).intersection(Rect2i(Vector2i.ZERO, size))
	if part.has_area() and r.size.x >= MIN_REGION_PX and r.size.y >= MIN_REGION_PX:
		return r
	return Rect2i(Vector2i.ZERO, size)

## The frame -> what is sent: the region cut out, then turned clockwise by `deg`.
static func prepare(img: Image, deg: int, part: Rect2) -> Image:
	var r := region_px(img.get_size(), part)
	var out: Image = img.get_region(r) if r.size != img.get_size() else img.duplicate()
	match deg:
		90:
			out.rotate_90(CLOCKWISE)
		180:
			out.rotate_180()
		270:
			out.rotate_90(COUNTERCLOCKWISE)
	return out

## A point (0..1) of the image `prepare` made from a frame of `size` -> the same point (0..1) of
## that frame.
static func to_frame(p: Vector2, deg: int, part: Rect2, size: Vector2i) -> Vector2:
	var q := p
	match deg:
		90:  # the frame's top-left went to the top-right
			q = Vector2(p.y, 1.0 - p.x)
		180:
			q = Vector2(1.0 - p.x, 1.0 - p.y)
		270:  # the frame's top-left went to the bottom-left
			q = Vector2(1.0 - p.y, p.x)
	var r := region_px(size, part)
	var sz := Vector2(size)
	return (Vector2(r.position) + q * Vector2(r.size)) / sz

class_name SheetFrame
extends RefCounted
## A camera frame made ready for the worksheet reader (#230, #232): the part with the worksheet
## cut out (a rectangle, 0..1 of the frame) and turned upright (0 / 90 / 180 / 270° clockwise).
## Set per camera on the settings screen's プリント tab and kept in user://sheet_check.cfg; the
## study mode uses the same settings for its overview frames (#232).
##
## The reader answers in the image it got; `to_frame` puts such a point back on the whole frame
## (where the camera map and the arm work).
##
## #298 (the reader's hand-off, §3.1: a fixed camera): the frame is no longer cut here. `request`
## turns the whole frame upright and gives the region as `roi` (0..1000 of that image); the server
## cuts it out, and the backend puts the boxes back into the region's own 0..1000, so what comes
## back is still "in the image `prepare` makes" (the ○ drawn on it, `to_frame`). `place` is where the
## child puts the sheet ("ここへおいてね！" in the study mode); the region should be a little wider
## (`region_around`: 5% on each side), as the hand-off asks.

const SETTINGS_PATH := "user://sheet_check.cfg"
const ROTATIONS := [0, 90, 180, 270]
const MIN_REGION_PX := 32
## the server's roi: at least 50 of 1000 wide and tall (else 400)
const ROI_MIN := 50
## the hand-off: a long side past ~1600-2000 px does not read better (the server shrinks to ~0.65 MP)
const SEND_EDGE := 2000
## JPEG quality: >= 90 (strong compression smears the thin handwriting)
const SEND_QUALITIES := [0.95, 0.92, 0.9]
## the region around the place: this much of the place's size on each side
const PLACE_MARGIN := 0.05

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
		var pl = cf.get_value(role, "place", Rect2())
		out[role] = {"rotation": deg if deg in ROTATIONS else 0, "region": v if v is Rect2 else Rect2(),
			"place": pl if pl is Rect2 else Rect2()}
	return out

static func save_settings(settings: Dictionary, path := SETTINGS_PATH) -> void:
	if path == "":
		return
	var cf := ConfigFile.new()
	for role in settings:
		var s: Dictionary = settings[role]
		cf.set_value(role, "rotation", int(s.get("rotation", 0)))
		cf.set_value(role, "region", s.get("region", Rect2()))
		cf.set_value(role, "place", s.get("place", Rect2()))
	cf.save(path)

## The settings of one camera ({"rotation": 0, "region": Rect2(), "place": Rect2()} = the whole
## frame as it is, no place set).
static func for_role(role: String, path := SETTINGS_PATH) -> Dictionary:
	return load_settings(path).get(role, {"rotation": 0, "region": Rect2(), "place": Rect2()})

## Where the study mode shows "ここへおいてね！" (0..1 of the frame): the place, else the region
## (as before #298), else nothing (the view's own middle).
static func guide_rect(settings: Dictionary) -> Rect2:
	var pl = settings.get("place", Rect2())
	if pl is Rect2 and pl.has_area():
		return pl
	var rg = settings.get("region", Rect2())
	return rg if rg is Rect2 and rg.has_area() else Rect2()

## The region the reader looks at for a place: PLACE_MARGIN of its size wider on each side.
static func region_around(place: Rect2, margin := PLACE_MARGIN) -> Rect2:
	if not place.has_area():
		return Rect2()
	return place.abs().grow_individual(place.size.x * margin, place.size.y * margin,
		place.size.x * margin, place.size.y * margin).intersection(Rect2(0, 0, 1, 1))

## Whether `part` is used for an image of `size` (a region too small sends the whole frame: under
## MIN_REGION_PX, or (#298, review on #300) narrower or shorter than the server's roi minimum, so
## the request, what is shown and `to_frame` all fall back to the whole frame together).
static func region_px(size: Vector2i, part: Rect2) -> Rect2i:
	var sz := Vector2(size)
	var r := Rect2i(Rect2(part.position * sz, part.size * sz).abs()).intersection(Rect2i(Vector2i.ZERO, size))
	var min_w := maxi(MIN_REGION_PX, ceili(size.x * (ROI_MIN + 1) / 1000.0))
	var min_h := maxi(MIN_REGION_PX, ceili(size.y * (ROI_MIN + 1) / 1000.0))
	if part.has_area() and r.size.x >= min_w and r.size.y >= min_h:
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

## A rectangle (0..1 of a frame) -> the same one in that frame turned clockwise by `deg`.
static func turn_rect(r: Rect2, deg: int) -> Rect2:
	var a := r.position
	var b := r.end
	var pts: Array[Vector2] = []
	for p in [a, b]:
		match deg:
			90:  # (x, y) -> (1 - y, x)
				pts.append(Vector2(1.0 - p.y, p.x))
			180:
				pts.append(Vector2(1.0 - p.x, 1.0 - p.y))
			270:  # (x, y) -> (y, 1 - x)
				pts.append(Vector2(p.y, 1.0 - p.x))
			_:
				pts.append(p)
	return Rect2(pts[0], pts[1] - pts[0]).abs()

## The region as the server's roi on the frame turned by `deg` ([x1, y1, x2, y2], 0..1000), or []
## when the whole frame is read (no region, one too small for the frame, or under ROI_MIN).
static func roi_of(size: Vector2i, deg: int, part: Rect2) -> Array:
	var r := region_px(size, part)
	if r.size == size:
		return []
	var t := turn_rect(Rect2(Vector2(r.position) / Vector2(size), Vector2(r.size) / Vector2(size)), deg)
	var roi := [roundi(t.position.x * 1000.0), roundi(t.position.y * 1000.0), roundi(t.end.x * 1000.0), roundi(t.end.y * 1000.0)]
	for i in 4:
		roi[i] = clampi(roi[i], 0, 1000)
	if roi[2] - roi[0] < ROI_MIN or roi[3] - roi[1] < ROI_MIN:
		return []
	return roi

## #298: what is sent for a frame: {"image": the whole frame turned upright, "roi": roi_of (maybe
## []), "shown": what the answer's boxes are about (`prepare`: the region cut out, turned upright)}.
static func request(img: Image, deg: int, part: Rect2) -> Dictionary:
	var whole := prepare(img, deg, Rect2())
	var roi := roi_of(img.get_size(), deg, part)
	return {"image": whole, "roi": roi, "shown": prepare(img, deg, part) if not roi.is_empty() else whole}

## The JPEG sent to the reader (#298): not shrunk below SEND_EDGE, quality >= 90; only when that is
## more than `byte_limit` (the WebSocket's room), smaller steps at quality 90. Empty = it cannot be.
static func encode(source: Image, byte_limit: int) -> PackedByteArray:
	if source == null or source.is_empty():
		return PackedByteArray()
	var image := source.duplicate()
	var edge := maxi(image.get_width(), image.get_height())
	if edge > SEND_EDGE:
		var k := float(SEND_EDGE) / float(edge)
		image.resize(maxi(1, roundi(image.get_width() * k)), maxi(1, roundi(image.get_height() * k)), Image.INTERPOLATE_LANCZOS)
	while true:
		for q in SEND_QUALITIES:
			var bytes: PackedByteArray = image.save_jpg_to_buffer(q)
			if not bytes.is_empty() and bytes.size() <= byte_limit:
				return bytes
		if maxi(image.get_width(), image.get_height()) <= 640:
			return PackedByteArray()
		image.resize(maxi(1, roundi(image.get_width() * 0.85)), maxi(1, roundi(image.get_height() * 0.85)), Image.INTERPOLATE_LANCZOS)
	return PackedByteArray()

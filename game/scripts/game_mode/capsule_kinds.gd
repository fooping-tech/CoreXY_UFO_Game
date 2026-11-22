class_name CapsuleKinds
extends RefCounted
## The capsule kinds (#266): what colour the capsule the crane lifted is, and what that makes
## it on the field.
##
##   red    fire   ファイヤーボールカプセル   fast and fierce: kicks harder, hits score more
##   blue   water  ウォーターボールカプセル   slow and floating: stays longer, the goal scores more
##   green  green  グリーンボールカプセル     bouncy and lucky: bounces high, everything a bit more
##   (none) normal the capsule as it always was
##
## The colour is read from the arm camera (the focus role) while the capsule hangs in front of
## it: classify() judges one frame (the ROI's saturated pixels by hue), a Reader collects the
## frames' votes, and the capsule taken into the portal gets the kind most of them saw. Nothing
## sure enough = normal. This is presentation only: it never decides anything for the crane
## and is never sent anywhere.
##
## The values are tuning values (config game_mode.capsule_kinds), the thresholds of the colour
## reading are not measured on the real camera yet (実機未検証).

const KINDS := ["normal", "fire", "water", "green"]
const NAMES := {"normal": "カプセル", "fire": "ファイヤーボールカプセル", "water": "ウォーターボールカプセル",
	"green": "グリーンボールカプセル"}
## the one line under the name in the collection show
const TRAITS := {"fire": "はやい！ あてると とくてん アップ", "water": "ゆっくり ふわふわ… ゴールで とくてん アップ",
	"green": "よく はねる！ ぜんぶ ちょっと アップ"}
const COLORS := {"fire": Color("ff4a2a"), "water": Color("3f8cff"), "green": Color("3fe06a")}
## what each kind changes (k = times the field's own value; bounce = the capsule's own):
##   gravity_k  how hard it falls       damp     how much the air slows it
##   kick_k     bumpers, pops, slings   stay_k   how long it may stay on the field
##   hit_k      points of a hit         goal_k   points of the goal
##   bounce     its bounciness (< 0 = the field's)
const DEFAULTS := {
	"normal": {"gravity_k": 1.0, "bounce": -1.0, "damp": 0.05, "kick_k": 1.0, "stay_k": 1.0, "hit_k": 1.0, "goal_k": 1.0},
	"fire": {"gravity_k": 1.15, "bounce": 0.6, "damp": 0.02, "kick_k": 1.35, "stay_k": 0.85, "hit_k": 2.0, "goal_k": 1.0},
	"water": {"gravity_k": 0.6, "bounce": 0.25, "damp": 0.9, "kick_k": 0.8, "stay_k": 1.4, "hit_k": 1.0, "goal_k": 2.0},
	"green": {"gravity_k": 0.8, "bounce": 0.8, "damp": 0.05, "kick_k": 1.1, "stay_k": 1.15, "hit_k": 1.3, "goal_k": 1.3},
}
## The colour reading's defaults (config game_mode.capsule_kinds.read):
##   roi        the part of the frame looked at (fractions of its size)
##   min_sat / min_val   a pixel counts only this saturated and this bright (0..1)
##   min_share  a colour must cover this much of the ROI's looked-at pixels
##   dominance  ... and this many times more than the next colour
##   hues       [from, to] of each colour (0..1; red wraps round: [0.93, 0.045])
##   sample_hz  frames read per second while a capsule may be in front of the camera
##   min_votes / min_ratio   the kind of the capsule: this many frames saw it, this share of
##              the frames that saw a colour at all
const READ := {"roi": [0.2, 0.15, 0.6, 0.7], "min_sat": 0.45, "min_val": 0.25, "min_share": 0.05, "dominance": 1.6,
	"hues": {"fire": [0.93, 0.045], "green": [0.22, 0.45], "water": [0.53, 0.72]},
	"sample_hz": 6.0, "min_votes": 3, "min_ratio": 0.6}
const SHEET_DIR := "res://assets/capsules/"
## the sprite's frame (tools/build_capsule_sprites.py; row 1 the capsule, row 2 the kind's part):
## its size and the capsule's radius in it
const FRAME := 32
const BODY_R := 11.0
const FPS := 10.0

var params := {}
var read := {}
static var _sheets := {}

func _init() -> void:
	configure({})

## config game_mode.capsule_kinds: {"<kind>": {...}, "read": {...}}; anything left out keeps
## its default, and every value is kept in a sane range.
func configure(cfg: Dictionary) -> void:
	params = {}
	for kind in KINDS:
		var p: Dictionary = (DEFAULTS[kind] as Dictionary).duplicate()
		var c: Dictionary = cfg.get(kind, {}) if cfg.get(kind) is Dictionary else {}
		for key in p.keys():
			if c.has(key):
				p[key] = float(c[key])
		p.gravity_k = clampf(p.gravity_k, 0.2, 3.0)
		p.bounce = clampf(p.bounce, -1.0, 1.2)
		p.damp = clampf(p.damp, 0.0, 5.0)
		p.kick_k = clampf(p.kick_k, 0.2, 3.0)
		p.stay_k = clampf(p.stay_k, 0.3, 3.0)
		p.hit_k = clampf(p.hit_k, 0.0, 5.0)
		p.goal_k = clampf(p.goal_k, 0.0, 5.0)
		params[kind] = p
	read = READ.duplicate(true)
	var r: Dictionary = cfg.get("read", {}) if cfg.get("read") is Dictionary else {}
	for key in r.keys():
		if read.has(key):
			read[key] = r[key]

## The values of `kind` (normal's for an unknown one).
func of(kind: String) -> Dictionary:
	return params.get(kind, params["normal"])

static func known(kind: String) -> bool:
	return kind in KINDS

static func display_name(kind: String) -> String:
	return str(NAMES.get(kind, NAMES["normal"]))

## The kind's colour; `fallback` (the Dial's) for normal.
static func color_of(kind: String, fallback: Color) -> Color:
	return COLORS.get(kind, fallback)

# ------------------------------------------------------------------ the colour of one frame
## Which colour fills the ROI of `img`: {"kind": "fire" / "water" / "green" / "", "share": the
## winner's share of the looked-at pixels, "counts": {kind: pixels}}. "" = no colour sure
## enough (too little of it, or two colours close together). Every step-th pixel is looked
## at (about 80 across), so a whole camera frame costs little.
static func classify(img: Image, cfg := {}) -> Dictionary:
	var out := {"kind": "", "share": 0.0, "counts": {"fire": 0, "water": 0, "green": 0}}
	if img == null or img.is_empty():
		return out
	var c: Dictionary = READ.duplicate(true)
	c.merge(cfg, true)
	var w := img.get_width()
	var h := img.get_height()
	var roi: Array = c.roi
	var x0 := clampi(int(w * float(roi[0])), 0, w - 1)
	var y0 := clampi(int(h * float(roi[1])), 0, h - 1)
	var x1 := clampi(int(w * (float(roi[0]) + float(roi[2]))), x0 + 1, w)
	var y1 := clampi(int(h * (float(roi[1]) + float(roi[3]))), y0 + 1, h)
	var step := maxi(1, (x1 - x0) / 80)
	var looked := 0
	var counts: Dictionary = out.counts
	var hues: Dictionary = c.hues
	for y in range(y0, y1, step):
		for x in range(x0, x1, step):
			looked += 1
			var p := img.get_pixel(x, y)
			if p.s < float(c.min_sat) or p.v < float(c.min_val):
				continue
			for kind in hues.keys():
				var r: Array = hues[kind]
				var lo := float(r[0])
				var hi := float(r[1])
				var hit := (p.h >= lo or p.h <= hi) if lo > hi else (p.h >= lo and p.h <= hi)
				if hit:
					counts[kind] = int(counts.get(kind, 0)) + 1
					break
	if looked == 0:
		return out
	var best := ""
	var best_n := 0
	var second_n := 0
	for kind in counts.keys():
		var n := int(counts[kind])
		if n > best_n:
			second_n = best_n
			best_n = n
			best = kind
		elif n > second_n:
			second_n = n
	var share := float(best_n) / looked
	out.share = share
	if best != "" and share >= float(c.min_share) and best_n >= float(c.dominance) * second_n:
		out.kind = best
	return out

## The frames' votes while one capsule hangs in front of the camera.
class Reader:
	extends RefCounted
	## [kind or "", the time it was seen]
	var votes: Array = []
	var clock := 0.0
	## only the votes of this many seconds back count
	var memory_s := 20.0

	func advance(dt: float) -> void:
		clock += dt

	func add(kind: String) -> void:
		votes.append([kind, clock])
		while votes.size() > 400:
			votes.remove_at(0)

	func clear() -> void:
		votes.clear()

	## How many frames saw `kind` (any colour: "*") in the memory.
	func count(kind := "*") -> int:
		var n := 0
		for v in votes:
			if clock - float(v[1]) <= memory_s and str(v[0]) != "" and (kind == "*" or str(v[0]) == kind):
				n += 1
		return n

	## The kind of the capsule: the colour most frames saw, when at least min_votes saw it and
	## it is min_ratio of the frames that saw any colour; else "normal".
	func decide(min_votes: int, min_ratio: float) -> String:
		var any := count()
		var best := "normal"
		var best_n := 0
		for kind in ["fire", "water", "green"]:
			var n := count(kind)
			if n > best_n:
				best_n = n
				best = kind
		if best_n < maxi(min_votes, 1) or any <= 0 or float(best_n) / any < min_ratio:
			return "normal"
		return best

# ------------------------------------------------------------------ the pictures
## The kind's sprite sheet (null for normal, or when it cannot be loaded: the plain capsule
## is drawn then).
static func sheet(kind: String) -> Texture2D:
	if kind == "normal" or not kind in KINDS:
		return null
	if not _sheets.has(kind):
		var path := SHEET_DIR + kind + ".png"
		_sheets[kind] = load(path) if ResourceLoader.exists(path) else null
	return _sheets[kind]

static func frames_of(tex: Texture2D) -> int:
	return maxi(1, int(tex.get_width()) / FRAME) if tex != null else 0

## Draws the capsule of `kind` at `pos`, `k` times the field's capsule size, animated by `t`
## (seconds). The capsule turns by `rot` (the ball's own rotation, like the plain capsule); the
## kind's part (flames, drops, sprout: the sheet's second row) stays upright on it.
## Returns false when there is no sprite (the caller draws the plain capsule).
static func draw(ci: CanvasItem, kind: String, pos: Vector2, k: float, t: float, rot := 0.0, halo := true) -> bool:
	var tex := sheet(kind)
	if tex == null:
		return false
	var n := frames_of(tex)
	var f := int(floor(t * FPS)) % n
	var px := (PinballField.CAPSULE_R + 1.0) / BODY_R * k  # screen pixels per sprite pixel
	var size := Vector2(FRAME, FRAME) * px
	# the capsule's centre is the middle of pixel (16, 18) of its frame
	var off := -Vector2(16.5, 18.5) * px
	if halo:
		var col: Color = COLORS[kind]
		ci.draw_circle(pos, (PinballField.CAPSULE_R + 8.0) * k, Color(col.r, col.g, col.b, 0.2))
	ci.draw_set_transform(pos, rot)
	ci.draw_texture_rect_region(tex, Rect2(off, size), Rect2(f * FRAME, 0, FRAME, FRAME))
	ci.draw_set_transform(Vector2.ZERO)
	if tex.get_height() >= FRAME * 2:
		ci.draw_texture_rect_region(tex, Rect2(pos + off, size), Rect2(f * FRAME, FRAME, FRAME, FRAME))
	return true

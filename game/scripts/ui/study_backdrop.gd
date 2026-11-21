class_name StudyBackdrop
extends Node2D
## The study mode's background (#237): a bright, warm pixel-art scene drawn in code (no image
## file) at W x H dots, scaled up to the screen with nearest-neighbour filtering. Behind the
## rope and the UFO, over the starfield; shown only while the study mode runs (main.gd).
##   sky    : light yellow to peach to pink, dithered between the bands
##   sun    : big and soft at the top right, clouds, twinkling stars and maths signs
##   bottom : far hills and a wooden desk (the worksheet's place)

const W := 180
const H := 320
const SKY := [Color("fff1b0"), Color("ffe08a"), Color("ffc978"), Color("ffb07a"), Color("ff9a86")]
const SUN := [Color("fffbe6"), Color("fff0a8"), Color("ffd66b")]
const CLOUD := Color("fffaf0")
const CLOUD_SHADE := Color("ffe2c8")
const HILL := [Color("ffb38a"), Color("f59a7c")]
const DESK := [Color("e0a061"), Color("c98549"), Color("a96a36")]
const SIGN := Color(1.0, 1.0, 1.0, 0.55)
## 5 x 5 maths signs floating in the sky
const SIGNS := {
	"+": ["..#..", "..#..", "#####", "..#..", "..#.."],
	"-": [".....", ".....", "#####", ".....", "....."],
	"x": ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
	"=": [".....", "#####", ".....", "#####", "....."],
	"/": ["..#..", ".....", "#####", ".....", "..#.."],
}

var texture: ImageTexture
var _t := 0.0
var _stars: Array = []  # [Vector2 dot, phase]

func _ready() -> void:
	z_index = -9  # over the starfield (-10), behind the rope and the UFO
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	texture = ImageTexture.create_from_image(paint())
	var rng := RandomNumberGenerator.new()
	rng.seed = 2370
	for i in 26:
		_stars.append([Vector2(rng.randi_range(4, W - 5), rng.randi_range(6, 180)), rng.randf() * TAU])

## The scene, dot by dot (also the tests' entry).
static func paint() -> Image:
	var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
	var bands := SKY.size()
	var sky_h := 250
	for y in H:
		for x in W:
			var k := float(y) / sky_h * (bands - 1)
			var i := mini(int(k), bands - 2)
			var f := k - i
			# ordered dithering between two bands
			var bayer: float = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]][y % 4][x % 4] / 16.0
			img.set_pixel(x, y, SKY[i + 1] if f > bayer else SKY[i])
	# the sun, soft rings
	var sc := Vector2i(138, 52)
	for y in range(sc.y - 30, sc.y + 31):
		for x in range(sc.x - 30, sc.x + 31):
			if x < 0 or x >= W or y < 0:
				continue
			var d := Vector2(x - sc.x, y - sc.y).length()
			if d <= 17.0:
				img.set_pixel(x, y, SUN[0] if d < 13.0 else SUN[1])
			elif d <= 22.0 and (x + y) % 2 == 0:
				img.set_pixel(x, y, SUN[2])
	# clouds: rows of round puffs
	for c in [[20, 40, 26], [58, 92, 20], [110, 120, 30], [14, 150, 18], [130, 190, 22]]:
		_cloud(img, c[0], c[1], c[2])
	# far hills
	for x in W:
		var h1 := 232 + int(8.0 * sin(x * 0.06) + 4.0 * sin(x * 0.17))
		var h2 := 244 + int(6.0 * sin(x * 0.045 + 1.3))
		for y in range(h1, H):
			img.set_pixel(x, y, HILL[0])
		for y in range(h2, H):
			img.set_pixel(x, y, HILL[1])
	# the desk: planks with grain
	for y in range(258, H):
		for x in W:
			var c2: Color = DESK[0]
			if (y - 258) % 14 == 0:
				c2 = DESK[2]
			elif ((x * 7 + y * 3) % 23) == 0:
				c2 = DESK[1]
			img.set_pixel(x, y, c2)
	for x in W:  # the desk's front edge catches the light
		img.set_pixel(x, 258, Color("f3c088"))
	# maths signs in the sky
	var rng := RandomNumberGenerator.new()
	rng.seed = 86
	var keys := SIGNS.keys()
	for i in 9:
		var at := Vector2i(rng.randi_range(4, W - 10), rng.randi_range(70, 215))
		var rows: Array = SIGNS[keys[i % keys.size()]]
		for yy in 5:
			for xx in 5:
				if str(rows[yy])[xx] == "#":
					var p := at + Vector2i(xx, yy)
					img.set_pixel(p.x, p.y, img.get_pixelv(p).lerp(Color.WHITE, SIGN.a))
	return img

static func _cloud(img: Image, x0: int, y0: int, w: int) -> void:
	for i in range(0, w, 6):
		var r := 5 + (i * 7) % 4
		var cx := x0 + i
		var cy := y0 - (r if i > 0 and i < w - 6 else r - 2)
		for y in range(cy - r, cy + r + 1):
			for x in range(cx - r, cx + r + 1):
				if x < 0 or x >= img.get_width() or y < 0 or y >= img.get_height():
					continue
				if Vector2(x - cx, y - cy).length() <= r:
					img.set_pixel(x, y, CLOUD if y < cy + r - 2 else CLOUD_SHADE)

func _process(dt: float) -> void:
	if visible:
		_t += dt
		queue_redraw()

func _draw() -> void:
	var vs := get_viewport_rect().size
	var k := maxf(vs.x / W, vs.y / H)
	var size := Vector2(W, H) * k
	var at := (vs - size) * 0.5
	draw_texture_rect(texture, Rect2(at, size), false)
	for s in _stars:  # twinkles
		var a := 0.5 + 0.5 * sin(_t * 2.6 + float(s[1]))
		if a < 0.35:
			continue
		var p: Vector2 = at + (s[0] as Vector2) * k
		var c := Color(1, 1, 1, a)
		draw_rect(Rect2(p - Vector2(k, 0), Vector2(k * 3, k)), c)
		draw_rect(Rect2(p - Vector2(0, k), Vector2(k, k * 3)), c)

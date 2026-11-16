class_name PixelText
extends RefCounted
## A 5 x 7 pixel font drawn with rectangles (#141): the score game's numbers and arcade
## words (SCORE, TIME, 1000, JACKPOT, the logo) stay crisp pixel art at any size, with no
## font file to license. Latin capitals, digits and a few signs only: Japanese text stays
## on the game's normal labels.
##
##   PixelText.draw(canvas_item, "1000", top_left, 3.0, Color.YELLOW, Color.BLACK)

const W := 5
const H := 7
## one pixel column between letters
const GAP := 1
const GLYPHS := {
	"A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
	"B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
	"C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
	"D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
	"E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
	"F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
	"G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###."],
	"H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
	"I": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"],
	"J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
	"K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
	"L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
	"M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
	"N": ["#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"],
	"O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
	"P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
	"Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
	"R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
	"S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
	"T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
	"U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
	"V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
	"W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#"],
	"X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
	"Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
	"Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
	"0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
	"1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
	"2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
	"3": ["####.", "....#", "....#", ".###.", "....#", "....#", "####."],
	"4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
	"5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
	"6": [".###.", "#....", "#....", "####.", "#...#", "#...#", ".###."],
	"7": ["#####", "....#", "...#.", "..#..", "..#..", "..#..", "..#.."],
	"8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
	"9": [".###.", "#...#", "#...#", ".####", "....#", "....#", ".###."],
	"+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
	"-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
	":": [".....", "..#..", "..#..", ".....", "..#..", "..#..", "....."],
	"!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
	".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
	"x": [".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
	">": ["#....", ".#...", "..#..", "...#.", "..#..", ".#...", "#...."],
	"<": ["....#", "...#.", "..#..", ".#...", "..#..", "...#.", "....#"],
	"/": ["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."],
	"?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
	" ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
}
const OUTLINE_DIRS := [Vector2(-1, -1), Vector2(0, -1), Vector2(1, -1), Vector2(-1, 0), Vector2(1, 0),
	Vector2(-1, 1), Vector2(0, 1), Vector2(1, 1)]

## Every character has a glyph.
static func supports(text: String) -> bool:
	for i in text.length():
		if not GLYPHS.has(text[i]):
			return false
	return true

static func width(text: String, scale: float) -> float:
	return maxf(text.length() * (W + GAP) - GAP, 0) * scale

static func height(scale: float) -> float:
	return H * scale

## Draws `text` with its top-left corner at `pos`. outline (a colour or null): a one-pixel
## rim around every letter, so it reads on any background.
static func draw(ci: CanvasItem, text: String, pos: Vector2, scale: float, color: Color, outline = null) -> void:
	if outline is Color:
		for d in OUTLINE_DIRS:
			_run(ci, text, pos + d * scale, scale, outline)
	_run(ci, text, pos, scale, color)

static func draw_centered(ci: CanvasItem, text: String, centre: Vector2, scale: float, color: Color, outline = null) -> void:
	draw(ci, text, centre - Vector2(width(text, scale), height(scale)) * 0.5, scale, color, outline)

static func draw_right(ci: CanvasItem, text: String, top_right: Vector2, scale: float, color: Color, outline = null) -> void:
	draw(ci, text, top_right - Vector2(width(text, scale), 0), scale, color, outline)

## Only the glyphs' rows `from` .. `to` - 1 (0 = the top row), in place: a highlight along
## the top of big numbers, a shadow along the bottom.
static func draw_rows(ci: CanvasItem, text: String, pos: Vector2, scale: float, color: Color, from: int, to: int) -> void:
	_run(ci, text, pos, scale, color, from, to)

## The text with every pixel grown by `grow` px on all sides: the solid shape round big
## letters (their holes filled when `grow` is half a hole), for a body or a rim behind them.
static func draw_grown(ci: CanvasItem, text: String, pos: Vector2, scale: float, color: Color, grow: float) -> void:
	_run(ci, text, pos, scale, color, 0, H, grow)

## One pass of the text in one colour; each row's runs of pixels are one rectangle.
static func _run(ci: CanvasItem, text: String, pos: Vector2, scale: float, color: Color, row_from := 0, row_to := H, grow := 0.0) -> void:
	var x := pos.x
	for i in text.length():
		var g = GLYPHS.get(text[i])
		if g != null and text[i] != " ":
			for row in range(maxi(row_from, 0), mini(row_to, H)):
				var line: String = g[row]
				var start := -1
				for col in W + 1:
					var on: bool = col < W and line[col] == "#"
					if on and start < 0:
						start = col
					elif not on and start >= 0:
						ci.draw_rect(Rect2(x + start * scale - grow, pos.y + row * scale - grow, (col - start) * scale + 2.0 * grow,
							scale + 2.0 * grow), color)
						start = -1
		x += (W + GAP) * scale

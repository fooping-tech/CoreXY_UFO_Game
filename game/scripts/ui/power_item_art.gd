class_name PowerItemArt
extends RefCounted
## The power-ups as pixel-art items (#237): 16 x 16 dots drawn in code (no image file), for the
## study mode's power roulette and its "GET!!". Each letter of a row is a dot's colour ("." none).
##   speed     : a lightning bolt
##   double    : a gold coin with "x2"
##   multiball : three balls
##   magnifier : a magnifying glass (the study mode looking for the sheet)
##   clock     : an alarm clock (the reward's TIME)
##   ticket    : a golden ticket (the reward's POWER TICKET)

const SIZE := 16
const PALETTE := {
	"O": Color("1a1030"),  # outline
	"Y": Color("ffd21f"),  # gold / yellow
	"L": Color("fff3a0"),  # light yellow
	"D": Color("c98a00"),  # dark gold
	"W": Color("ffffff"),
	"R": Color("ff3b5c"),
	"P": Color("ff4fd8"),
	"C": Color("3ff0ff"),
	"B": Color("1f8fff"),
	"G": Color("7cff6b"),
	"K": Color("8a93a6"),  # the lens' metal rim
	"E": Color("c8f6ff"),  # glass
	"M": Color("a0522d"),  # a wooden handle
}
const SPRITES := {
	"speed": [
		"........OOOOOO..",
		".......OYYYYYO..",
		"......OYLYYYO...",
		".....OYLYYYO....",
		"....OYLYYYO.....",
		"...OYYYYYYOOOO..",
		"..OYYYYYYYYYYO..",
		"..OOOOOYYYYYO...",
		"......OYYYYO....",
		".....OYYYYO.....",
		"....OYYYYO......",
		"...OYYYO........",
		"..OYYO..........",
		"..OYO...........",
		"..OO............",
		"................",
	],
	"double": [
		".....OOOOOO.....",
		"...OOYYYYYYOO...",
		"..OYYLLYYYYYYO..",
		".OYYLYYYYYYYYDO.",
		".OYLYYYYYYYYYDO.",
		"OYYYRYRYRRRYYYDO",
		"OYYYRYRYYYRYYYDO",
		"OYYYYRYYRRRYYYDO",
		"OYYYRYRYRYYYYYDO",
		"OYYYRYRYRRRYYYDO",
		".OYYYYYYYYYYYDO.",
		".OYYYYYYYYYYDDO.",
		"..ODYYYYYYYDDO..",
		"...OODDDDDDOO...",
		".....OOOOOO.....",
		"................",
	],
	"multiball": [
		"......OOOO......",
		".....OPPPPO.....",
		"....OPWPPPPO....",
		"....OPPPPPPO....",
		"....OPPPPPPO....",
		".....OPPPPO.....",
		"..OOOOOOOOOOOO..",
		".OCCCCO..OGGGGO.",
		"OCWCCCCOOGWGGGGO",
		"OCCCCCCOOGGGGGGO",
		"OCCCCBCOOGGGGGGO",
		".OCCBBO..OGGGGO.",
		"..OOOO....OOOO..",
		"................",
		"................",
		"................",
	],
	"clock": [
		"..OO........OO..",
		".ORRO......ORRO.",
		".ORO.OOOOOO.ORO.",
		"..O.ORRRRRRO.O..",
		"...ORWWWWWWRO...",
		"..ORWWWOWWWWRO..",
		"..ORWWWOWWWWRO..",
		".ORWWWWOWWWWWRO.",
		".ORWWWWOOOOWWRO.",
		".ORWWWWWWWWWWRO.",
		"..ORWWWWWWWWRO..",
		"..ORWWWWWWWWRO..",
		"...ORRRRRRRRO...",
		"..OO.OOOOOO.OO..",
		".OO..........OO.",
		"................",
	],
	"ticket": [
		"................",
		"................",
		".OOOOOOOOOOOOOO.",
		".OYYYYYYYYYYYYO.",
		".OYDDDDDDDDDDYO.",
		"OYYDYYYWYYYYDYYO",
		"O.YDYYWWWYYYDY.O",
		".OYDYWWWWWYYDYO.",
		"O.YDYYWWWYYYDY.O",
		"OYYDYYWYWYYYDYYO",
		".OYDDDDDDDDDDYO.",
		".OYYYYYYYYYYYYO.",
		".OOOOOOOOOOOOOO.",
		"................",
		"................",
		"................",
	],
	"magnifier": [
		"...OOOOO........",
		"..OKKKKKO.......",
		".OKEEWWEKO......",
		"OKEEWEEEEKO.....",
		"OKEWEEEEEKO.....",
		"OKEEEEEEEKO.....",
		"OKEEEEEEEKO.....",
		"OKEEEEEEEKO.....",
		".OKEEEEEKO......",
		"..OKKKKKOO......",
		"...OOOOOMMO.....",
		"........OMMO....",
		".........OMMO...",
		"..........OMMO..",
		"...........OMO..",
		"............OO..",
	],
}

## Draws `kind` on `ci` (inside its draw), centred at `centre`, one dot = `px` pixels.
static func draw(ci: CanvasItem, kind: String, centre: Vector2, px: float, alpha := 1.0) -> void:
	var rows: Array = SPRITES.get(kind, [])
	var origin := centre - Vector2(SIZE, SIZE) * px * 0.5
	for y in rows.size():
		var row: String = rows[y]
		for x in row.length():
			var c: Color = PALETTE.get(row[x], Color(0, 0, 0, 0))
			if c.a <= 0.0:
				continue
			c.a *= alpha
			ci.draw_rect(Rect2(origin + Vector2(x, y) * px, Vector2(px, px)), c)

class_name GameModeLayout
extends RefCounted
## Where everything of the score game sits on the portrait screen (#157, docs/game_mode_spec.md
## §4): one place for the numbers, so the field, the HUD, the effects, the result and the
## ranking agree. Design space 720 x 1280 (9:16); the pixel canvas is 360 x 640 shown at 2x,
## so one dot is 2 design px (3 screen px on a 1080 x 1920 monitor, 6 on 2160 x 3840).
##
## From the top:
##   HUD        y    0 ..  114   SCORE (left), TIME (right)
##   STATUS     y  130 ..  242   the hand (left), the combo (middle), the arm camera (right)
##   RAIL       y  250 ..  352   UFOくん going left and right
##   FIELD      y  352 .. 1100   the pinball field, tall
##   DIALS      y 1100 .. 1280   Dial 1's port bottom left, Dial 2's bottom right
##
## Dial 1 is the left of the screen and Dial 2 the right, as the real Dials stand beside
## the monitor. Nothing here is a robot coordinate: this is the picture only.

const SCREEN := Vector2(720, 1280)
const PIXEL_SIZE := Vector2i(360, 640)
const DOT_PX := 2.0
const CX := 360.0

# ---- HUD
const SCORE_RECT := Rect2(12, 10, 340, 104)
const TIME_RECT := Rect2(368, 10, 340, 104)
## the staff's key hint, small, over the status row
const HINT_Y := 116.0

# ---- the status row: the hand, the combo, the arm camera
const STATUS_Y := 130.0
const GESTURE_RECT := Rect2(12, 130, 232, 112)
const SCOPE_RECT := Rect2(476, 130, 232, 112)
## the combo and the jackpot notice, between the two panels
const COMBO_RECT := Rect2(252, 130, 216, 112)

# ---- UFOくん's rail
const UFO_Y := 298.0

# ---- the pinball field (PinballField has its own layout of what is in it)
const FIELD_LEFT := 30.0
const FIELD_RIGHT := 690.0
const FIELD_TOP := 352.0
const FIELD_FLOOR := 1066.0

# ---- the Dial's port (#200: the left one only; the right of this band is empty sky)
const DIALS_Y := 1100.0
const PORTS := {"left": Vector2(92, 1192)}
## each port's line of words (what that Dial is doing)
const LANE_LABEL_Y := 1112.0

# ---- what comes up over the field
## the middle of the field: banners, the countdown, "GO!"
const CENTRE := Vector2(360, 640)
## the result's huge number, and the ranking's "NEW RECORD!"
const RESULT_CENTRE := Vector2(360, 600)
## the widest a line of big pixel letters may be
const SAFE_W := 680.0

## The dot size that makes `text` as wide as it can be within `max_w`, even, at most `most`.
static func fit_scale(text: String, max_w: float, most: float, least := 2.0) -> float:
	var cols := float(maxi(text.length(), 1) * (PixelText.W + PixelText.GAP) - PixelText.GAP)
	return clampf(floorf(max_w / cols / 2.0) * 2.0, least, most)

## The x of a Dial's side of the screen, just off it (the light runs out to the real Dial).
static func dial_edge(side: String) -> Vector2:
	return Vector2(-10.0 if side == "left" else SCREEN.x + 10.0, (PORTS[side] as Vector2).y)

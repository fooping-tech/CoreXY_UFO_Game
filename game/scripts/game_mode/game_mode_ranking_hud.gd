class_name GameModeRankingHud
extends GameModeShowScreen
## The high scores on the screen (#155, docs/game_mode_spec.md §3.3): "NEW RECORD!" when a
## round made the top ten, then the board, HIGH SCORES, the ten places. Only a place and a
## score are ever shown: no name, no avatar, nothing typed.
##
## It reads the controller (ranking_view: "" / "record" / "board", the round's rank) and the
## RankingManager's rows; it decides nothing. Like the result screen, the picture is in the
## game mode's pixel canvas (the field's dots, even sizes only) and the Japanese lines are
## labels on top. The sparks are a GameModeParticles pool, the sheets go through VFXManager.

## Portrait (#157): the board fills the middle of the tall screen, under the HUD and the
## status row.
const CENTRE := GameModeLayout.RESULT_CENTRE
const TITLE := "HIGH SCORES"
const TITLE_Y := 276.0
## "NEW RECORD!" on two lines: [the words, the top of the line]
const NEW_RECORD := [["NEW", 330.0], ["RECORD!", 452.0]]
const NEW_RECORD_SCALE := 14.0
## the ground line of the new record's confetti sheet
const CONFETTI_Y := 960.0
## the board's plate and its rows: the first three are bigger
const PLATE := Rect2(40, 356, 640, 752)
const ROWS_Y := 384.0
const TOP_STEP := 88.0
const STEP := 64.0
const TOP_SCALE := 10.0
const ROW_SCALE := 6.0
## the right edges of the two columns (the place, the score), and the widest a score may be
const RANK_X := 176.0
const SCORE_X := 618.0
const SCORE_W := 410.0
const EMPTY := "---"
const GOLD := Color("ffd23c")
const SILVER := Color("d8e0f0")
const BRONZE := Color("e0915a")
const REST := Color("b8f4ff")
const YELLOW := Color("ffe03c")
const CYAN := Color("3ff0ff")
const MAGENTA := Color("ff4fd8")

var _place: Label
var _note: Label
var _keys: Label

func setup(c: GameModeController) -> void:
	# over the HUD's panels and the result's lines; the picture over the result's picture
	_build_art(c, 31, "RankingArt", 41, "RankingParticles")
	_place = _label(120, YELLOW, 600.0, 170.0)
	_note = _label(20, Color("c8d6ff"), 1116.0, 30.0)
	_keys = _label(24, Color.WHITE, 1154.0, 38.0)

# ------------------------------------------------------------------ what is on
## "" / "record" (NEW RECORD!) / "board" (HIGH SCORES).
func mode() -> String:
	return ctl.ranking_view if ctl != null and ctl.active() else ""

## The words under "NEW RECORD!".
func place_text() -> String:
	return "第 %d 位！" % ctl.ranking_rank if ctl.ranking_rank > 0 else ""

static func rank_color(rank: int) -> Color:
	match rank:
		1:
			return GOLD
		2:
			return SILVER
		3:
			return BRONZE
	return REST

## The top of a row and its dot size.
static func row_y(rank: int) -> float:
	return ROWS_Y + TOP_STEP * minf(rank - 1, 3) + STEP * maxf(rank - 4, 0)

static func row_scale(rank: int) -> float:
	return TOP_SCALE if rank <= 3 else ROW_SCALE

## The board as text, one line a place ("1  13565", "10  ---"): what a player reads, and
## all a player is shown of a record (tests read it).
func board_lines() -> Array[String]:
	var out: Array[String] = []
	for r in ctl.ranking.rows():
		out.append("%d  %s" % [int(r.rank), str(int(r.score)) if int(r.score) > 0 else EMPTY])
	return out

## The line under the board: this round's score when it is not on the board, and a file
## that could not be written (the ranking is then only kept until the game closes).
func note_text() -> String:
	var parts: Array[String] = []
	if ctl.phase == "RESULT":
		match ctl.ranking_note:
			"out":
				parts.append("今回のスコア  %d　（ランキングには とどかなかった）" % ctl.final_score())
			"zero":
				parts.append("今回のスコア  0")
			"demo":
				parts.append("今回のスコア  %d　（デモは 記録しない）" % ctl.final_score())
			"short":
				parts.append("今回のスコア  %d　（短いラウンドは 記録しない）" % ctl.final_score())
	if ctl.ranking.save_error != "":
		parts.append("ランキングを保存できなかった: %s" % ctl.ranking.save_error)
	return "　".join(parts)

func keys_text() -> String:
	match mode():
		"record":
			return "Enter：ランキングへ"
		"board":
			return "Enter：もう一回      T：練習から      Esc：タイトル" if ctl.phase != "IDLE" \
				else "Enter：スタート      R：もどる      Esc：タイトル"
	return ""

func _process(dt: float) -> void:
	if ctl == null:
		return
	_t += dt
	var m := mode()
	art.visible = m != ""
	visible = m != ""
	if m == "":
		return
	_back.queue_redraw()
	_front.queue_redraw()
	_place.text = place_text() if m == "record" else ""
	_place.pivot_offset = _place.size * 0.5
	_place.scale = Vector2.ONE * (1.0 + (0.06 * sin(_t * 9.0) if ctl.effects else 0.0))
	_note.text = note_text() if m == "board" else ""
	_keys.text = keys_text()
	_keys.modulate.a = 0.75 + 0.25 * sin(_t * 5.0)

# ------------------------------------------------------------------ drawing
func _draw_back() -> void:
	var m := mode()
	if m == "":
		return
	_back.draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0.01, 0.02, 0.08, 0.9))
	if m == "record" and ctl.effects:
		_draw_rays(CENTRE, _t * 1.1, [CYAN, MAGENTA, GOLD], 0.22)
	elif m == "board":
		# the board's plate: dark glass with a neon rim, like the HUD's panels
		var plate := PLATE
		PinballField.glow_rect(_back, plate, CYAN, 0.5)
		_back.draw_rect(plate.grow(4.0), DARK)
		_back.draw_rect(plate, Color(0.03, 0.05, 0.16, 0.94))
		_back.draw_rect(plate, CYAN, false, 2.0)
		_back.draw_rect(Rect2(plate.position + Vector2(6, 6), Vector2(plate.size.x - 12.0, 2)), Color(1, 1, 1, 0.18))

func _draw_front() -> void:
	match mode():
		"record":
			_draw_record()
		"board":
			_draw_board()

## "NEW RECORD!", on two lines: the letters jump in one after another and keep flashing.
func _draw_record() -> void:
	var sc := NEW_RECORD_SCALE
	var step := (PixelText.W + PixelText.GAP) * sc
	var age := ctl.ranking_view_t
	var n := 0
	for line in NEW_RECORD:
		var words: String = line[0]
		var x0 := SCREEN.x * 0.5 - PixelText.width(words, sc) * 0.5
		for i in words.length():
			n += 1
			var lt := age - 0.04 * n
			if ctl.effects and lt < 0.0:
				continue
			var dy := 0.0
			if ctl.effects:
				dy = -60.0 * exp(-8.0 * lt) * cos(lt * 15.0) + sin(_t * 7.0 + n * 0.6) * 5.0
			var col: Color = [YELLOW, CYAN, MAGENTA][(n + int(_t * 8.0)) % 3] if ctl.effects else YELLOW
			var p := Vector2(x0 + step * i, float(line[1]) + dy).snapped(Vector2(2, 2))
			PixelText.draw_grown(_front, words[i], p, sc, DARK, sc)
			PixelText.draw(_front, words[i], p + Vector2(sc * 0.5, sc * 0.5), sc, Color(MAGENTA.r, MAGENTA.g, MAGENTA.b, 0.9))
			PixelText.draw(_front, words[i], p, sc, Color.WHITE if ctl.effects and lt < 0.08 else col)

## HIGH SCORES and the ten places. This round's place glows and blinks.
func _draw_board() -> void:
	var ts := 8.0
	var tw := PixelText.width(TITLE, ts)
	var tp := Vector2(SCREEN.x * 0.5 - tw * 0.5, TITLE_Y)
	PixelText.draw(_front, TITLE, tp + Vector2(4, 4), ts, Color(MAGENTA.r, MAGENTA.g, MAGENTA.b, 0.9))
	PixelText.draw(_front, TITLE, tp, ts, YELLOW, DARK)
	_front.draw_rect(Rect2(tp.x, tp.y + PixelText.height(ts) + 8.0, tw, 2), CYAN)
	var mine := ctl.ranking_rank if ctl.phase == "RESULT" else 0
	for r in ctl.ranking.rows():
		var rank := int(r.rank)
		var sc := row_scale(rank)
		var y := row_y(rank)
		var col := rank_color(rank)
		var has := int(r.score) > 0
		var text := str(int(r.score)) if has else EMPTY
		if rank == mine:
			# the neon behind this round's row, and the letters blinking to white
			var pulse := 0.5 + 0.5 * sin(_t * 9.0) if ctl.effects else 1.0
			var row := Rect2(PLATE.position.x + 8.0, y - 8.0, PLATE.size.x - 16.0, PixelText.height(sc) + 16.0)
			PinballField.glow_rect(_front, row, MAGENTA, 0.5 + 0.5 * pulse)
			_front.draw_rect(row, Color(MAGENTA.r, MAGENTA.g, MAGENTA.b, 0.2 + 0.15 * pulse))
			_front.draw_rect(row, YELLOW.lerp(Color.WHITE, pulse), false, 2.0)
			if ctl.effects and int(_t * 6.0) % 2 == 0:
				col = Color.WHITE
			PixelText.draw(_front, ">", Vector2(PLATE.position.x + 14.0 + 4.0 * pulse, y + (PixelText.height(sc) - 28.0) * 0.5).snapped(Vector2(2, 2)), 4.0, YELLOW, DARK)
			PixelText.draw(_front, "NEW", Vector2(SCORE_X + 12.0, y + (PixelText.height(sc) - 14.0) * 0.5).snapped(Vector2(2, 2)), 2.0, YELLOW, DARK)
		PixelText.draw_right(_front, str(rank), Vector2(RANK_X, y), sc, col if has else Color(col.r, col.g, col.b, 0.45), DARK)
		var ssc := minf(sc, GameModeLayout.fit_scale(text, SCORE_W, sc))  # a very long score is drawn smaller, never over the place
		PixelText.draw_right(_front, text, Vector2(SCORE_X, y + (PixelText.height(sc) - PixelText.height(ssc)) * 0.5), ssc, col if has else Color(REST.r, REST.g, REST.b, 0.35), DARK)

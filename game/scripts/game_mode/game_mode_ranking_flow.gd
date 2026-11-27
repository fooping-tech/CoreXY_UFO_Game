class_name GameModeRankingFlow
extends RefCounted
## The score game's high scores as they come up after a round (#155), and today's best
## (#183): what GameModeController does with RankingManager and GameModeRankingHud, taken out
## of it (#222). Presentation and a file: no device hears of it, the score is not changed.
##
## What the screens read stays on the controller (ranking_view, ranking_view_t, ranking_rank,
## ranking_note, ranking_enabled, ...); this holds only the flow's own step and timer.

var ctl: GameModeController
var state := ""  # "" (not offered yet) / "hold" / "record" / "done"
var _t := 0.0
## #183: the best score of today (this machine's date): of the ranking's records, and of the
## rounds played since the game was started that did not get into it. 0 = none yet.
var _today_date := ""
var _today_best := 0

func _init(c: GameModeController) -> void:
	ctl = c

## The result's show is over: the round's final score is offered to the ranking, by
## itself (no one types anything), once. Then "NEW RECORD!" when it made the top ten, then
## the board. Presentation and a file: no device hears of it, the score is not changed.
func tick(dt: float) -> void:
	ctl.ranking_view_t += dt
	if ctl.phase != "RESULT":
		return
	match state:
		"":
			if ctl.result_show.settled():
				register_score()
				_t = ctl.rank_hold_s  # the final score stands a moment longer
				state = "hold" if ctl.ranking_enabled else "done"
		"hold":
			_t -= dt
			if _t <= 0.0:
				show_rank()
		"record":
			_t -= dt
			if _t <= 0.0:
				show_board()

## Why this round is not offered to the ranking ("" = it is): only a round played to its
## end by people counts. STOPPED and the practice never come here (they have no result).
func excluded() -> String:
	if not ctl.ranking_enabled:
		return "off"
	if ctl.ranking_force:
		return ""
	if ctl.demo:
		return "demo"
	if ctl.duration_s < ctl._full_duration_s - 0.01:
		return "short"  # a round shortened from the command line (a rehearsal)
	return ""

func register_score() -> void:
	ctl.ranking_rank = 0
	ctl.ranking_note = excluded()
	var final := ctl.final_score()
	if ctl.ranking_note == "" and final <= 0:
		ctl.ranking_note = "zero"
	if ctl.ranking_note == "":
		note_today(final)  # also when it does not get into the ranking
	if ctl.ranking_note == "":
		ctl.ranking_rank = ctl.ranking.submit(final, ctl.round_id)
		if ctl.ranking_rank == 0:
			ctl.ranking_note = "out"
	ctl._trace("ranking", null, {"score_delta": final, "result": ("rank %d" % ctl.ranking_rank) if ctl.ranking_rank > 0 else ctl.ranking_note})
	ctl.trace.close()

func show_rank() -> void:
	if ctl.ranking_rank <= 0 or not ctl.effects:
		show_board()  # not a record (or no effects): straight to the board
		return
	ctl.ranking_view = "record"
	ctl.ranking_view_t = 0.0
	state = "record"
	_t = ctl.rank_record_s
	ctl.result_screen.clear()
	# every part of the celebration starts in this one tick
	var c := GameModeRankingHud.CENTRE
	var rp := ctl.ranking_hud.particles
	var k := 1.0 - 0.06 * (ctl.ranking_rank - 1)  # the higher the place, the more of everything
	# #328: 「ジャン！」 and a crowd cheering and clapping (they were the synthesised new_record
	# and the jackpot fanfare)
	ctl.sounds.play("result_jan")
	ctl.sounds.play("cheer")
	ctl._shake(0.6 + 0.4 * k)
	ctl.bounce(1.2 + 0.8 * k)
	ctl.hitstop(GameModeController.HITSTOP_MAX_S)
	rp.ring(c, Color("ffd23c"), 620.0, 0.8, 80.0)
	rp.ring(c, Color("3ff0ff"), 460.0, 0.65, 60.0)
	rp.ring(c, Color("ff4fd8"), 320.0, 0.5, 40.0)
	rp.burst(c, Color("ffe03c"), int(50 + 40 * k), 600.0)
	var cols := [Color("ffe03c"), Color("3ff0ff"), Color("ff4fd8")]
	for i in 6:
		rp.burst(Vector2(ctl._rng.randf_range(60.0, GameModeLayout.SCREEN.x - 60.0), ctl._rng.randf_range(-10.0, 160.0)), cols[i % 3], 14, 300.0, PI * 0.5, PI * 0.9, 0.15)
	ctl.ranking_hud.art.visible = true  # (it is shown from this tick: the sheets go on it now)
	ctl.ranking_hud.sheet("success_sparkle", c, 5.0)
	ctl.ranking_hud.sheet("success_confetti", Vector2(c.x, GameModeRankingHud.CONFETTI_Y), 3.0)
	ctl.fx.react("big")
	ctl.backdrop.pulse(Color("ffd23c"), 1.0)

func show_board() -> void:
	ctl.ranking_view = "board"
	ctl.ranking_view_t = 0.0
	state = "done"
	ctl.result_screen.clear()
	ctl.ranking_hud.clear()
	ctl.sounds.play("goal")

## R on the score game's title: the board, and back.
func toggle() -> void:
	if ctl.phase != "IDLE":
		return
	ctl.ranking_view = "" if ctl.ranking_view != "" else "board"
	ctl.ranking_view_t = 0.0
	if ctl.ranking_view == "board":
		ctl.ranking.load_file()  # as it is on the disk now
		ctl.sounds.play("goal")

## A result is being left before its show was over (Enter then T, T, Esc): the round was
## played to its end, so its score is still offered to the ranking, quietly.
func flush() -> void:
	if ctl.phase == "RESULT" and state == "" and not ctl.result.is_empty():
		register_score()
		state = "done"

func clear_view() -> void:
	ctl.ranking_view = ""
	ctl.ranking_view_t = 0.0
	ctl.ranking_rank = 0
	ctl.ranking_note = ""
	state = ""
	_t = 0.0
	if ctl.ranking_hud != null:
		ctl.ranking_hud.clear()

## #352: the settings screen's ランキングを消す. The records, their file and today's best are
## gone ("" = done; else why the file could not be removed, and nothing changed). A screen
## and a file only: no device hears of it.
func wipe() -> String:
	var why := ctl.ranking.wipe()
	if why != "":
		return why
	_today_date = ""
	_today_best = 0
	ctl.ranking_rank = 0
	ctl.ranking_note = ""
	return ""

func today_best() -> int:
	var d := Time.get_date_string_from_system()
	var best := _today_best if _today_date == d else 0
	if ctl.ranking != null:
		for e in ctl.ranking.entries:
			if str(e.get("timestamp", "")).begins_with(d):
				best = maxi(best, int(e.get("score", 0)))
	return best

func note_today(score: int) -> void:
	var d := Time.get_date_string_from_system()
	if _today_date != d:
		_today_date = d
		_today_best = 0
	_today_best = maxi(_today_best, score)

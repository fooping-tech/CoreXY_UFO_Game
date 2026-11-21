class_name StudyModeController
extends Node
## UFOくん 勉強モード (#86): the experience as one state machine.
##
##   INTRO -> WAITING_FOR_WORKSHEET -> STUDYING
##   STUDYING --HELP (Y, or 1 / 2 / 3 fingers then a thumbs-up: #136)--> HELP_LOCATING -> HELP_MOVING -> CAPTURE_10CM -> CAPTURE_5CM
##            -> CAPTURE_LANDING -> AI_EXPLAINING -> RESUME_STUDY -> STUDYING
##   STUDYING --3 problems stably filled / grown-up's Enter--> the answer check (#236, #237):
##            ANSWER_CHECK_READY -> SHEET_SCANNING -> GRADING_QUESTION (one problem at a time, from 1)
##            -> REVIEW_SUMMARY (only when something is to be looked at again)
##                 --R: rewritten--> RESCAN -> GRADING_QUESTION (the ones not yet right) -> ...
##                 --Enter--> REWARD_CALCULATING
##            -> REWARD_REVEAL -> POWERUP_SELECT (a power ticket: a roulette picks it) -> CLEANUP -> GAME_READY_WITH_REWARD
##            --"ゲームで遊ぶ"--> (off; the reward is handed over: StudyGrading.reward)
##   CLEANUP --fault--> CLEANUP_FAILED --Enter--> GAME_READY_WITH_REWARD (tidy-up left unchecked)
##   any motion fault / stop --> ERROR --Enter--> STUDYING (never moves again by itself)
##
## Separate from the machine: this node never writes RobotState and never sends a
## robot command itself. Motion is asked of StudyServices (one backend sequence
## under its motion lock, or the game's mock); readings, the explanation and the
## voice come back from it as signals. The presentation (HUD, UFO faces, VFX,
## sounds) follows `state` and the events posted to GameState ("study_*").

signal state_changed(previous: String, current: String)
signal changed  # anything shown changed (HUD refresh)

const STATES := ["OFF", "INTRO", "WAITING_FOR_WORKSHEET", "STUDYING", "HELP_LOCATING", "HELP_MOVING",
	"CAPTURE_10CM", "CAPTURE_5CM", "CAPTURE_LANDING", "AI_EXPLAINING", "RESUME_STUDY", "ANSWER_CHECK_READY",
	"SHEET_SCANNING", "GRADING_QUESTION", "REVIEW_SUMMARY", "RESCAN", "REWARD_CALCULATING", "REWARD_REVEAL",
	"POWERUP_SELECT", "CLEANUP", "CLEANUP_FAILED", "GAME_READY_WITH_REWARD", "ERROR"]
## #237: the answer check, and the reward that follows it
const CHECK_STATES := ["ANSWER_CHECK_READY", "SHEET_SCANNING", "GRADING_QUESTION", "REVIEW_SUMMARY", "RESCAN"]
const REWARD_STATES := ["REWARD_CALCULATING", "REWARD_REVEAL", "POWERUP_SELECT"]
const POWERUPS := [["speed", "SPEED UP"], ["double", "DOUBLE SCORE"], ["multiball", "MULTI BALL"]]
const CAPTURE_STATE := {"10cm": "CAPTURE_10CM", "5cm": "CAPTURE_5CM", "landing": "CAPTURE_LANDING"}
const HELP_STATES := ["HELP_LOCATING", "HELP_MOVING", "CAPTURE_10CM", "CAPTURE_5CM", "CAPTURE_LANDING"]
const FAILURES := ["", "locate", "motion", "ai", "voice", "occlude", "grade", "cleanup"]
const FAILURE_LABEL := {"": "なし", "locate": "位置の特定", "motion": "アームの停止", "ai": "AI の解説",
	"voice": "音声", "occlude": "手で隠れる", "grade": "答え合わせの読み取り", "cleanup": "片付け"}

var main: Node
var services: StudyServices
var speech: StudySpeech
## #233: the voice dialogue (push to talk -> Whisper -> the tutor)
var voice: StudyVoice
var sounds: StudySounds
var tracker := StudyQuestionTracker.new()
var catalog: WorksheetCatalog
var state := "OFF"
var grade_index := 3
var worksheet: Dictionary = {}
var weekday_label := "月曜日"
var help_problem := 3  # the problem the current / last HELP looks at
var default_help_problem := 3  # Y's problem (study_mode.help.problem)
var help_keycode := KEY_Y
## #136: 1 / 2 / 3 fingers held to the overview camera offer help with that problem
## ("教えてあげようか？"), a thumbs-up held then starts it. study_mode.hand_help.
const COUNT_POSES := {"point": 1, "peace": 2, "three": 3}
var hand_help_enabled := true
var hand_hold_ms := 600.0
var hand_offer_s := 12.0
var offer_problem := 0  # offered and waiting for a thumbs-up (0 = none)
var _offer_until_ms := 0.0
var _hand_pose := ""
var _hand_since_ms := -1.0
var _hand_used := ""  # a pose already acted on: nothing more until the hand changes
## keys of the study mode (study_mode.keys); the game's own keys stay as they are
var keys := {"advance": KEY_ENTER, "fill_1": KEY_1, "fill_2": KEY_2, "fill_3": KEY_3, "grade_prev": KEY_COMMA,
	"grade_next": KEY_PERIOD, "skip": KEY_F6, "inject": KEY_F7, "reset": KEY_F8, "toggle": KEY_F5, "rescan": KEY_R}
## #237: the answer check
var grading := StudyGrading.new()
var grade_checking_s := 0.9  # "かくにん中…" before a problem's verdict
var grade_reveal_s := 2.5  # one problem's whole turn
var reveal_queue: Array[int] = []
var reveal_current := 0  # the problem being shown now (0 = none)
var shown := {}  # number -> true once its verdict was shown
var combo := 0  # right answers shown in a row (the HUD's COMBO)
## the power ticket's roulette: the light goes round the powers, slows down and stops on one
var roulette_index := -1  # the power lit now (-1 = not turning)
var roulette_spinning := false
var roulette_force := ""  # tests / a demo: where it stops ("" = by chance)
var roulette_rng := RandomNumberGenerator.new()
const ROULETTE_STEPS := 22  # at least this many steps (then up to two more to stop on the pick)
var used_help := false  # HELP never takes a reward away; only remembered
var reward: Dictionary = {}  # the last check's reward (StudyGrading.reward), handed to the game
var selected_powerups: Array = []
var last_reward: Dictionary = {}  # what "ゲームで遊ぶ" handed over (kept after the mode ends)
## the study time: from the start of the homework to all 3 problems filled
var study_started_ms := -1
var study_final_s := -1.0
var explanation: Dictionary = {}
var explain_note := ""
var error_text := ""
var notice := ""  # a short line under the checklist (why HELP did not move, ...)
var adult_prompt := ""  # a grown-up must press Enter before the arm moves / to go on
var completion_fired := false
var celebrate_count := 0  # how many times the celebration really started (tests: exactly once)
var cleanup_ok := false
var cleanup_status := ""
var help_phase := ""
var inject_index := 0
var _pending_adult := ""  # "help" | "cleanup" | "grip" | "cleanup_failed" | "confirm_complete"
var _help_target: Dictionary = {}
## The tutor AI's "not in the picture, look d_mm further" (#104): at most MAX_NAV more captures
## per HELP; the arm goes on only after it is back from this capture and the words are said.
const MAX_NAV := 2
var nav_tries := 0
var _pending_nav: Array = []
var _nav_spoken := false
var _help_arm_done := false
var _explain_spoken := false
var _state_t := 0.0
var _celebration_min_s := 6.0
var _after_speech: Callable
var _timers: Array = []  # [seconds_left, Callable, story]: dropped when the story restarts
var _story := 0
var _photo_src: Image
var _photo_tex: ImageTexture

func setup(m: Node, hw: HomeworkClient) -> void:
	main = m
	catalog = WorksheetCatalog.load_default()
	speech = StudySpeech.new()
	speech.name = "StudySpeech"
	add_child(speech)
	sounds = StudySounds.new()
	sounds.name = "StudySounds"
	add_child(sounds)
	services = StudyServices.new()
	services.name = "StudyServices"
	add_child(services)
	services.setup(m, hw)
	voice = StudyVoice.new()
	voice.name = "StudyVoice"
	add_child(voice)
	voice.setup(self)
	speech.voice_request = services.voice_request
	services.on_voice = speech.on_voice
	services.on_voice_error = speech.on_voice_error
	speech.line_started.connect(_on_line_started)
	speech.queue_empty.connect(_on_speech_done)
	services.worksheet_seen.connect(_on_worksheet_seen)
	services.reading.connect(_on_reading)
	services.located.connect(_on_located)
	services.locate_failed.connect(_on_locate_failed)
	services.motion_update.connect(_on_motion_update)
	services.motion_done.connect(_on_motion_done)
	services.motion_fault.connect(_on_motion_fault)
	services.explained.connect(_on_explained)
	services.explain_failed.connect(_on_explain_failed)
	services.navigated.connect(_on_navigated)
	services.navigate_failed.connect(_on_navigate_failed)
	services.graded.connect(_on_graded)
	services.grade_failed.connect(_on_grade_failed)
	var ac = GameConfig.get_value("study_mode", "answer_check", {})
	if ac is Dictionary:
		grading.configure(ac)
		grade_checking_s = maxf(float(ac.get("checking_s", grade_checking_s)), 0.1)
		grade_reveal_s = maxf(float(ac.get("reveal_s", grade_reveal_s)), grade_checking_s + 0.2)
		if ac.get("demo_results") is Array:
			services.demo_results = (ac.demo_results as Array).duplicate()
	var w = GameConfig.get_value("study_mode", "watch", {})
	tracker.configure(w if w is Dictionary else {})
	weekday_label = str(GameConfig.get_value("study_mode", "weekday_label", weekday_label))
	_load_grade()
	var h = GameConfig.get_value("study_mode", "help", {})
	if h is Dictionary:
		default_help_problem = int(h.get("problem", 3))
		help_problem = default_help_problem
		var code := OS.find_keycode_from_string(str(h.get("key", "Y")))
		help_keycode = code if code != KEY_NONE else KEY_Y
	var hh = GameConfig.get_value("study_mode", "hand_help", {})
	if hh is Dictionary:
		hand_help_enabled = bool(hh.get("enabled", hand_help_enabled))
		hand_hold_ms = maxf(float(hh.get("hold_ms", hand_hold_ms)), 100.0)
		hand_offer_s = maxf(float(hh.get("offer_s", hand_offer_s)), 2.0)
	var k = GameConfig.get_value("study_mode", "keys", {})
	if k is Dictionary:
		for name in k:
			var code := OS.find_keycode_from_string(str(k[name]))
			if code != KEY_NONE and keys.has(name):
				keys[name] = code

func active() -> bool:
	return state != "OFF"

func _set_state(s: String) -> void:
	if s == state:
		return
	var prev := state
	state = s
	_state_t = 0.0
	GameState.post_event("study_state", {"previous": prev, "state": s})
	if services != null:
		services.trace("state %s -> %s%s" % [prev, s, (" (%s)" % notice) if notice != "" else ""])
	state_changed.emit(prev, s)
	changed.emit()

# ------------------------------------------------------------------ start / stop
func start() -> void:
	if not catalog.ok():
		push_warning("study mode: no worksheets (config/worksheets.json)")
		return
	reset_story()
	if main != null and main.debug_ui != null and main.debug_ui.visible:
		main.debug_ui.visible = false  # the main screen is the experience (F1 brings the panel back)
		main._layout()
	_set_state("INTRO")
	sounds.play("appear")
	sounds.music_play("study")  # #237: the study mode's own music (study.mp3)
	_say([{"text": "そろそろ勉強の時間だよ！", "face": "excited"},
		{"text": "今日は%s！宿題をチェックしよう！" % weekday_label, "face": "happy"},
		{"text": "席について、プリントを置いてね！", "face": "wink"}], _enter_waiting)

func stop() -> void:
	voice.reset()
	sounds.music_stop()
	services.abort("勉強モードを終えました")
	services.watch_stop()
	speech.clear()
	_set_state("OFF")

func reset_story() -> void:
	_story += 1
	grading.reset([])
	used_help = false
	reward = {}
	selected_powerups = []
	roulette_spinning = false
	roulette_index = -1
	shown.clear()
	reveal_queue.clear()
	reveal_current = 0
	if voice != null:
		voice.reset()
	offer_problem = 0
	_hand_used = ""
	_hand_since_ms = -1.0
	_pending_nav = []
	nav_tries = 0
	_timers.clear()
	services.abort()
	services.watch_stop()
	speech.clear()
	worksheet = current_worksheet()
	tracker.reset(worksheet.get("problems", []).size() if not worksheet.is_empty() else 3)
	study_started_ms = -1
	study_final_s = -1.0
	explanation = {}
	explain_note = ""
	error_text = ""
	notice = ""
	adult_prompt = ""
	completion_fired = false
	cleanup_ok = false
	cleanup_status = ""
	help_phase = ""
	_pending_adult = ""
	_after_speech = Callable()

func current_worksheet() -> Dictionary:
	var g := catalog.grades()
	if g.is_empty():
		return {}
	return catalog.for_grade(str(g[clampi(grade_index, 0, g.size() - 1)].get("id", "")))

func grade_label() -> String:
	return str(worksheet.get("grade_label", ""))

func _load_grade() -> void:
	var gi := catalog.grade_index(str(GameConfig.get_value("study_mode", "grade", "elem_3")))
	grade_index = gi if gi >= 0 else 3

## The settings screen saved (#93): the grade, simulated / camera, the sounds. Not while
## it runs (the settings open from the title, where the study mode is stopped).
func reload_settings() -> void:
	if active():
		return
	_load_grade()
	services.load_demo_config()
	sounds.enabled = bool(GameConfig.get_value("audio", "enabled", true))

func change_grade(step: int) -> void:
	if state not in ["INTRO", "WAITING_FOR_WORKSHEET"]:
		return
	var n := catalog.grades().size()
	if n == 0:
		return
	grade_index = posmod(grade_index + step, n)
	worksheet = current_worksheet()
	tracker.reset(3)
	services.begin(worksheet, grade_label())
	if state == "WAITING_FOR_WORKSHEET":
		services.watch_start()
	sounds.play("tick")
	changed.emit()

func _enter_waiting() -> void:
	_set_state("WAITING_FOR_WORKSHEET")
	services.begin(worksheet, grade_label())
	services.watch_start()
	if services.mock_needs_prepare():
		_ask_adult("prepare", "大人の人へ: Mock のアームを準備します（モーター ON・原点復帰）。Enter で準備")

# ------------------------------------------------------------------ speech
func _say(lines: Array, then := Callable()) -> void:
	speech.clear()
	_after_speech = then
	speech.say(lines)

func _on_line_started(_text: String, face: String) -> void:
	if face != "" and main != null and main.ufo != null:
		main.ufo.flash(face, speech.reading_time(_text) + 0.5)
	changed.emit()

func _on_speech_done() -> void:
	var f := _after_speech
	_after_speech = Callable()
	if f.is_valid():
		f.call()
	changed.emit()

# ------------------------------------------------------------------ the homework
func _on_worksheet_seen() -> void:
	if state != "WAITING_FOR_WORKSHEET":
		return
	_set_state("STUDYING")
	study_started_ms = Time.get_ticks_msec()
	sounds.cue("found")
	GameState.post_event("study_started", {"worksheet_id": worksheet.get("worksheet_id", "")})
	_say([{"text": "プリントを見つけたよ！", "face": "happy"},
		{"text": "宿題スタート！むずかしかったら %s キーでぼくを呼んでね。" % OS.get_keycode_string(help_keycode), "face": "normal"}])

func studying() -> bool:
	return state in ["STUDYING", "RESUME_STUDY"] or state in HELP_STATES or state == "AI_EXPLAINING"

func _on_reading(questions: Array, held: bool, reason: String) -> void:
	if not studying() or completion_fired:
		return
	# #237: a real print read by the local reader: its problems are the ones read, any count
	var grow := services.reads_whole_sheet()
	if grow and not tracker.from_sheet:
		tracker.reset_numbers([], true)
	var newly := tracker.add_numbered(questions, held, reason, grow)
	for n in newly:
		sounds.play("chime")
		GameState.post_event("study_question_filled", {"number": n})
		if state in ["STUDYING", "RESUME_STUDY"]:
			main.ufo.flash("happy", 1.2)
	changed.emit()
	_check_complete()

func _check_complete() -> void:
	if tracker.complete and not completion_fired and state in ["STUDYING", "RESUME_STUDY"]:
		_complete()

func elapsed_s() -> float:
	if study_final_s >= 0.0:
		return study_final_s
	if study_started_ms < 0:
		return 0.0
	return (Time.get_ticks_msec() - study_started_ms) / 1000.0

## Fired once per story (a repeated reading / key press never starts the check twice): every
## problem written -> the answer check with UFOくん (#237), not the celebration yet.
func _complete() -> void:
	if completion_fired:
		return
	completion_fired = true
	study_final_s = elapsed_s()
	_set_state("ANSWER_CHECK_READY")
	GameState.post_event("study_complete", {"elapsed_s": study_final_s, "by": tracker.completed_by})
	grading.reset(tracker.numbers)  # the problems written (a real print: the ones read on it)
	grading.used_help = used_help
	shown.clear()
	reveal_current = 0
	combo = 0
	sounds.music_play("check")  # the answer check's music (study_check.mp3)
	sounds.cue("check_start")
	_say([{"text": "ぜんぶ書けたね！", "face": "excited"},
		{"text": "UFOくんと答え合わせしよう！", "face": "happy"}], _scan.bind(false))

# ------------------------------------------------------------------ the answer check (#237)
## Read the whole sheet once (the reader is called once; the problems are then shown one by one).
func _scan(rescan: bool) -> void:
	if not (state == "ANSWER_CHECK_READY" or (rescan and state == "REVIEW_SUMMARY")):
		return
	_set_state("RESCAN" if rescan else "SHEET_SCANNING")
	notice = ""
	sounds.play("tick")
	services.grade(rescan)
	if rescan:
		_say([{"text": "もういちど 見てみるね！", "face": "normal"}])

func _on_graded(problems: Array) -> void:
	if state not in ["SHEET_SCANNING", "RESCAN"]:
		return
	_reveal(grading.apply(problems, services.reads_whole_sheet()))

## The reading failed: never "wrong", the problems not yet right are only unclear.
func _on_grade_failed(reason: String) -> void:
	if state not in ["SHEET_SCANNING", "RESCAN"]:
		return
	notice = "プリントを読めなかったよ: " + reason
	services.trace("answer check: " + reason)
	_reveal(grading.fail_all())

func _reveal(numbers: Array[int]) -> void:
	reveal_queue = numbers.duplicate()
	for n in numbers:
		shown.erase(n)
	_set_state("GRADING_QUESTION")
	_reveal_next()

func _reveal_next() -> void:
	if state != "GRADING_QUESTION":
		return
	if reveal_queue.is_empty():
		reveal_current = 0
		_summary()
		return
	reveal_current = reveal_queue.pop_front()
	sounds.cue("drum")  # the roll before the verdict
	changed.emit()
	_later(grade_checking_s, _show_verdict.bind(reveal_current))

func _show_verdict(n: int) -> void:
	if state != "GRADING_QUESTION" or reveal_current != n:
		return
	shown[n] = true
	var v: String = grading.verdicts.get(n, StudyGrading.UNCLEAR)
	match v:
		StudyGrading.CORRECT:
			combo += 1
			sounds.cue("correct")
			if combo >= 2:
				sounds.cue("combo")
			main.ufo.flash("happy", 1.5)
			GameState.post_event("study_answer_correct", {"number": n, "combo": combo})
			speech.say([{"text": "%dばん、せいかい！" % n, "face": "excited"}])
		StudyGrading.REVIEW:
			combo = 0
			sounds.cue("review")
			GameState.post_event("study_answer_review", {"number": n})
			speech.say([{"text": "%dばんは、もういちど 見てみよう。" % n, "face": "wink"}])
		_:
			combo = 0
			sounds.cue("unclear")
			GameState.post_event("study_answer_unclear", {"number": n})
			speech.say([{"text": "%dばんは、紙が 見えにくかったみたい。" % n, "face": "worried"}])
	changed.emit()
	_later(maxf(grade_reveal_s - grade_checking_s, 0.1), _reveal_next)

## The energy for the game: one per problem right.
func energy() -> int:
	return grading.count(StudyGrading.CORRECT)

## A hint for a problem to look at again: the worksheet's first hint (never the answer).
func review_hint(n: int) -> String:
	var hints: Array = WorksheetCatalog.problem(worksheet, n).get("hints", [])
	return str(hints[0]) if not hints.is_empty() else "もういちど 問題を ゆっくり 読んでみよう"

func _summary() -> void:
	grading.checked = true
	var look := grading.to_look_again()
	if look.is_empty():
		_calc_reward()
		return
	_set_state("REVIEW_SUMMARY")
	var lines: Array = []
	for n in grading.with_verdict(StudyGrading.REVIEW):
		lines.append({"text": "%dばんは、%s" % [n, review_hint(n)], "face": "normal"})
	for n in grading.with_verdict(StudyGrading.UNCLEAR):
		lines.append({"text": "%dばんは、紙の位置や 手で かくれていないかを 見てね。" % n, "face": "worried"})
	lines.append({"text": "書きなおしたら、もういちど 見るよ。あとで見直してもいいよ！", "face": "wink"})
	_say(lines)
	_ask_adult("review", "書きなおしたら R でもう一度読む ／ このまま Enter でつぎへ（見直しはあとでも OK）")

func _calc_reward() -> void:
	if state not in ["GRADING_QUESTION", "REVIEW_SUMMARY"]:
		return
	_pending_adult = ""
	adult_prompt = ""
	services.watch_stop()
	selected_powerups = []
	_set_state("REWARD_CALCULATING")
	reward = grading.reward(str(worksheet.get("worksheet_id", "")))
	_later(0.8, _reveal_reward)

func _reveal_reward() -> void:
	if state != "REWARD_CALCULATING":
		return
	celebrate_count += 1
	_set_state("REWARD_REVEAL")
	sounds.cue("reward")
	if grading.all_correct():
		sounds.cue("perfect")
	GameState.post_event("study_celebrate", {"reward": reward.duplicate()})
	var lines: Array = []
	if grading.all_correct():
		lines.append({"text": "ぜんぶ せいかい！パーフェクト！！", "face": "excited"})
	else:
		lines.append({"text": "やったー！ 答え合わせ おわり！", "face": "excited"})
	if int(reward.time_bonus_s) > 0:
		lines.append({"text": "ゲームの じかんが %d びょう ふえるよ！" % int(reward.time_bonus_s), "face": "happy"})
	if int(reward.power_tickets) > 0:
		lines.append({"text": "パワーチケットも ゲット！", "face": "excited"})
	_say(lines, func():
		if state == "REWARD_REVEAL":
			_later(maxf(_celebration_min_s - _state_t, 0.0), _after_reveal))

func _after_reveal() -> void:
	if state != "REWARD_REVEAL":
		return
	if int(reward.get("power_tickets", 0)) > 0:
		_set_state("POWERUP_SELECT")
		sounds.cue("power_show")
		_say([{"text": "パワールーレット、スタート！", "face": "excited"}])
		_spin_roulette()
	else:
		_after_reward()

## The roulette: the light steps round the powers, each step a little slower, and stops on the
## pick (roulette_force, else by chance): that power is chosen.
func _spin_roulette() -> void:
	var pick := -1
	for i in POWERUPS.size():
		if POWERUPS[i][0] == roulette_force:
			pick = i
	if pick < 0:
		pick = roulette_rng.randi_range(0, POWERUPS.size() - 1)
	var steps := ROULETTE_STEPS
	while (steps - 1) % POWERUPS.size() != pick:
		steps += 1
	roulette_spinning = true
	roulette_index = -1
	var t := 0.0
	for i in steps:
		t += 0.045 + 0.32 * pow(float(i) / steps, 3.0)  # fast, then slower and slower
		_later(t, _roulette_step.bind(i % POWERUPS.size(), i == steps - 1))

func _roulette_step(index: int, last: bool) -> void:
	if state != "POWERUP_SELECT" or not roulette_spinning:
		return
	roulette_index = index
	sounds.play("pin" if not last else "tick")
	changed.emit()
	if last:
		roulette_spinning = false
		choose_powerup(POWERUPS[index][0])

## The power for the game: where the roulette stopped (once per check).
func choose_powerup(kind: String) -> void:
	if state != "POWERUP_SELECT" or not selected_powerups.is_empty():
		return
	var name := ""
	for pw in POWERUPS:
		if pw[0] == kind:
			name = pw[1]
	if name == "":
		return
	selected_powerups = [kind]
	reward = grading.reward(str(worksheet.get("worksheet_id", "")), selected_powerups)
	sounds.cue("power_pick")
	GameState.post_event("study_powerup_selected", {"kind": kind})
	_say([{"text": "%s に けってい！ ゲームに もっていこう！" % name, "face": "excited"}], _after_reward)

func _after_reward() -> void:
	if state not in ["REWARD_REVEAL", "POWERUP_SELECT"]:
		return
	if cleanup_enabled():
		_begin_cleanup()
	else:
		_unlock()

## study_mode.cleanup.enabled (#110: off = no tidy-up, the game unlocks after the celebration).
static func cleanup_enabled() -> bool:
	var c = GameConfig.get_value("study_mode", "cleanup", {})
	return c is Dictionary and bool(c.get("enabled", true))

# ------------------------------------------------------------------ HELP by hand (#136)
## The hand on the overview camera now: its pose ("" = no fresh hand). Called every frame
## while the study mode runs. A pose counts after hand_hold_ms; once acted on, the same
## pose does nothing more until the hand changes (a held thumb does not start twice).
func hand_tick(pose: String, now_ms: float) -> void:
	if offer_problem > 0 and now_ms > _offer_until_ms:
		offer_problem = 0
		services.trace("hand help: the offer timed out")
		changed.emit()
	if not hand_help_enabled or state not in ["STUDYING", "RESUME_STUDY"]:
		_hand_pose = pose
		_hand_since_ms = now_ms
		return
	if pose != _hand_pose:
		_hand_pose = pose
		_hand_since_ms = now_ms
		if pose != _hand_used:
			_hand_used = ""
		return
	if pose == "" or pose == _hand_used or now_ms - _hand_since_ms < hand_hold_ms:
		return
	if COUNT_POSES.has(pose):
		_hand_used = pose
		offer_help(int(COUNT_POSES[pose]), now_ms)
	elif pose == "thumb" and offer_problem > 0:
		_hand_used = pose
		var n := offer_problem
		offer_problem = 0
		services.trace("hand help: thumbs-up for problem %d" % n)
		request_help(n, true)

## "問題 n、教えてあげようか？" and wait hand_offer_s for a thumbs-up.
## The problem Y helps with (#237): on a real print (read by the camera) the one the child seems
## stuck on: the first being written, else the first not written yet; 0 = none to tell (all are
## written, or none read yet: the child is asked). On the sample sheet: help.problem (its challenge).
func stuck_problem() -> int:
	if not services.reads_whole_sheet() and not tracker.from_sheet:
		return default_help_problem
	for n in tracker.numbers:
		if tracker.shown_state(n) == StudyQuestionTracker.WRITING:
			return n
	for n in tracker.numbers:
		if tracker.shown_state(n) in [StudyQuestionTracker.EMPTY, StudyQuestionTracker.HELD] and not tracker.is_filled(n):
			return n
	return 0

func offer_help(problem: int, now_ms: float) -> void:
	if WorksheetCatalog.problem(worksheet, problem).is_empty() and not tracker.has(problem):
		return
	offer_problem = problem
	_offer_until_ms = now_ms + hand_offer_s * 1000.0
	services.trace("hand help: %d fingers, offer for problem %d" % [problem, problem])
	notice = "問題 %d: いいね（親指を立てる）で解説をはじめるよ" % problem
	sounds.play("appear")
	_say([{"text": "問題 %d だね。教えてあげようか？" % problem, "face": "surprised"},
		{"text": "いいね👍 を見せてくれたら、近くで見て解説するよ！", "face": "wink"}])
	changed.emit()

# ------------------------------------------------------------------ HELP
## HELP for problem (Y: stuck_problem(), 0 = ask which). asked: the child asked for it by hand, so a
## problem already filled is explained too.
func request_help(problem := 0, asked := false) -> void:
	if state not in ["STUDYING", "RESUME_STUDY"]:
		if state in HELP_STATES or state == "AI_EXPLAINING":
			notice = "いま見に行っているところだよ"
			changed.emit()
		return
	offer_problem = 0
	if problem <= 0:
		problem = stuck_problem()
		if problem <= 0:  # nothing to go to by itself: ask, never move on a guess
			notice = "どの問題か教えてね（指で番号 → いいね、または V を押して話す）"
			_say([{"text": "どの問題かな？", "face": "surprised"},
				{"text": "指で番号を見せるか、Vを押して教えてね！", "face": "wink"}])
			changed.emit()
			return
	used_help = true  # remembered only: a HELP never takes a reward away (#236)
	help_problem = problem
	if tracker.is_filled(help_problem) and not asked:
		notice = "問題 %d はもう書けているみたい（アームは動かしません）" % help_problem
		_say([{"text": "問題 %d はもう書けているみたい！すごいね！" % help_problem, "face": "happy"}])
		changed.emit()
		return
	_set_state("HELP_LOCATING")
	explanation = {}
	explain_note = ""
	_help_arm_done = false
	_explain_spoken = false
	nav_tries = 0
	_pending_nav = []
	sounds.play("appear")
	GameState.post_event("study_help", {"problem": help_problem})
	_say([{"text": "困ったの？" if not asked else "わかった！問題 %d だね。" % help_problem, "face": "surprised"},
		{"text": "ぼくが近くで見てみるよ！", "face": "excited"}])
	services.locate_help(help_problem)

func _on_located(target: Dictionary) -> void:
	if state != "HELP_LOCATING":
		return
	_help_target = target
	if services.robot_is_real():
		_ask_adult("help", "大人の人へ: アームが問題 %d の上へ動きます。手を机から離してから Enter（やめるなら Space）" % help_problem)
		return
	_move_help()

func _move_help() -> void:
	adult_prompt = ""
	_set_state("HELP_MOVING")
	help_phase = "MOVE"
	services.start_help(_help_target)

func _on_locate_failed(reason: String) -> void:
	if state != "HELP_LOCATING":
		return
	notice = "見に行けませんでした: " + reason
	_set_state("RESUME_STUDY")
	_say([{"text": "ごめんね、いまは近くで見られないみたい。", "face": "worried"},
		{"text": "プリントのヒントを出すね！", "face": "normal"}], func(): _show_fallback_explanation(reason))

## Without the arm: the worksheet's own hints, so the child still gets help.
func _show_fallback_explanation(reason: String) -> void:
	if state != "RESUME_STUDY":
		return
	explanation = StudyServices.fallback_explanation(WorksheetCatalog.problem(worksheet, help_problem), help_problem)
	explain_note = "（アームは動かしていません: %s）" % reason
	_say(_explain_lines(explanation, false), _resume_study)

func _on_motion_update(kind: String, phase: String, stage: String, holding: bool, data: Dictionary) -> void:
	if kind == "help":
		help_phase = phase
		if holding and CAPTURE_STATE.has(stage) and state in ["HELP_MOVING", "CAPTURE_10CM", "CAPTURE_5CM", "CAPTURE_LANDING"]:
			_capture_stage(stage)
		changed.emit()
	elif kind == "cleanup":
		_on_cleanup_update(phase, data)

func _capture_stage(stage: String) -> void:
	_set_state(CAPTURE_STATE[stage])
	if services.inject_fail == "motion":
		services.inject_fail = ""
		_on_motion_stop_key("失敗の注入: アームを止めました")
		return
	sounds.play("shutter")
	GameState.post_event("study_capture", {"stage": stage})
	services.capture(stage)
	var lines := {"10cm": "10センチ上から パシャ！", "5cm": "もっと近くで パシャ！", "landing": "いちばん近くで パシャ！"}
	speech.say([{"text": lines[stage], "face": "surprised" if stage != "landing" else "happy"}])
	# the close-up stays on screen a moment before the arm moves on
	_later(1.2, func():
		if state == CAPTURE_STATE[stage]:
			services.release_stage(stage)
			if stage == StudyServices.last_stage():  # #110: 10 cm only by default
				_begin_explaining())

func _begin_explaining() -> void:
	_set_state("AI_EXPLAINING")
	_say([{"text": "うーん、よーく見てるよ…", "face": "normal"}])
	services.explain(help_problem)

func _on_explained(result: Dictionary) -> void:
	if state != "AI_EXPLAINING":
		return
	var nav: Dictionary = result.navigate if result.get("navigate") is Dictionary else {}
	if str(nav.get("kind", "")) == "move" and nav.get("d_mm") is Array:
		if nav_tries < MAX_NAV:
			nav_tries += 1
			_pending_nav = nav.d_mm
			_nav_spoken = false
			notice = "問題 %d が写っていないので、もう一度見に行きます（%d / %d）" % [help_problem, nav_tries, MAX_NAV]
			_say([{"text": "あれっ、ここじゃないみたい。", "face": "surprised"},
				{"text": "さがしに いくね！ 手を はなして まっててね。", "face": "excited"}], func():
				_nav_spoken = true
				_maybe_navigate())
			return
		# looked MAX_NAV more times without finding it: the worksheet's own hints
		explanation = StudyServices.fallback_explanation(WorksheetCatalog.problem(worksheet, help_problem), help_problem)
		explain_note = "（さがしても見つからなかったので、プリントのヒントだよ）"
		_speak_explanation()
		return
	explanation = result
	explain_note = "" if not bool(result.get("needs_confirmation", false)) else "（読み取りに自信がないので、大人の人も確かめてね）"
	_speak_explanation()

func _on_explain_failed(reason: String, fallback: Dictionary) -> void:
	if state != "AI_EXPLAINING":
		return
	explanation = fallback
	explain_note = "（AI が使えなかったので、プリントのヒントだよ: %s）" % reason
	notice = "AI の解説: " + reason
	_speak_explanation()

func _explain_lines(result: Dictionary, intro := true) -> Array:
	var lines: Array = []
	if intro:
		lines.append({"text": "なるほど、ここが難しいんだね！", "face": "happy"})
		lines.append({"text": "こんなふうに考えてみよう！", "face": "wink"})
	var body: Array = result.get("speech_lines", []) if result.get("speech_lines") is Array else []
	if body.is_empty() and str(result.get("speech_text", "")) != "":
		body = [str(result.speech_text)]
	for t in body:
		lines.append({"text": str(t), "face": "normal"})
	return lines

func _speak_explanation() -> void:
	_explain_spoken = false
	_say(_explain_lines(explanation), func():
		_explain_spoken = true
		_maybe_resume())

func _maybe_resume() -> void:
	if not _pending_nav.is_empty():
		_maybe_navigate()
		return
	if state == "AI_EXPLAINING" and _explain_spoken and _help_arm_done:
		_resume_study()

## Looks again d_mm further once the arm is back and the words are said (#104).
func _maybe_navigate() -> void:
	if state != "AI_EXPLAINING" or _pending_nav.is_empty() or not _nav_spoken or not _help_arm_done:
		return
	var d := _pending_nav
	_pending_nav = []
	_help_arm_done = false
	_explain_spoken = false
	_set_state("HELP_LOCATING")
	services.navigate_help(d)

func _on_navigated(target: Dictionary) -> void:
	_on_located(target)  # as a found problem: the grown-up's Enter on the real robot, then the capture

func _on_navigate_failed(reason: String) -> void:
	_on_locate_failed("もう一度見に行けませんでした: " + reason)

func _resume_study() -> void:
	_set_state("RESUME_STUDY")
	_say([{"text": "さあ、答えを書いてみてね！", "face": "wink"}], func():
		if state == "RESUME_STUDY":
			_set_state("STUDYING")
			_check_complete())
	_check_complete()

func _on_motion_done(kind: String) -> void:
	if kind == "help":
		_help_arm_done = true
		help_phase = "IDLE"
		_maybe_resume()
	elif kind == "cleanup":
		_cleanup_finished()
	changed.emit()

func _on_motion_fault(kind: String, reason: String) -> void:
	if kind == "help" and (state in HELP_STATES or state == "AI_EXPLAINING"):
		_help_arm_done = true
		_error("アームを止めました: " + reason)
	elif kind == "cleanup" and state == "CLEANUP":
		_cleanup_failed(reason)

func _error(text: String) -> void:
	error_text = text
	_pending_nav = []  # a stop is a stop: no looking again (#104)
	services.abort()
	_set_state("ERROR")
	sounds.play("pop")
	GameState.post_event("study_error", {"message": text})
	_say([{"text": "あれれ、止まっちゃった。", "face": "worried"},
		{"text": "大人の人に見てもらってね。Enter で続けるよ。", "face": "worried"}])

# ------------------------------------------------------------------ the tidy-up
func _begin_cleanup() -> void:
	if state not in ["REWARD_REVEAL", "POWERUP_SELECT"]:
		return
	_set_state("CLEANUP")
	GameState.post_event("study_cleanup", {})
	_say([{"text": "お勉強おわり！", "face": "happy"}, {"text": "最後にお片付けをするよ！", "face": "excited"}], func():
		if state != "CLEANUP":
			return
		if services.robot_is_real():
			_ask_adult("cleanup", "大人の人へ: 片付けでアームが机の上を動きます。手やものを離してから Enter（やめるなら Space）")
		else:
			services.start_cleanup())

func _on_cleanup_update(phase: String, data: Dictionary) -> void:
	if state != "CLEANUP":
		return
	cleanup_status = phase
	var line: String = {"TO_JIG": "マグネットのどうぐを取りに行くよ", "GRIP": "つかむよ…", "SWEEP": "ぐるっと回って集めるよ！",
		"TO_COLLECT": "集めたものを運ぶよ", "BACK_TO_JIG": "どうぐを返すね", "PARK": "おしまいの場所へ"}.get(phase, "")
	if phase == "SWEEP" and int(data.get("waypoint", 1)) > 1:
		line = ""
	if line != "":
		speech.say([{"text": line, "face": "normal"}])
	if bool(data.get("confirming", false)) and _pending_adult != "grip":
		_ask_adult("grip", "大人の人へ: 爪がマグネットのどうぐをつかめていたら Enter（だめなら Space で止める）")
	elif not bool(data.get("confirming", false)) and _pending_adult == "grip":
		_pending_adult = ""
		adult_prompt = ""
	changed.emit()

func _cleanup_finished() -> void:
	if state != "CLEANUP":
		return
	cleanup_ok = true
	adult_prompt = ""
	_pending_adult = ""
	GameState.post_event("study_cleanup_done", {})
	sounds.play("chime")
	_unlock()

func _cleanup_failed(reason: String) -> void:
	cleanup_ok = false
	cleanup_status = "FAULT"
	error_text = "片付けを止めました: " + reason
	_set_state("CLEANUP_FAILED")
	GameState.post_event("study_cleanup_failed", {"message": reason})
	_ask_adult("cleanup_failed", "大人の人へ: 片付けは途中で止めました（%s）。机の上を確かめてから Enter" % reason)
	_say([{"text": "あれれ、お片付けがうまくいかなかったみたい。", "face": "worried"},
		{"text": "大人の人に見てもらってね。", "face": "sad"}])

func _unlock() -> void:
	_set_state("GAME_READY_WITH_REWARD")
	sounds.cue("ready")
	GameState.post_event("study_game_unlocked", {"cleanup_ok": cleanup_ok, "reward": reward.duplicate()})
	_say([{"text": "お勉強おつかれさま！", "face": "happy"}, {"text": "STUDY POWER、じゅんび OK！", "face": "excited"},
		{"text": "これからはゲームの時間だよ！", "face": "wink"}])

## "ゲームで遊ぶ": the reward is handed over once (last_reward; the score game takes it in #239)
## and the study mode ends (the game's own readiness checks apply as before).
func play_game() -> void:
	if state != "GAME_READY_WITH_REWARD":
		return
	last_reward = reward.duplicate(true)
	GameState.post_event("study_reward", last_reward.duplicate(true))
	stop()
	GameState.post_event("reset")

# ------------------------------------------------------------------ grown-ups, keys, stop
func _ask_adult(kind: String, text: String) -> void:
	_pending_adult = kind
	adult_prompt = text
	sounds.play("tick")
	changed.emit()

func _adult_ok() -> void:
	var kind := _pending_adult
	_pending_adult = ""
	adult_prompt = ""
	match kind:
		"help":
			if state == "HELP_LOCATING":
				_move_help()
		"cleanup":
			if state == "CLEANUP":
				services.start_cleanup()
		"grip":
			services.confirm_grip()
		"cleanup_failed":
			if state == "CLEANUP_FAILED":
				_unlock()
		"prepare":
			services.prepare_mock_robot()
		"review":
			_calc_reward()
	changed.emit()

## Enter: the context's "next" (the sheet is placed, a grown-up's confirmation, play).
func advance() -> void:
	if _pending_adult != "":
		_adult_ok()
		return
	match state:
		"INTRO":
			_enter_waiting()
			speech.clear()
			_say([{"text": "席について、プリントを置いてね！", "face": "wink"}])
		"WAITING_FOR_WORKSHEET":
			services.mark_seen()
		"STUDYING", "RESUME_STUDY":
			if tracker.filled_count() == tracker.count:
				tracker.confirm_complete()  # a grown-up checked the sheet
				_check_complete()
			else:
				notice = "まだ %d / %d 問。全部書けたら Enter で大人の人が確認できます" % [tracker.filled_count(), tracker.count]
				changed.emit()
		"ERROR":
			error_text = ""
			_set_state("STUDYING" if study_started_ms >= 0 else "WAITING_FOR_WORKSHEET")
			if state == "STUDYING":
				services.watch_start()
			_say([{"text": "続きをやろう！", "face": "normal"}])
		"GAME_READY_WITH_REWARD":
			play_game()

## Space (the game's stop key, which also stops the robot): the study mode stops its motion.
func on_stop_key() -> void:
	if not active():
		return
	voice.cancel()
	if _pending_adult in ["help", "cleanup"]:
		_pending_adult = ""
		adult_prompt = ""
		if state == "HELP_LOCATING":
			_on_locate_failed("Space でやめました")
		elif state == "CLEANUP":
			_cleanup_failed("Space でやめました")
		return
	if state in HELP_STATES or state == "CLEANUP" or _pending_adult == "grip":
		_on_motion_stop_key("Space で止めました")
	elif state == "AI_EXPLAINING" and (not _pending_nav.is_empty() or services.motion_active()):
		# about to look again (#104) or the arm still on its way back: a stop is a stop
		_on_motion_stop_key("Space で止めました")

func _on_motion_stop_key(reason: String) -> void:
	if state == "CLEANUP" or _pending_adult == "grip":
		_pending_adult = ""
		services.abort(reason)
		if state == "CLEANUP":
			_cleanup_failed(reason)
		return
	services.abort(reason)  # ends the backend's sequence too (soft_stop -> its ABORT)
	if state != "ERROR":
		_error(reason)

## Keys while the study mode runs: true when used here. The game's keys stay as they are.
func handle_key(keycode: int) -> bool:
	if keycode == keys.toggle:
		if active():
			stop()
		else:
			start()
		return true
	if not active():
		return false
	if state == "POWERUP_SELECT" and keycode in [KEY_1, KEY_2, KEY_3]:
		pass  # the roulette picks it (the fill keys do nothing here)
	elif state == "REVIEW_SUMMARY" and keycode == keys.rescan:
		_pending_adult = ""
		adult_prompt = ""
		_scan(true)
	elif keycode == voice.talk_keycode:
		voice.press()  # #233: held = listening; the release ends it (handle_key_release)
	elif keycode == keys.advance or keycode == KEY_KP_ENTER:
		advance()
	elif keycode == help_keycode:
		request_help()
	elif keycode in [keys.fill_1, keys.fill_2, keys.fill_3] and services.mode == "simulated":
		services.demo_fill({keys.fill_1: 1, keys.fill_2: 2, keys.fill_3: 3}[keycode])
	elif keycode == keys.grade_prev:
		change_grade(-1)
	elif keycode == keys.grade_next:
		change_grade(1)
	elif keycode == keys.skip:
		debug_skip()
	elif keycode == keys.inject:
		debug_next_failure()
	elif keycode == keys.reset:
		start()
	else:
		return false
	return true

## A key let go: the talk key ends the listening (#233). True when used here.
func handle_key_release(keycode: int) -> bool:
	if not active() or keycode != voice.talk_keycode:
		return false
	voice.release()
	return true

## The voice dialogue's answer as it comes (#233): the first lines replace what was being said,
## the next ones queue after them.
func voice_lines(lines: Array, first: bool) -> void:
	if not active():
		return
	if first:
		_say(lines)
	else:
		speech.say(lines)

## The answer is complete: `look` > 0 then sends the arm's camera to that problem once UFOくん
## has said it all (the usual HELP, asked by the child).
func voice_done(look := 0) -> void:
	if not active() or look <= 0:
		return
	var f := func():
		if voice.in_talk_state():
			request_help(look, true)
	if speech.busy():
		_after_speech = f
	else:
		f.call()

## UFOくん answers what the child said (#233); `look` > 0: then the arm's camera looks at that
## problem (the usual HELP, asked by the child: a problem already written is looked at too).
func voice_answer(lines: Array, look := 0) -> void:
	if not active():
		return
	_say(lines, func():
		if look > 0 and voice.in_talk_state():
			request_help(look, true))

## The arm belongs to the study mode now: no manual jog.
func blocks_manual_control() -> bool:
	return active() and (state in HELP_STATES or state in ["AI_EXPLAINING", "CLEANUP"] or services.motion_active())

## The UFO's mood over the game's one ("" = the game's).
func mood_override() -> String:
	match state:
		"REWARD_REVEAL", "POWERUP_SELECT", "GAME_READY_WITH_REWARD":
			return "SUCCESS"
		"ERROR", "CLEANUP_FAILED":
			return "FAILURE"
	return ""

## The round close-up view is up (capturing).
## #136: the arm camera from the arm's first move to the end of the explanation (then the
## photo it took: explain_photo()).
func wants_scope() -> bool:
	return state in ["CAPTURE_10CM", "CAPTURE_5CM", "CAPTURE_LANDING", "HELP_MOVING", "AI_EXPLAINING"]

## The arm camera's photo of the problem while it is explained (null = the live camera).
func explain_photo() -> Texture2D:
	if state != "AI_EXPLAINING":
		return null
	var img: Image = null
	for stage in ["landing", "5cm", "10cm"]:
		if services.captures.get(stage) is Image:
			img = services.captures[stage]
			break
	if img == null or img.is_empty():
		return null
	if _photo_src != img:
		_photo_src = img
		_photo_tex = ImageTexture.create_from_image(img)
	return _photo_tex

func capture_stage() -> String:
	for k in CAPTURE_STATE:
		if CAPTURE_STATE[k] == state:
			return k
	return ""

# ------------------------------------------------------------------ debug
## F6: skip ahead as if the current step succeeded.
func debug_skip() -> void:
	match state:
		"INTRO":
			speech.clear()
			_enter_waiting()
		"WAITING_FOR_WORKSHEET":
			services.mark_seen()
		"STUDYING", "RESUME_STUDY":
			tracker.confirm_complete()
			_check_complete()
		"HELP_LOCATING", "HELP_MOVING", "CAPTURE_10CM", "CAPTURE_5CM", "CAPTURE_LANDING":
			services.abort("F6 でスキップ")
			_help_arm_done = true
			_begin_explaining()
		"AI_EXPLAINING":
			speech.clear()
			_help_arm_done = true
			_resume_study()
		"ANSWER_CHECK_READY":
			speech.clear()
			_scan(false)
		"SHEET_SCANNING", "RESCAN":  # as if the reader found every problem right
			services.cancel_grade()
			var all_right: Array = []
			for n in grading.numbers:
				all_right.append({"number": n, "answer_status": "correct"})
			_on_graded(all_right)
		"GRADING_QUESTION":
			for n in reveal_queue:
				shown[n] = true
			if reveal_current > 0:
				shown[reveal_current] = true
			reveal_queue.clear()
			reveal_current = 0
			_summary()
		"REVIEW_SUMMARY":
			_calc_reward()
		"REWARD_CALCULATING":
			_reveal_reward()
		"REWARD_REVEAL":
			speech.clear()
			_after_reveal()
		"POWERUP_SELECT":
			if selected_powerups.is_empty():  # stop the roulette where it is (or on the first)
				roulette_spinning = false
				choose_powerup(POWERUPS[maxi(roulette_index, 0)][0])
			speech.clear()
			_after_reward()
		"CLEANUP":
			services.abort("F6 でスキップ")
			_cleanup_finished()
		"CLEANUP_FAILED", "ERROR":
			advance()
		"GAME_READY_WITH_REWARD":
			play_game()
	changed.emit()

## F7: the next action of the chosen kind fails (cycles through the kinds).
func debug_next_failure() -> void:
	inject_index = (inject_index + 1) % FAILURES.size()
	var f: String = FAILURES[inject_index]
	services.inject_fail = f
	speech.voice_on = f != "voice"
	if f == "occlude":
		services.demo_occlude(3)
	notice = "失敗の注入: " + FAILURE_LABEL[f]
	changed.emit()

func _later(secs: float, f: Callable) -> void:
	_timers.append([secs, f, _story])

func _process(dt: float) -> void:
	if state == "OFF":
		return
	_state_t += dt
	voice.tick(dt)
	for t in _timers.duplicate():
		t[0] -= dt
		if t[0] <= 0.0:
			_timers.erase(t)
			if int(t[2]) == _story:
				t[1].call()

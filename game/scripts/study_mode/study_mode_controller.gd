class_name StudyModeController
extends Node
## UFOくん 勉強モード (#86): the experience as one state machine.
##
##   INTRO -> WAITING_FOR_WORKSHEET -> STUDYING
##   STUDYING --HELP (Y)--> HELP_LOCATING -> HELP_MOVING -> CAPTURE_10CM -> CAPTURE_5CM
##            -> CAPTURE_LANDING -> AI_EXPLAINING -> RESUME_STUDY -> STUDYING
##   STUDYING --3 problems stably filled / grown-up's Enter--> HOMEWORK_COMPLETE
##            -> CELEBRATION -> CLEANUP -> GAME_UNLOCKED --"ゲームで遊ぶ"--> (off)
##   CLEANUP --fault--> CLEANUP_FAILED --Enter--> GAME_UNLOCKED (tidy-up left unchecked)
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
	"CAPTURE_10CM", "CAPTURE_5CM", "CAPTURE_LANDING", "AI_EXPLAINING", "RESUME_STUDY", "HOMEWORK_COMPLETE",
	"CELEBRATION", "CLEANUP", "CLEANUP_FAILED", "GAME_UNLOCKED", "ERROR"]
const CAPTURE_STATE := {"10cm": "CAPTURE_10CM", "5cm": "CAPTURE_5CM", "landing": "CAPTURE_LANDING"}
const HELP_STATES := ["HELP_LOCATING", "HELP_MOVING", "CAPTURE_10CM", "CAPTURE_5CM", "CAPTURE_LANDING"]
const FAILURES := ["", "locate", "motion", "ai", "voice", "occlude", "cleanup"]
const FAILURE_LABEL := {"": "なし", "locate": "位置の特定", "motion": "アームの停止", "ai": "AI の解説",
	"voice": "音声", "occlude": "手で隠れる", "cleanup": "片付け"}

var main: Node
var services: StudyServices
var speech: StudySpeech
var sounds: StudySounds
var tracker := StudyQuestionTracker.new()
var catalog: WorksheetCatalog
var state := "OFF"
var grade_index := 3
var worksheet: Dictionary = {}
var weekday_label := "月曜日"
var help_problem := 3
var help_keycode := KEY_Y
## keys of the study mode (study_mode.keys); the game's own keys stay as they are
var keys := {"advance": KEY_ENTER, "fill_1": KEY_1, "fill_2": KEY_2, "fill_3": KEY_3, "grade_prev": KEY_COMMA,
	"grade_next": KEY_PERIOD, "skip": KEY_F6, "inject": KEY_F7, "reset": KEY_F8, "toggle": KEY_F5}
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
var _help_arm_done := false
var _explain_spoken := false
var _state_t := 0.0
var _celebration_min_s := 6.0
var _after_speech: Callable
var _timers: Array = []  # [seconds_left, Callable, story]: dropped when the story restarts
var _story := 0

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
	var w = GameConfig.get_value("study_mode", "watch", {})
	tracker.configure(w if w is Dictionary else {})
	weekday_label = str(GameConfig.get_value("study_mode", "weekday_label", weekday_label))
	var gi := catalog.grade_index(str(GameConfig.get_value("study_mode", "grade", "elem_3")))
	grade_index = gi if gi >= 0 else 3
	var h = GameConfig.get_value("study_mode", "help", {})
	if h is Dictionary:
		help_problem = int(h.get("problem", 3))
		var code := OS.find_keycode_from_string(str(h.get("key", "Y")))
		help_keycode = code if code != KEY_NONE else KEY_Y
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
	_say([{"text": "そろそろ勉強の時間だよ！", "face": "excited"},
		{"text": "今日は%s！宿題をチェックしよう！" % weekday_label, "face": "happy"},
		{"text": "席について、プリントを置いてね！", "face": "wink"}], _enter_waiting)

func stop() -> void:
	services.abort("勉強モードを終えました")
	services.watch_stop()
	speech.clear()
	_set_state("OFF")

func reset_story() -> void:
	_story += 1
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
	sounds.play("chime")
	GameState.post_event("study_started", {"worksheet_id": worksheet.get("worksheet_id", "")})
	_say([{"text": "プリントを見つけたよ！", "face": "happy"},
		{"text": "宿題スタート！むずかしかったら %s キーでぼくを呼んでね。" % OS.get_keycode_string(help_keycode), "face": "normal"}])

func studying() -> bool:
	return state in ["STUDYING", "RESUME_STUDY"] or state in HELP_STATES or state == "AI_EXPLAINING"

func _on_reading(probs: Array, held: bool, reason: String) -> void:
	if not studying() or completion_fired:
		return
	var newly := tracker.add_reading(probs, held, reason)
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

## Fired once per story (a repeated reading / key press never celebrates twice).
func _complete() -> void:
	if completion_fired:
		return
	completion_fired = true
	study_final_s = elapsed_s()
	services.watch_stop()
	_set_state("HOMEWORK_COMPLETE")
	GameState.post_event("study_complete", {"elapsed_s": study_final_s, "by": tracker.completed_by})
	_celebrate()

func _celebrate() -> void:
	celebrate_count += 1
	_set_state("CELEBRATION")
	sounds.play("fanfare")
	GameState.post_event("study_celebrate", {})
	_say([{"text": "やったー！！！", "face": "excited"},
		{"text": "宿題、ぜんぶ終わったね！", "face": "happy"},
		{"text": "すっごい！がんばったね！！", "face": "excited"}], _celebration_spoken)

func _celebration_spoken() -> void:
	if state != "CELEBRATION":
		return
	_later(maxf(_celebration_min_s - _state_t, 0.0), _begin_cleanup)

# ------------------------------------------------------------------ HELP
func request_help() -> void:
	if state not in ["STUDYING", "RESUME_STUDY"]:
		if state in HELP_STATES or state == "AI_EXPLAINING":
			notice = "いま見に行っているところだよ"
			changed.emit()
		return
	if tracker.is_filled(help_problem):
		notice = "問題 %d はもう書けているみたい（アームは動かしません）" % help_problem
		_say([{"text": "問題 %d はもう書けているみたい！すごいね！" % help_problem, "face": "happy"}])
		changed.emit()
		return
	_set_state("HELP_LOCATING")
	explanation = {}
	explain_note = ""
	_help_arm_done = false
	_explain_spoken = false
	sounds.play("appear")
	GameState.post_event("study_help", {"problem": help_problem})
	_say([{"text": "困ったの？", "face": "surprised"}, {"text": "ぼくが近くで見てみるよ！", "face": "excited"}])
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
			if stage == "landing":
				_begin_explaining())

func _begin_explaining() -> void:
	_set_state("AI_EXPLAINING")
	_say([{"text": "うーん、よーく見てるよ…", "face": "normal"}])
	services.explain(help_problem)

func _on_explained(result: Dictionary) -> void:
	if state != "AI_EXPLAINING":
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
	if state == "AI_EXPLAINING" and _explain_spoken and _help_arm_done:
		_resume_study()

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
	services.abort()
	_set_state("ERROR")
	sounds.play("pop")
	GameState.post_event("study_error", {"message": text})
	_say([{"text": "あれれ、止まっちゃった。", "face": "worried"},
		{"text": "大人の人に見てもらってね。Enter で続けるよ。", "face": "worried"}])

# ------------------------------------------------------------------ the tidy-up
func _begin_cleanup() -> void:
	if state != "CELEBRATION":
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
	_set_state("GAME_UNLOCKED")
	sounds.play("fanfare")
	GameState.post_event("study_game_unlocked", {"cleanup_ok": cleanup_ok})
	_say([{"text": "お勉強おつかれさま！", "face": "happy"}, {"text": "宿題ぜんぶ終わったね！", "face": "excited"},
		{"text": "これからはゲームの時間だよ！", "face": "wink"}])

## "ゲームで遊ぶ": back to the claw game (its own readiness checks apply as before).
func play_game() -> void:
	if state != "GAME_UNLOCKED":
		return
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
		"GAME_UNLOCKED":
			play_game()

## Space (the game's stop key, which also stops the robot): the study mode stops its motion.
func on_stop_key() -> void:
	if not active():
		return
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
	if keycode == keys.advance or keycode == KEY_KP_ENTER:
		advance()
	elif keycode == help_keycode:
		request_help()
	elif keycode in [keys.fill_1, keys.fill_2, keys.fill_3] and services.mode == "mock":
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

## The arm belongs to the study mode now: no manual jog.
func blocks_manual_control() -> bool:
	return active() and (state in HELP_STATES or state in ["AI_EXPLAINING", "CLEANUP"] or services.motion_active())

## The UFO's mood over the game's one ("" = the game's).
func mood_override() -> String:
	match state:
		"CELEBRATION", "HOMEWORK_COMPLETE", "GAME_UNLOCKED":
			return "SUCCESS"
		"ERROR", "CLEANUP_FAILED":
			return "FAILURE"
	return ""

## The round close-up view is up (capturing).
func wants_scope() -> bool:
	return state in ["CAPTURE_10CM", "CAPTURE_5CM", "CAPTURE_LANDING", "HELP_MOVING"] and help_phase in ["LOWER", "SETTLE", "HOLD"]

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
		"CELEBRATION":
			speech.clear()
			_begin_cleanup()
		"CLEANUP":
			services.abort("F6 でスキップ")
			_cleanup_finished()
		"CLEANUP_FAILED", "ERROR":
			advance()
		"GAME_UNLOCKED":
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
	for t in _timers.duplicate():
		t[0] -= dt
		if t[0] <= 0.0:
			_timers.erase(t)
			if int(t[2]) == _story:
				t[1].call()

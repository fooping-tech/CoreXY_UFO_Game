class_name StaffControl
extends RefCounted
## The exhibition staff's operations (#260): a few named actions that mean the same thing on
## every screen. The keyboard's F6..F10 and, later, an outside device (a button box, a
## remote) go through run(), the one way in; describe() says what an action does on the
## screen now (for a staff overlay or a remote's labels).
##
##   next     F6   on: the screen's step done or its wait skipped (校正 -> the menu, the menu's
##                choice, the study mode's reading / grading skipped, the practice's next step,
##                the result on)
##   skip     F7   all of it: the practice left out, the score game started without it, the
##                study mode ended and on to the score game
##   menu     F8   back to the menu (the title)
##   recover  F9   (#292: after a fault stopped the score game: its recovery screen, then
##                its まとめて準備, pressed twice) the arm out of an alarm / without homing: the alarm cleared, then the
##                preparation (the 校正 tab's 「準備をまとめて実行」; the arm moves), and the easy
##                mode out of its stop
##   switch   F10  the study mode <-> the score game (from the menu, 校正 or the crane: the study)
##   stop     (Space) stops, always
##
## Staff only: nothing here is offered to the visitors' hands. The arm moves only by
## `recover`, through the same commands and gates as the 校正 tab (motors, homing, the motion
## lock, request_id); `stop` is never held back.

const ACTIONS := ["next", "skip", "menu", "recover", "switch", "stop"]
const KEYS := {KEY_F6: "next", KEY_F7: "skip", KEY_F8: "menu", KEY_F9: "recover", KEY_F10: "switch"}
## how the keys read on a screen's hint line
const HINT := "F6 つぎへ  F7 とばす  F8 メニュー  F9 ふっき  F10 べんきょう⇔ゲーム"

var main: Node
## what was done last: [action, screen, what] (tests, the debug log)
var last: Array = []

func _init(m: Node) -> void:
	main = m

## The screen now: settings / title / study / score / crane (the plain crane screen).
func screen() -> String:
	if main.settings_active():
		return "settings"
	if main.title_active():
		return "title"
	if main.study_mode != null and main.study_mode.active():
		return "study"
	if main.game_mode != null and main.game_mode.active():
		return "score"
	return "crane"

## The action for a key (Shift held: none, those are the developers' own), or "".
static func action_for_key(keycode: int, shift := false) -> String:
	if shift:
		return ""
	return str(KEYS.get(keycode, ""))

## What `action` does on this screen now, in a few words ("" = nothing here).
func describe(action: String) -> String:
	var s := screen()
	match action:
		"stop":
			return "とめる"
		"menu":
			return "" if s == "title" else "メニューへ もどる"
		"recover":
			# #292: the score game stopped on a fault: the recovery screen, then its preparation
			if main.get("robot_guard") != null and main.robot_guard.latched():
				if not main.recovery_panel.is_open():
					return "ふっきの画面を ひらく"
				return "まとめて準備（もう一度で アームが動く）" if main.robot_guard.confirm_left <= 0.0 else "まとめて準備を はじめる（アームが動く）"
			if main.arm_recovering():
				return ""
			if main.arm_recovery_reason() != "":
				return "アラーム解除 → まとめて準備（" + main.arm_recovery_reason() + "）"
			if main.easy != null and main.easy.faulted():
				return "かんたんモードを もどす"
			return ""
		"switch":
			return "ゲームへ" if s == "study" else "べんきょうモードへ"
		"next", "skip":
			return _describe_step(action, s)
	return ""

func _describe_step(action: String, s: String) -> String:
	match s:
		"settings":
			return "メニューへ"
		"title":
			return "えらんだ ものを はじめる"
		"study":
			if action == "skip" or main.study_mode.state == "GAME_READY_WITH_REWARD":
				return "べんきょうを おわって ゲームへ"
			return "とばして つづける"
		"score":
			var g = main.game_mode
			if g.phase == "TUTORIAL":
				return "れんしゅうを ぜんぶ とばす" if action == "skip" else "れんしゅうの つぎへ"
			if g.phase in ["IDLE", "STOPPED"]:
				return "れんしゅう なしで はじめる" if action == "skip" else "はじめる"
			if g.phase == "RESULT":
				return "つぎへ"
	return ""

## Does `action` on the screen now. Returns what was done ("" = nothing here, refused or
## unknown). `source` is who asked ("key", a device's name), for the log.
func run(action: String, source := "key") -> String:
	var what := describe(action) if action in ACTIONS else ""
	var s := screen()
	var done := false
	match action:
		"stop":
			main.stop_key()
			done = true
		"menu":
			done = _menu(s)
		"recover":
			done = _recover()
		"switch":
			done = _switch(s)
		"next", "skip":
			done = _step(action, s)
	if not done:
		what = ""
	last = [action, s, what]
	if main.has_signal("debug_log"):
		main.debug_log.emit("staff %s (%s) on %s: %s" % [action, source, s, what if what != "" else "nothing"])
	return what

func _menu(s: String) -> bool:
	match s:
		"title":
			return false
		"settings":
			main.settings.cancel()
		_:
			main.show_title()
	return true

func _recover() -> bool:
	# #292: latched after a fault of the crane: the first press opens the recovery screen, the
	# next ones are its まとめて準備 (asked twice: the arm moves)
	if main.get("robot_guard") != null and main.robot_guard.latched():
		if not main.recovery_panel.is_open():
			main.recovery_panel.open()
			return true
		return main.robot_guard.prepare()
	if main.recover_arm():
		return true
	if main.easy != null and main.easy.faulted():
		main.easy.reset()
		return true
	return false

func _switch(s: String) -> bool:
	match s:
		"settings":
			main.settings.cancel()
			main.title.choose("study")
		"title":
			main.title.choose("study")
		"study":
			_study_to_game()
		_:  # the score game, the crane screen
			main._on_title_chosen("study")
	return true

## The study mode over: its reward when it was earned, then the score game's title.
func _study_to_game() -> void:
	var st = main.study_mode
	if st.state == "GAME_READY_WITH_REWARD":
		st.play_game()
	else:
		st.stop()
		main.open_score_game()

func _step(action: String, s: String) -> bool:
	match s:
		"settings":
			main.settings.cancel()
			return true
		"title":
			main.title.handle_key(KEY_ENTER)
			return true
		"study":
			if action == "skip" or main.study_mode.state == "GAME_READY_WITH_REWARD":
				_study_to_game()
			else:
				main.study_mode.debug_skip()
			return true
		"score":
			var g = main.game_mode
			if g.phase == "TUTORIAL":
				return g.staff_step("all" if action == "skip" else "next")
			if g.phase in ["IDLE", "STOPPED"] and action == "skip":
				g.start()
				return g.running()
			if g.phase in ["IDLE", "STOPPED", "RESULT"]:
				return g.handle_key(KEY_ENTER)
	return false

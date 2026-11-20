class_name GameModeTutorialVoice
extends RefCounted
## UFOくん's voice in the score game's practice (#149): the lines wait a moment for the
## helper's link, a voice is asked of the backend (VOICEVOX / say) and its answer is handed
## to the controller's StudySpeech. Taken out of GameModeController (#222). The voice is
## decoration: nothing of the round, the lanes or the devices waits for it.

var ctl: GameModeController
var _seq := 0
## lines waiting for the voice's link, and for how long still (config game_mode.tutorial.voice_link_wait_s)
var pending: Array = []
var _wait := 0.0
var link_wait_s := 2.5

func _init(c: GameModeController) -> void:
	ctl = c

## Lines for UFOくん. The voice comes over the helper's link, which may only just be
## opening (the practice's first line, the spell): the lines wait for it a moment
## (link_wait_s) instead of being shown without a voice. Never longer: the voice is
## decoration.
func say(lines: Array) -> void:
	ctl.tutorial_speech.clear()
	pending = []
	if link_wait_s > 0.0 and coming():
		pending = lines.duplicate()
		_wait = link_wait_s
		return
	ctl.tutorial_speech.say(lines)

## A voice is possible but its link is not up yet (still connecting, or no hello yet).
func coming() -> bool:
	var hw := client()
	if hw == null or not ctl.tutorial_speech.voice_on or hw.get("link") == null or not hw.link.enabled:
		return false
	return not hw.link.is_open() or not bool(hw.get("hello_seen"))

func tick(dt: float) -> void:
	if pending.is_empty():
		return
	_wait -= dt
	if _wait <= 0.0 or not coming():
		var lines := pending
		pending = []
		ctl.tutorial_speech.say(lines)

## UFOくん's voice for a line: asked of the backend (VOICEVOX / say) over the helper's link.
## "" = no voice now: the line is shown as words for its reading time.
func request(text: String) -> String:
	var hw := client()
	if hw == null or not bool(hw.get("speech_available")) or hw.get("link") == null or not hw.link.is_open():
		return ""
	_seq += 1
	var rid := "sm-gt-say-%d-%d" % [Time.get_ticks_msec(), _seq]  # "sm-": the helper leaves it to its asker
	if hw.link.send_aux({"type": "homework_say", "request_id": rid, "data": {"text": text}}) != OK:
		return ""
	return rid

## The helper's link to the backend (the game's own, else the study mode's): where a voice
## can be asked for. null = there is none (no helper configured): the lines are words only.
func client() -> Node:
	var main: Node = ctl.main
	if main == null:
		return null
	var hw: Node = main.get("homework") if main.get("homework") is Node else null
	if hw == null and main.get("study_mode") != null and main.study_mode != null and main.study_mode.services.homework is Node:
		hw = main.study_mode.services.homework
	if hw != null and hw.has_signal("aux_message") and not hw.aux_message.is_connected(_on_aux):
		hw.aux_message.connect(_on_aux)
	return hw

func _on_aux(msg: Dictionary) -> void:
	var rid := str(msg.get("request_id", ""))
	if not rid.begins_with("sm-gt-"):
		return
	var data: Dictionary = msg.get("data", {}) if msg.get("data") is Dictionary else {}
	match str(msg.get("type", "")):
		"homework_speech":
			ctl.tutorial_speech.on_voice(rid, HomeworkClient.wav_stream(Marshalls.base64_to_raw(str(data.get("wav_base64", "")))), str(data.get("credit", "")))
		"homework_speech_error", "homework_error":
			ctl.tutorial_speech.on_voice_error(rid, str(data.get("message", "")))

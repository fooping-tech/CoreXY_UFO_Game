class_name StudyVoice
extends Node
## The study mode's voice dialogue (#233): the child holds the talk key (V) or the microphone
## button and speaks; on letting go the backend turns it into text (Whisper on this Mac) and the
## text, the worksheet as the overview camera sees it (cut out and turned upright: SheetFrame)
## and the turns so far go to the tutor (the local LLM server). UFOくん says its answer with the
## usual speech (voice + bubble). When the tutor wants a closer look at a problem, the usual HELP
## (the arm's camera) starts for it.
##
## Only while studying, in the camera mode, with the backend's voice (hello: study_voice), and
## never while UFOくん speaks (it would hear itself). The microphone is opened by the backend only
## between the press and the release (at most max_s). Nothing here moves the arm by itself.

signal changed

const IDLE := "idle"
const LISTENING := "listening"  # the key is held
const HEARING := "hearing"  # Whisper is writing it down
const THINKING := "thinking"  # the tutor is answering
const FACES := {"excited": "excited", "happy": "happy", "normal": "normal", "sad": "sad", "surprised": "surprised",
	"worried": "worried", "wink": "wink", "thinking": "worried", "praise": "happy", "celebrate": "excited"}
const MAX_HISTORY := 8

var ctl: StudyModeController
var enabled := true
var max_s := 20.0
var talk_keycode := KEY_V
var state := IDLE
## what the child said last (shown), and the tutor's last answer (data of homework_talk_result)
var heard := ""
var last_answer: Dictionary = {}
var note := ""  # why it cannot listen now / what went wrong (shown small)
## the dialogue: the problem talked about and its turns ([{hint_level, message}], the server's shape)
var target_problem := 0
var history: Array = []
## where the worksheet's picture comes from (the overview camera; tests give their own)
var overview_source: Callable
var _rid := ""
var _held_s := 0.0
var _seq := 0
var _token := 0

func setup(c: StudyModeController) -> void:
	ctl = c
	var v = GameConfig.get_value("study_mode", "voice", {})
	if v is Dictionary:
		enabled = bool(v.get("enabled", enabled))
		max_s = clampf(float(v.get("max_s", max_s)), 1.0, 60.0)
		var code := OS.find_keycode_from_string(str(v.get("key", "V")))
		talk_keycode = code if code != KEY_NONE else KEY_V
	overview_source = func() -> Image: return ctl.services._overview_image()
	var hw := _homework()
	if hw != null:
		hw.aux_message.connect(_on_aux)

func _homework() -> HomeworkClient:
	return ctl.services.homework if ctl != null and ctl.services != null else null

## The study mode's states where the child may talk: doing the homework (not while the arm
## looks at a problem, UFOくん explains, celebrates or tidies up).
const TALK_STATES := ["STUDYING", "RESUME_STUDY"]

func in_talk_state() -> bool:
	return ctl != null and ctl.state in TALK_STATES

## Why the child cannot talk to UFOくん now ("" when they can).
func blocker() -> String:
	if not enabled:
		return "声の対話は オフ（study_mode.voice.enabled）"
	if ctl == null or not ctl.active():
		return "勉強モードではない"
	if ctl.services.mode == "simulated":
		return "模擬の勉強モード（カメラのときだけ話せる）"
	var hw := _homework()
	if hw == null or not hw.hello_seen:
		return "バックエンドにつながっていない"
	if not hw.voice_available:
		return hw.voice_problem if hw.voice_problem != "" else "バックエンドに声の入力がない"
	if not in_talk_state():
		return "いまは 話せない（宿題中に話せる）"
	if ctl.speech.busy():
		return "UFOくんが 話しているところ"
	if state != IDLE:
		return "前の声を 聞いているところ"
	return ""

func can_talk() -> bool:
	return blocker() == ""

## The key or the button went down: start listening.
func press() -> void:
	var why := blocker()
	if why != "":
		note = why
		changed.emit()
		return
	var hw := _homework()
	_rid = _next_rid("ls")
	if hw.link.send_aux({"type": "homework_listen_start", "request_id": _rid, "data": {}}) != OK:
		_rid = ""
		note = "バックエンドに送れなかった"
		changed.emit()
		return
	state = LISTENING
	_held_s = 0.0
	heard = ""
	note = ""
	changed.emit()

## The key or the button came up: what was said goes to Whisper.
func release() -> void:
	if state != LISTENING:
		return
	_rid = _next_rid("lst")
	if _homework().link.send_aux({"type": "homework_listen_stop", "request_id": _rid, "data": {}}) != OK:
		_fail("バックエンドに送れなかった", false)
		return
	state = HEARING
	changed.emit()

## Drop whatever is going on (Space, the study mode ending, leaving the studying state).
func cancel() -> void:
	if state == IDLE:
		return
	var hw := _homework()
	if state == LISTENING and hw != null:
		hw.link.send_aux({"type": "homework_listen_cancel", "data": {}})
	_token += 1
	_rid = ""
	state = IDLE
	changed.emit()

## A new study session: a new dialogue.
func reset() -> void:
	cancel()
	heard = ""
	last_answer = {}
	note = ""
	target_problem = 0
	history.clear()

func tick(dt: float) -> void:
	if state == LISTENING:
		_held_s += dt
		if _held_s >= max_s:
			release()  # the backend stops at max_s too
	if state != IDLE and not in_talk_state():
		cancel()

func _next_rid(kind: String) -> String:
	_seq += 1
	return "sm-%s-%d" % [kind, _seq]

func _on_aux(msg: Dictionary) -> void:
	var rid := str(msg.get("request_id", ""))
	if rid == "" or rid != _rid:
		return
	var t := str(msg.get("type", ""))
	var data: Dictionary = msg.get("data", {}) if msg.get("data") is Dictionary else {}
	match t:
		"homework_listen":
			pass  # the microphone is open
		"homework_heard":
			heard = str(data.get("text", "")).strip_edges()
			_ask(heard)
		"homework_heard_error":
			var code := str(data.get("code", ""))
			_fail(str(data.get("message", "")), code == "not_heard")
		"homework_talk_result":
			_answer(data)
		"homework_talk_error", "homework_error":
			_fail(str(data.get("message", "うまく いかなかった")), false)

## The child's words + the worksheet now -> the tutor.
func _ask(text: String) -> void:
	var hw := _homework()
	var img: Image = overview_source.call()
	if img == null or img.is_empty():
		_fail("俯瞰カメラの映像がない", false)
		return
	var jpeg := StudyClient.encode_jpeg(hw.watch_image(img), hw.max_image_edge, hw.max_image_bytes)
	if jpeg.is_empty():
		_fail("画像を上限サイズ内に圧縮できなかった", false)
		return
	# a number said ("3ばん") picks the problem itself; else the one being talked about
	var target := 0 if mentions_number(text) else target_problem
	_rid = _next_rid("talk")
	var err := hw.link.send_aux({"type": "homework_talk", "request_id": _rid, "data": {
		"text": text, "image_jpeg_base64": Marshalls.raw_to_base64(jpeg), "target_problem": target,
		"history": history.duplicate(), "worksheet_id": str(ctl.current_worksheet().get("worksheet_id", ""))}})
	if err != OK:
		_fail("バックエンドに送れなかった", false)
		return
	state = THINKING
	changed.emit()

static func mentions_number(text: String) -> bool:
	var re := RegEx.create_from_string("[0-9０-９一二三四五六七八九十]|ばん|番")
	return re.search(text) != null

func _answer(data: Dictionary) -> void:
	_rid = ""
	state = IDLE
	last_answer = data
	var tp := int(data.get("target_problem", 0)) if data.get("target_problem") != null else 0
	if tp > 0 and tp != target_problem:
		target_problem = tp
		history.clear()  # another problem: its own turns
	var message := str(data.get("message", ""))
	history.append({"hint_level": int(data.get("hint_level", 0)), "message": message})
	while history.size() > MAX_HISTORY:
		history.pop_front()
	var face: String = FACES.get(str(data.get("ufo_face", "")), FACES.get(str(data.get("visual_effect", "")), "normal"))
	var lines: Array = []
	var parts: Array = data.speech_lines if data.get("speech_lines") is Array and not (data.speech_lines as Array).is_empty() \
		else [message]
	for p in parts:
		lines.append({"text": str(p), "face": face})
	var look := bool(data.get("need_recapture", false)) and tp > 0
	if str(data.get("action", "")) == "praise":
		GameState.post_event("study_voice_praise", {"problem": tp})
	changed.emit()
	ctl.voice_answer(lines, tp if look else 0)

func _fail(message: String, not_heard: bool) -> void:
	_rid = ""
	state = IDLE
	note = message
	changed.emit()
	ctl.voice_answer([{"text": "ごめんね、よく きこえなかった。もういちど おしえてね。" if not_heard
		else "いまは うまく こたえられないみたい。ごめんね。", "face": "worried"}], 0)

## What the HUD shows about talking.
func status_text() -> String:
	match state:
		LISTENING:
			return "きいてるよ…（はなしおわったら %s を はなしてね）" % OS.get_keycode_string(talk_keycode)
		HEARING:
			return "きいた ことばを かいてるよ…"
		THINKING:
			return "かんがえちゅう…"
	if can_talk():
		return "%s を おしながら はなしかけてね" % OS.get_keycode_string(talk_keycode)
	return ""

class_name StudyVoice
extends Node
## The study mode's voice dialogue (#233): the child holds the talk key (V) or the microphone
## button and speaks; on letting go the backend turns it into text (Whisper on this Mac) and the
## text, the worksheet as the overview camera sees it (cut out and turned upright: SheetFrame)
## and the turns so far go to the tutor (the local LLM server, its "dialog" format, streamed).
## UFOくん starts saying the answer with its first sentence (homework_talk_delta), while the rest
## is still being made, with the usual speech (voice + bubble). When the tutor wants a closer look
## at a problem, the usual HELP (the arm's camera) starts for it.
##
## Only while studying, in the camera mode, with the backend's voice (hello: study_voice), and
## never while UFOくん speaks (it would hear itself). The microphone is opened by the backend only
## between the press and the release (at most max_s). Nothing here moves the arm by itself.

signal changed

const IDLE := "idle"
const LISTENING := "listening"  # the key is held
const HEARING := "hearing"  # Whisper is writing it down
const THINKING := "thinking"  # the tutor is answering
const ANSWERING := "answering"  # its first sentences are being said, the rest is coming
const FACES := {"excited": "excited", "happy": "happy", "normal": "normal", "sad": "sad", "surprised": "surprised",
	"worried": "worried", "wink": "wink", "thinking": "worried", "praise": "happy", "celebrate": "excited"}
const MAX_HISTORY := 10
## an answer that does not come in this long is given up (a lost link, a stuck server)
const WAIT_S := 90.0  # messages: the API takes 12 with the picture and the new question

var ctl: StudyModeController
var enabled := true
var max_s := 20.0
var talk_keycode := KEY_V
var state := IDLE
## what the child said last (shown), and the tutor's last answer (data of homework_talk_result)
var heard := ""
var last_answer: Dictionary = {}
var note := ""  # why it cannot listen now / what went wrong (shown small)
## the dialogue: the problem talked about and its turns ([{role: user|assistant, content}])
var target_problem := 0
var history: Array = []
## where the worksheet's picture comes from (the overview camera; tests give their own)
var overview_source: Callable
var _rid := ""
var _waited_s := 0.0
var _said := 0  # sentences of this answer already given to the speech
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
		hw.link_lost.connect(_on_link_lost)  # review on #235: never wait forever for a lost answer

func _homework() -> HomeworkClient:
	return ctl.services.homework if ctl != null and ctl.services != null else null

## The study mode's states where the child may talk: doing the homework (not while the arm
## looks at a problem, UFOくん explains, celebrates or tidies up).
const TALK_STATES := ["STUDYING", "RESUME_STUDY"]

func in_talk_state() -> bool:
	if ctl == null:
		return false
	# #281: the check's summary too, once the dialogue mode is on
	return ctl.state in TALK_STATES or (ctl.dialog_mode and ctl.state == "REVIEW_SUMMARY")

## Why the child cannot talk to UFOくん now ("" when they can).
func blocker() -> String:
	if not enabled:
		return "声の対話は オフ（study_mode.voice.enabled）"
	if ctl == null or not ctl.active():
		return "勉強モードではない"
	if ctl.dialog_needs_thumb and not ctl.dialog_mode:  # #281
		return "いいね 👍 を %d びょう みせると おはなしモード" % roundi(ctl.dialog_thumb_s)
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
	elif state != IDLE:
		_waited_s += dt
		if _waited_s >= WAIT_S:
			_fail("返事が来なかった", false)
	if state != IDLE and not in_talk_state():
		cancel()

## The backend's link went away: the answer being waited for will not come.
func _on_link_lost() -> void:
	if state == IDLE:
		return
	_token += 1
	_rid = ""
	state = IDLE
	note = "バックエンドとの つながりが切れた"
	changed.emit()

func _next_rid(kind: String) -> String:
	_seq += 1
	_waited_s = 0.0
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
		"homework_talk_delta":
			_sentence(str(data.get("text", "")))
		"homework_talk_result":
			_answer(data)
		"homework_talk_error", "homework_error":
			_fail(str(data.get("message", "うまく いかなかった")), false)

## The child's words + the worksheet now -> the tutor.
## What the child names (#237, the backend's number_in_utterance): "1ばん", "１番", "(1)", "①",
## "いちばん", "一番", "もんだい 1". 0 = no problem named.
const KANA_NUMBERS := {"じゅう": 10, "きゅう": 9, "いち": 1, "さん": 3, "よん": 4, "ろく": 6, "なな": 7, "しち": 7,
	"はち": 8, "に": 2, "し": 4, "ご": 5, "く": 9}
const KANJI_NUMBERS := {"一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10}
static func number_in(text: String) -> int:
	var t := text
	for i in 10:
		t = t.replace(char(0xFF10 + i), str(i))
	for ch in t:
		var c := ch.unicode_at(0)
		if c >= 0x2460 and c <= 0x2473:  # ① .. ⑳
			return c - 0x2460 + 1
	var re := RegEx.create_from_string("([0-9]{1,2})\\s*(ばん|番|もん|問)|[(（]\\s*([0-9]{1,2})\\s*[)）]|(もんだい|問題)\\s*([0-9]{1,2})")
	var m := re.search(t)
	if m != null:
		for g in [1, 3, 5]:
			if m.get_string(g) != "":
				return int(m.get_string(g))
	var kana := RegEx.create_from_string("(じゅう|きゅう|いち|さん|よん|ろく|なな|しち|はち|に|し|ご|く)\\s*(ばん|番)")
	m = kana.search(t)
	if m != null:
		return int(KANA_NUMBERS[m.get_string(1)])
	var kanji := RegEx.create_from_string("([一二三四五六七八九十])\\s*(ばん|番)")
	m = kanji.search(t)
	if m != null:
		return int(KANJI_NUMBERS[m.get_string(1)])
	return 0

func _ask(text: String) -> void:
	# a problem named ("1ばんが わからない"): go and look at it (the overview camera finds it, the
	# arm's camera looks closer, the tutor explains: the usual HELP; a grown-up's Enter first on
	# the real crane). Nothing named: the dialogue answers.
	var named := number_in(text)
	# (review on #282: at the check's summary the arm's HELP does not run: the tutor answers,
	# about that problem, from the sheet's picture)
	if named > 0 and in_talk_state() and ctl.state in TALK_STATES:
		_rid = ""
		state = IDLE
		note = ""
		history.append({"role": "user", "content": text})
		target_problem = named
		changed.emit()
		ctl.request_help(named, true)
		return
	var hw := _homework()
	var img: Image = overview_source.call()
	if img == null or img.is_empty():
		_fail("俯瞰カメラの映像がない", false)
		return
	var jpeg := StudyClient.encode_jpeg(hw.watch_image(img), hw.max_image_edge, hw.max_image_bytes)
	if jpeg.is_empty():
		_fail("画像を上限サイズ内に圧縮できなかった", false)
		return
	# the backend reads a number said ("3ばん"); else the problem being talked about
	var target := target_problem
	_rid = _next_rid("talk")
	var err := hw.link.send_aux({"type": "homework_talk", "request_id": _rid, "data": {
		"text": text, "image_jpeg_base64": Marshalls.raw_to_base64(jpeg), "target_problem": target,
		"history": history.duplicate(), "worksheet_id": str(ctl.current_worksheet().get("worksheet_id", ""))}})
	if err != OK:
		_fail("バックエンドに送れなかった", false)
		return
	state = THINKING
	_said = 0
	changed.emit()

## A sentence of the answer while the rest is still coming: said at once.
func _sentence(text: String) -> void:
	if text.strip_edges() == "" or state not in [THINKING, ANSWERING]:
		return
	ctl.voice_lines([{"text": text, "face": "normal"}], _said == 0)
	_said += 1
	state = ANSWERING
	changed.emit()

func _answer(data: Dictionary) -> void:
	_rid = ""
	state = IDLE
	last_answer = data
	var tp := int(data.get("target_problem", 0)) if data.get("target_problem") != null else 0
	if tp > 0 and tp != target_problem:
		target_problem = tp
		history.clear()  # another problem: its own turns
	var message := str(data.get("message", ""))
	history.append({"role": "user", "content": heard})
	history.append({"role": "assistant", "content": message})
	while history.size() > MAX_HISTORY:
		history.pop_front()
	var face: String = FACES.get(str(data.get("visual_effect", "")), "normal")
	var rest: Array = data.rest if data.get("rest") is Array else ([] if _said > 0 else [message])
	var lines: Array = []
	for p in rest:
		lines.append({"text": str(p), "face": face})
	if not lines.is_empty():
		ctl.voice_lines(lines, _said == 0)
	var look := bool(data.get("need_recapture", false)) and tp > 0
	changed.emit()
	ctl.voice_done(tp if look else 0)

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
		ANSWERING:
			return ""
	if can_talk():
		return "%s を おしながら はなしかけてね" % OS.get_keycode_string(talk_keycode)
	return ""

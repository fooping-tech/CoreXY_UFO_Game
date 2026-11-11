class_name StudySpeech
extends Node
## UFOくん's lines, one at a time: each line is shown in the speech bubble right
## away and, when a voice is available, also spoken (VOICEVOX / macOS say, made by
## the backend: `voice_request` sends the text and returns a request id, the WAV
## comes back through `on_voice`). A line ends when its voice finishes, or after a
## reading time when there is no voice (off, unavailable, an error, or it did not
## come within voice_wait_s): the experience never waits on the voice engine.

signal line_started(text: String, face: String)
signal line_finished(text: String)
signal queue_empty

## Callable(text: String) -> String (request id, "" = no voice for this line).
var voice_request: Callable
var voice_on := true
var voice_wait_s := 3.0
var min_line_s := 1.4
var chars_per_s := 9.0
var current := ""
var current_face := ""
var credit := ""
var status := ""
var _queue: Array[Dictionary] = []
var _rid := ""
var _left := 0.0  # seconds until the line ends without a voice
var _waiting_voice := false
var _player: AudioStreamPlayer

func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.name = "UfoVoice"
	add_child(_player)
	_player.finished.connect(_on_voice_finished)

func busy() -> bool:
	return current != "" or not _queue.is_empty()

## Queue lines: Strings or {text, face}.
func say(lines: Array, face := "") -> void:
	for l in lines:
		var item: Dictionary = l if l is Dictionary else {"text": str(l), "face": face}
		if str(item.get("text", "")).strip_edges() != "":
			_queue.append(item)
	if current == "":
		_next()

## Drop everything (state change, reset); the bubble keeps the last line until the next.
func clear() -> void:
	_queue.clear()
	_rid = ""
	_waiting_voice = false
	_left = 0.0
	if _player != null:
		_player.stop()
	current = ""

## Reading time for a line without a voice.
func reading_time(text: String) -> float:
	return maxf(min_line_s, 0.6 + text.length() / chars_per_s)

func _next() -> void:
	if _queue.is_empty():
		current = ""
		queue_empty.emit()
		return
	var item: Dictionary = _queue.pop_front()
	current = str(item.text)
	current_face = str(item.get("face", ""))
	_left = reading_time(current)
	_rid = ""
	_waiting_voice = false
	if voice_on and voice_request.is_valid():
		_rid = str(voice_request.call(current))
		_waiting_voice = _rid != ""
		if _waiting_voice:
			_left = voice_wait_s + reading_time(current)
	line_started.emit(current, current_face)

## The backend's answer to a voice request.
func on_voice(rid: String, stream: AudioStream, line_credit := "") -> void:
	if rid == "" or rid != _rid or current == "":
		return
	_waiting_voice = false
	if line_credit != "":
		credit = line_credit
	if stream == null:
		_left = reading_time(current)  # no audio: read it instead
		return
	_player.stream = stream
	_player.play()
	_left = stream.get_length() + 0.4  # a fallback if `finished` never comes

func on_voice_error(rid: String, message: String) -> void:
	if rid != "" and rid == _rid:
		status = "声が出せませんでした（文字で表示中）: " + message
		_waiting_voice = false
		_left = reading_time(current)

func _on_voice_finished() -> void:
	if current != "":
		_end_line()

func _process(dt: float) -> void:
	if current == "":
		return
	_left -= dt
	if _left <= 0.0:
		_end_line()

func _end_line() -> void:
	var done := current
	_player.stop()
	_rid = ""
	current = ""
	line_finished.emit(done)
	_next()

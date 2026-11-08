class_name HomeworkClient
extends Node
## Homework watch: while running, capture the overview camera every interval_s and
## send it to the backend, which estimates the worksheet's progress with Jev.
## Own WebSocket link (aux: hello + homework_* only); never touches the robot.
## Keeps running when the panel or tab changes: only stop() ends it.

signal state_changed

var cameras: CameraHub
var link: UfoWebSocketClient
var session_id := ""
## stopped | connecting | running | unavailable | error
var state := "stopped"
var status_text := "「宿題スタート」で見守りを始める"
var camera_role := "overview"
var interval_s := 10.0
var max_image_edge := 1024
var max_image_bytes := 700000
## The shown progress (median of the last updated readings) and the last reading.
var progress_pct := NAN
var last_pct := NAN
var held_reason := ""
var last_update_ms := 0
var count := 0
var skipped := 0
var errors := 0
var cost_usd := 0.0
## Every reading of this session: {elapsed_s, progress_pct, smoothed_pct, held}
var history: Array[Dictionary] = []
var _started_ms := 0
var _stopped_elapsed := 0.0
var _next_ms := 0
var _waiting := false  # a frame was sent and its answer has not come back
var _seq := 0

func setup(hub: CameraHub) -> void:
	cameras = hub
	camera_role = str(GameConfig.get_value("homework", "camera_role", "overview"))
	interval_s = maxf(float(GameConfig.get_value("homework", "interval_s", 10.0)), 2.0)
	max_image_edge = int(GameConfig.get_value("homework", "max_image_edge", 1024))
	max_image_bytes = int(GameConfig.get_value("homework", "max_image_bytes", 700000))
	link = UfoWebSocketClient.new()
	link.name = "HomeworkLink"
	link.study_only = true  # aux link: hello + study_* / homework_* only, no RobotState
	link.auto_reconnect = true
	link.outbound_buffer_size = maxi(1048576, max_image_bytes * 2)
	link.study_message.connect(_on_message)
	link.disconnected.connect(_on_disconnected)
	add_child(link)

func running() -> bool:
	return state == "running" or state == "connecting"

func start() -> void:
	if running():
		return
	session_id = "homework-%d-%d" % [Time.get_ticks_msec(), randi()]
	_started_ms = Time.get_ticks_msec()
	_stopped_elapsed = 0.0
	progress_pct = NAN
	last_pct = NAN
	held_reason = ""
	last_update_ms = 0
	count = 0
	skipped = 0
	errors = 0
	cost_usd = 0.0
	history.clear()
	_waiting = false
	state = "connecting"
	status_text = "バックエンドに接続中…"
	link.enabled = true
	state_changed.emit()
	if link.is_open():
		_send_start()

func stop(reason := "") -> void:
	if session_id != "" and link.is_open():
		link.send_aux({"type": "homework_stop", "data": {"session_id": session_id}})
	if running():
		_stopped_elapsed = elapsed_s()
	session_id = ""
	state = "stopped"
	status_text = reason if reason != "" else "終了しました（表示は最後の値）"
	_waiting = false
	link.enabled = false
	state_changed.emit()

## Seconds since start (frozen once stopped).
func elapsed_s() -> float:
	if running():
		return (Time.get_ticks_msec() - _started_ms) / 1000.0
	return _stopped_elapsed

func _process(_dt: float) -> void:
	if state != "running" or Time.get_ticks_msec() < _next_ms:
		return
	_next_ms = Time.get_ticks_msec() + int(interval_s * 1000.0)
	if _waiting:
		skipped += 1  # the last estimate is still running: skip this tick (as the jev repo does)
		return
	if cameras == null or not cameras.has_feed(camera_role):
		status_text = "%s カメラに映像がありません" % camera_role
		state_changed.emit()
		return
	var jpeg := StudyClient.encode_jpeg(cameras.texture(camera_role).get_image(), max_image_edge, max_image_bytes)
	if jpeg.is_empty():
		status_text = "画像を上限サイズ内に圧縮できませんでした"
		state_changed.emit()
		return
	_seq += 1
	var err := link.send_aux({"type": "homework_frame", "request_id": "hw-%d" % _seq, "data": {
		"session_id": session_id, "image_jpeg_base64": Marshalls.raw_to_base64(jpeg)}})
	if err == OK:
		_waiting = true
		status_text = "推定中…"
	else:
		status_text = "画像を送信できませんでした（WebSocket error %d）" % err
	state_changed.emit()

func _send_start() -> void:
	link.send_aux({"type": "homework_start", "data": {"session_id": session_id}})

func _on_message(msg: Dictionary) -> void:
	var t := str(msg.get("type", ""))
	var data: Dictionary = msg.get("data", {}) if msg.get("data") is Dictionary else {}
	if t == "hello":
		if state != "connecting" and state != "running":
			return
		if not bool(data.get("homework", false)):
			state = "unavailable"
			status_text = "バックエンドで宿題の見守りが無効です（config の homework.enabled）"
		else:
			_send_start()
	elif t == "homework_status":
		if str(data.get("state", "")) == "running" and state == "connecting":
			state = "running"
			_next_ms = Time.get_ticks_msec()  # the first frame right away
			status_text = "見守り中（%d 秒ごとに撮影）" % int(interval_s)
	elif t == "homework_progress":
		_waiting = false
		_apply_summary(data)
		last_pct = _num(data.get("progress_pct"))
		var smoothed := _num(data.get("smoothed_pct"))
		if not is_nan(smoothed):
			progress_pct = smoothed
		held_reason = str(data.get("held_reason", ""))
		last_update_ms = Time.get_ticks_msec()
		history.append({"elapsed_s": elapsed_s(), "progress_pct": last_pct, "smoothed_pct": progress_pct, "held": held_reason})
		status_text = "見守り中" + ("" if held_reason == "" else "（%s のため前の値のまま）" % held_text(held_reason))
	elif t == "homework_error":
		_waiting = false
		errors += 1
		_apply_summary(data)
		var code := str(data.get("code", ""))
		var message := str(data.get("message", "不明なエラー"))
		if code in ["config", "disabled"]:
			state = "error"
			status_text = "開始できません: " + message
			link.enabled = false
		elif bool(data.get("stopped", false)):
			stop("エラーが続いたため止めました: " + message)
			return
		else:
			status_text = "エラー（次の撮影で続ける）: " + message
	else:
		return
	state_changed.emit()

func _apply_summary(data: Dictionary) -> void:
	count = int(data.get("count", count))
	skipped = maxi(skipped, int(data.get("skipped", 0)))
	cost_usd = float(data.get("cost_usd", cost_usd))

func _on_disconnected() -> void:
	if running():
		_waiting = false
		state = "connecting"
		status_text = "バックエンドとの接続が切れました。再接続中…"
		state_changed.emit()

static func _num(v) -> float:
	return float(v) if v != null else NAN

## "12:34" / "1:02:03"
static func format_elapsed(seconds: float) -> String:
	var s := int(maxf(seconds, 0.0))
	if s >= 3600:
		return "%d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]
	return "%02d:%02d" % [s / 60, s % 60]

static func held_text(reason: String) -> String:
	match reason:
		"not_visible":
			return "プリントが見えない"
		"occluded":
			return "手やペンで解答欄が隠れている"
		"no_answer":
			return "推定できなかった"
		_:
			return reason

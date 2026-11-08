class_name StudyClient
extends Node
## Optional, non-robot connection for a manually captured camera frame.

signal state_changed

var cameras: CameraHub
var link: UfoWebSocketClient
var session_id := ""
var request_id := ""
var state := "closed"
var status_text := "学習セッションを開始してください"
var answer := ""
var server_available := false
## Who answers, from the backend's hello (study.provider): "claude" or "codex".
var provider := ""
var camera_role := "overview"
var max_image_edge := 1280
var max_image_bytes := 700000
var _seq := 0

func setup(hub: CameraHub) -> void:
	cameras = hub
	camera_role = str(GameConfig.get_value("study", "camera_role", "overview"))
	max_image_edge = int(GameConfig.get_value("study", "max_image_edge", 1280))
	max_image_bytes = int(GameConfig.get_value("study", "max_image_bytes", 700000))
	link = UfoWebSocketClient.new()
	link.name = "StudyLink"
	link.study_only = true
	link.auto_reconnect = true
	# Base64 expands JPEGs by 4/3 and the JSON envelope adds a little more.
	# Keep margin for one complete queued message (WebSocketPeer rejects it otherwise).
	link.outbound_buffer_size = maxi(1048576, max_image_bytes * 2)
	link.study_message.connect(_on_message)
	link.disconnected.connect(_on_disconnected)
	add_child(link)

func start_session() -> void:
	if session_id != "" and state != "closed":
		return
	session_id = "study-%d-%d" % [Time.get_ticks_msec(), randi()]
	state = "connecting"
	status_text = "バックエンドに接続中…"
	answer = ""
	link.enabled = true
	state_changed.emit()
	if link.is_open():
		_send_session_start()

func end_session() -> void:
	if session_id != "" and link.is_open():
		link.send_aux({"type": "study_session_end", "data": {"session_id": session_id}})
	session_id = ""
	request_id = ""
	state = "closed"
	status_text = "学習セッションを終了しました"
	answer = ""
	server_available = false
	link.enabled = false
	state_changed.emit()

func ask(question: String) -> void:
	question = question.strip_edges()
	if state != "ready" or question == "":
		status_text = "質問を入力し、セッションの準備完了を待ってください"
		state_changed.emit()
		return
	if cameras == null or not cameras.has_feed(camera_role):
		status_text = "%s カメラに映像がありません" % camera_role
		state_changed.emit()
		return
	var image := cameras.texture(camera_role).get_image()
	var jpeg := encode_jpeg(image, max_image_edge, max_image_bytes)
	if jpeg.is_empty():
		status_text = "画像を上限サイズ内に圧縮できませんでした"
		state_changed.emit()
		return
	_seq += 1
	request_id = "study-r%d-%d" % [Time.get_ticks_msec(), _seq]
	answer = ""
	state = "thinking"
	status_text = "%sが画像を確認しています…" % provider_label(provider)
	var error := link.send_aux({"type": "study_request", "request_id": request_id, "data": {
		"session_id": session_id, "question": question, "camera_role": camera_role,
		"image_jpeg_base64": Marshalls.raw_to_base64(jpeg)}})
	if error != OK:
		state = "ready"
		request_id = ""
		status_text = "画像を送信できませんでした（WebSocket error %d）" % error
	state_changed.emit()

func cancel() -> void:
	if state == "thinking" and request_id != "":
		link.send_aux({"type": "study_cancel", "request_id": request_id, "data": {}})

static func encode_jpeg(source: Image, edge_limit: int, byte_limit: int) -> PackedByteArray:
	if source == null or source.is_empty():
		return PackedByteArray()
	var image := source.duplicate()
	var largest := maxi(image.get_width(), image.get_height())
	if largest > edge_limit:
		var scale := float(edge_limit) / float(largest)
		image.resize(maxi(1, int(image.get_width() * scale)), maxi(1, int(image.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
	for quality in [0.86, 0.72, 0.58, 0.44, 0.30]:
		var bytes: PackedByteArray = image.save_jpg_to_buffer(quality)
		if not bytes.is_empty() and bytes.size() <= byte_limit:
			return bytes
	return PackedByteArray()

func _send_session_start() -> void:
	link.send_aux({"type": "study_session_start", "data": {"session_id": session_id}})

func _on_message(msg: Dictionary) -> void:
	var t := str(msg.get("type", ""))
	var data: Dictionary = msg.get("data", {}) if msg.get("data") is Dictionary else {}
	if t == "hello":
		server_available = bool(data.get("study", false))
		provider = str(data.get("study_provider", ""))
		if not server_available:
			state = "unavailable"
			status_text = "バックエンドの学習機能が無効です（--study と config を確認）"
		else:
			_send_session_start()
	elif t == "study_status":
		server_available = bool(data.get("available", true))
		var next := str(data.get("state", ""))
		if next == "ready":
			state = "ready"
			status_text = "準備完了"
		elif next == "thinking":
			state = "thinking"
		elif next == "closed":
			state = "closed"
	elif t == "study_delta" and str(msg.get("request_id", "")) == request_id:
		answer += str(data.get("text", ""))
	elif t == "study_result" and str(msg.get("request_id", "")) == request_id:
		state = "ready"
		status_text = "回答完了。続けて質問できます"
		request_id = ""
	elif t == "study_error":
		state = "ready" if session_id != "" and server_available else "unavailable"
		status_text = "エラー: " + str(data.get("message", "不明なエラー"))
		request_id = ""
	state_changed.emit()

func _on_disconnected() -> void:
	if session_id != "":
		state = "connecting"
		status_text = "バックエンドとの接続が切れました。再接続中…"
		state_changed.emit()

## The name shown for a study provider.
static func provider_label(p: String) -> String:
	match p:
		"claude":
			return "Claude Code"
		"codex":
			return "Codex"
		_:
			return "アシスタント"

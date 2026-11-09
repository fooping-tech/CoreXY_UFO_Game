class_name HomeworkClient
extends Node
## Homework watch: while running, capture the overview camera every interval_s and
## send it to the backend, which estimates the worksheet's progress with Jev.
## Own WebSocket link (aux: hello + homework_* only); never touches the robot.
## Keeps running when the panel or tab changes: only stop() ends it.
##
## Stage 1 of the advice (#76): when the backend reports a stall, the panel offers
## "近づいてアドバイス": the robot link (the game's main connection) starts the
## backend's approach sequence (arm camera down to the recorded spot); at HOLD this
## client captures the overview + focus frames side by side, asks for advice on the
## aux link and releases the arm (it goes back up while the advice is written).
##
## Stage 2 (#78): the overview image <-> CoreXY XY calibration lives in the backend
## (camera_map_*). Calibrate: centre the arm's camera on a mark, click the mark in the
## overview image (`calib_add`). Look: click a point (`look_at`): the backend maps it to
## XY and runs the approach there (no advice); it stays down until `look_done` or the
## hold timeout.
##
## Stage 3 (#79), the helper: when the backend reports a stall, say "手伝おうか？" once
## (again after offer_repeat_s while still stalled). The stuck key (Y) or, within
## offer_window_s of the offer, a thumbs-up (only while the gesture control is off)
## asks the backend which problem the child is stuck on; the next key (N) asks for the
## next problem to solve. The backend names it and finds its answer box (the study
## assistant, checked with Jev); only a box it calls usable is looked at (the look above,
## so it needs the calibration). Otherwise nothing moves and the helper says so. The
## voice is made by the backend (VOICEVOX / macOS say) and played here.

signal state_changed

var cameras: CameraHub
var link: UfoWebSocketClient
## The game's robot connection (commands + homework_approach status); null without one.
var robot_ws: UfoWebSocketClient
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
## The backend's stall verdict (no gain of stall_min_gain points for stall_s).
var stalled := false
var stalled_for_s := 0.0
## "" | approaching | thinking | done | error
var advice_state := ""
var advice_text := ""
var advice_status := ""
## The backend's approach sequence: {active, phase, error, last_result, spot}
var approach: Dictionary = {}
var advice_available := false
## The backend's camera calibration: {points, camera, usable, problem, rms_mm, max_mm, h_inv, ...}
var camera_map: Dictionary = {}
var calib_status := ""
## true while a look (clicked point) runs: HOLD is not released by the advice
var looking := false
var _look_moving := false
var _approach_rid := ""
## ---- helper (#79)
var speech_available := false
var voice_on := true
var speech_status := ""
## "VOICEVOX:<character>" of the last VOICEVOX line (the VOICEVOX terms ask for it to be shown)
var speech_credit := ""
var player: AudioStreamPlayer
var helper_offer := true
var offer_text := "手伝おうか？"
var offer_repeat_s := 300.0
var offer_window_s := 60.0
var thumb_hold_ms := 800.0
## kind ("stuck" / "next") -> keycode
var focus_keys := {"stuck": KEY_Y, "next": KEY_N}
## "" | locating | done | unsure | error
var locate_state := ""
var locate_status := ""
var locate_kind := ""
## The last homework_locate_result data.
var last_locate: Dictionary = {}
var _offer_until_ms := 0
var _last_offer_ms := -1
var _offered_this_stall := false
var _thumb_since_ms := -1.0
var _thumb_spent := false
var _captured := false
var _started_ms := 0
var _stopped_elapsed := 0.0
var _next_ms := 0
var _waiting := false  # a frame was sent and its answer has not come back
var _seq := 0

func setup(hub: CameraHub, robot_link: UfoWebSocketClient = null) -> void:
	cameras = hub
	robot_ws = robot_link
	if robot_ws != null:
		robot_ws.message_received.connect(_on_robot_message)
		robot_ws.ack.connect(_on_robot_ack)
		robot_ws.connected.connect(request_camera_map)
	camera_role = str(GameConfig.get_value("homework", "camera_role", "overview"))
	interval_s = maxf(float(GameConfig.get_value("homework", "interval_s", 10.0)), 2.0)
	max_image_edge = int(GameConfig.get_value("homework", "max_image_edge", 1024))
	max_image_bytes = int(GameConfig.get_value("homework", "max_image_bytes", 700000))
	link = UfoWebSocketClient.new()
	link.name = "HomeworkLink"
	link.study_only = true  # aux link: hello + study_* / homework_* only, no RobotState
	link.auto_reconnect = true
	link.outbound_buffer_size = maxi(1048576, max_image_bytes * 2)
	link.inbound_buffer_size = 4194304  # the helper's voice comes as a WAV in base64
	link.study_message.connect(_on_message)
	link.disconnected.connect(_on_disconnected)
	add_child(link)
	var h = GameConfig.get_value("homework", "helper", {})
	configure_helper(h if h is Dictionary else {})
	player = AudioStreamPlayer.new()
	player.name = "HelperVoice"
	add_child(player)

func configure_helper(c: Dictionary) -> void:
	helper_offer = bool(c.get("offer", helper_offer))
	offer_text = str(c.get("offer_text", offer_text))
	offer_repeat_s = maxf(float(c.get("offer_repeat_s", offer_repeat_s)), 10.0)
	offer_window_s = maxf(float(c.get("offer_window_s", offer_window_s)), 1.0)
	thumb_hold_ms = maxf(float(c.get("thumb_hold_ms", thumb_hold_ms)), 0.0)
	var keys = c.get("keys", {})
	if keys is Dictionary:
		for kind in ["stuck", "next"]:
			var code := OS.find_keycode_from_string(str(keys.get(kind, "")))
			if code != KEY_NONE:
				focus_keys[kind] = code

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
		advice_available = bool(data.get("homework_advice", false))
		speech_available = bool(data.get("homework_speech", false))
		if state != "connecting" and state != "running":
			return
		if not bool(data.get("homework", false)):
			state = "unavailable"
			status_text = "バックエンドで宿題の見守りが無効です（config の homework.enabled）"
		else:
			_send_start()
	elif t == "homework_speech":
		_play_speech(data)
	elif t == "homework_speech_error":
		speech_status = "声を出せませんでした: " + str(data.get("message", ""))
	elif t == "homework_locate_result":
		_on_locate_result(data)
	elif t == "homework_locate_error":
		_locate_failed("読み取れませんでした: " + str(data.get("message", "")), "うまく読み取れなかったよ。")
	elif t == "homework_advice_delta":
		advice_text += str(data.get("text", ""))
	elif t == "homework_advice_result":
		advice_state = "done"
		advice_status = "アドバイスを出しました"
	elif t == "homework_advice_error":
		advice_state = "error"
		advice_status = "アドバイスを作れませんでした: " + str(data.get("message", ""))
	elif t == "homework_status":
		if str(data.get("state", "")) == "advising":
			advice_state = "thinking"
			advice_status = "Claude / Codex が読み取っています…"
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
		_maybe_offer()
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
	stalled = bool(data.get("stalled", stalled))
	stalled_for_s = float(data.get("stalled_for_s", stalled_for_s))
	count = int(data.get("count", count))
	skipped = maxi(skipped, int(data.get("skipped", 0)))
	cost_usd = float(data.get("cost_usd", cost_usd))

func _on_disconnected() -> void:
	if running():
		_waiting = false
		state = "connecting"
		status_text = "バックエンドとの接続が切れました。再接続中…"
		state_changed.emit()

# ------------------------------------------------------------------ advice (#76)
## The robot link can take commands (a backend runs the robot, not the game's own mock).
func robot_link_ready() -> bool:
	return robot_ws != null and robot_ws.enabled and robot_ws.is_open() and RobotState.source == "websocket"

func advice_busy() -> bool:
	return advice_state in ["approaching", "thinking"]

## Record where the arm is now as the homework spot (jog it above the worksheet first).
func record_spot() -> void:
	if not robot_link_ready():
		advice_status = "位置の記録にはバックエンド（実機 / モック）への接続が要る"
		state_changed.emit()
		return
	robot_ws.send_command("homework_spot_set")

## Take the arm's camera down to the spot, capture, ask for advice, go back.
func approach_and_advise() -> void:
	if advice_busy() or looking:
		return
	if not robot_link_ready():
		advice_status = "近づくにはバックエンド（実機 / モック）への接続が要る"
		state_changed.emit()
		return
	_ensure_link()
	advice_state = "approaching"
	advice_text = ""
	advice_status = "アームを宿題の位置へ動かしています…（Space / STOP で中止）"
	_captured = false
	_approach_rid = robot_ws.send_command("homework_approach")
	state_changed.emit()

## Advice from the cameras as they are now (no motion).
func advise_now() -> void:
	if advice_busy():
		return
	_ensure_link()
	advice_text = ""
	_send_advice()

func _ensure_link() -> void:
	if not link.enabled:
		link.enabled = true  # the aux link may be off when no watch is running

## Overview (whole sheet) and focus (close-up) side by side; the overview alone without a focus feed.
func _capture_advice_image() -> Dictionary:
	var parts: Array[Image] = []
	for role in ["overview", "focus"]:
		if cameras != null and cameras.has_feed(role):
			var img := cameras.texture(role).get_image()
			if img != null and not img.is_empty():
				parts.append(img)
	if parts.is_empty():
		return {}
	var image := compose_side_by_side(parts, 720)
	return {"jpeg": StudyClient.encode_jpeg(image, 1600, max_image_bytes), "composite": parts.size() > 1}

## Images scaled to one height and put left to right.
static func compose_side_by_side(parts: Array[Image], height: int) -> Image:
	var scaled: Array[Image] = []
	var width := 0
	for p in parts:
		var img := p.duplicate() as Image
		img.convert(Image.FORMAT_RGB8)
		var w := maxi(1, int(round(float(img.get_width()) * height / float(img.get_height()))))
		img.resize(w, height, Image.INTERPOLATE_BILINEAR)
		scaled.append(img)
		width += w
	var out := Image.create(width, height, false, Image.FORMAT_RGB8)
	var x := 0
	for img in scaled:
		out.blit_rect(img, Rect2i(0, 0, img.get_width(), height), Vector2i(x, 0))
		x += img.get_width()
	return out

func _send_advice() -> void:
	var cap := _capture_advice_image()
	if cap.is_empty() or (cap.jpeg as PackedByteArray).is_empty():
		advice_state = "error"
		advice_status = "カメラの映像がないため、アドバイスを頼めませんでした"
		state_changed.emit()
		return
	_seq += 1
	var err := link.send_aux({"type": "homework_advice", "request_id": "hwa-%d" % _seq, "data": {
		"session_id": session_id, "composite": cap.composite,
		"image_jpeg_base64": Marshalls.raw_to_base64(cap.jpeg)}})
	if err == OK:
		advice_state = "thinking"
		advice_status = "Claude / Codex が読み取っています…"
	else:
		advice_state = "error"
		advice_status = "画像を送れませんでした（WebSocket error %d）" % err
	state_changed.emit()

func _on_robot_ack(rid: String, ok: bool, payload: Dictionary) -> void:
	if rid != _approach_rid:
		return
	_approach_rid = ""
	if not ok and advice_state == "approaching":
		advice_state = "error"
		advice_status = "近づけませんでした: " + str(payload.get("reason", ""))
		state_changed.emit()
	elif not ok and looking:
		looking = false
		calib_status = "動かせませんでした: " + str(payload.get("reason", ""))
		state_changed.emit()

func _on_robot_message(msg: Dictionary) -> void:
	var t := str(msg.get("type", ""))
	var data: Dictionary = msg.get("data", {}) if msg.get("data") is Dictionary else {}
	if t == "homework_approach":
		_on_approach(data)
	elif t == "robot_state" and data.get("homework_approach") is Dictionary:
		_on_approach(data.homework_approach)
	elif t == "ack" and str(data.get("command", "")) == "homework_spot_set":
		_on_approach(data)
		advice_status = "宿題の位置を記録しました"
		state_changed.emit()
	elif (t == "ack" or t == "nack") and str(data.get("command", "")).begins_with("camera_map_"):
		_on_camera_map_reply(str(data.command), t == "ack", data)
	elif t == "nack" and str(data.get("command", "")) == "homework_spot_set":
		advice_status = "位置を記録できませんでした: " + str(data.get("reason", ""))
		state_changed.emit()

# ------------------------------------------------------------------ camera calibration (#78)
## Size and flips of the overview image as shown (what the clicks and the frames refer to).
func camera_signature() -> Dictionary:
	var size := cameras.feed_size(camera_role) if cameras != null else Vector2.ZERO
	var c = GameConfig.get_value("camera", camera_role, {})
	var flips: Dictionary = c if c is Dictionary else {}
	return {"width": int(size.x), "height": int(size.y),
		"flip_h": bool(flips.get("flip_h", false)), "flip_v": bool(flips.get("flip_v", false))}

func request_camera_map() -> void:
	if robot_link_ready():
		robot_ws.send_command("camera_map_status")

## Pair the clicked overview point (u, v: 0..1) with where the arm is now.
func calib_add(uv: Vector2) -> void:
	if not robot_link_ready():
		calib_status = "校正にはバックエンド（実機 / モック）への接続が要る"
		state_changed.emit()
		return
	calib_status = "記録中…"
	robot_ws.send_command("camera_map_add", {"u": uv.x, "v": uv.y, "camera": camera_signature()})
	state_changed.emit()

func calib_undo() -> void:
	if robot_link_ready():
		robot_ws.send_command("camera_map_undo")

func calib_clear() -> void:
	if robot_link_ready():
		robot_ws.send_command("camera_map_clear")

## Take the arm's camera above the clicked overview point (at the recorded spot's height).
func look_at(uv: Vector2) -> void:
	if advice_busy() or looking:
		return
	if not robot_link_ready():
		calib_status = "動かすにはバックエンド（実機 / モック）への接続が要る"
		state_changed.emit()
		return
	looking = true
	_look_moving = false
	calib_status = "クリックした場所へアームのカメラを動かしています…（Space / STOP で中止）"
	_approach_rid = robot_ws.send_command("homework_approach", {"u": uv.x, "v": uv.y, "camera": camera_signature()})
	state_changed.emit()

## Done looking: the arm goes back up (and back).
func look_done() -> void:
	if robot_link_ready() and bool(approach.get("active", false)):
		robot_ws.send_command("homework_approach_release")

func _hold_timeout_s() -> float:
	var a = GameConfig.get_value("homework", "approach", {})
	return float(a.get("hold_timeout_s", 15.0)) if a is Dictionary else 15.0

func calibration_usable() -> bool:
	return bool(camera_map.get("usable", false))

## Where the arm's camera looks, as an overview image point (u, v); null without a calibration.
func arm_view_uv():
	var h = camera_map.get("h_inv")
	if not (h is Array) or h.size() != 3:
		return null
	return map_point(h, RobotState.x_mm, RobotState.y_mm)

## 3x3 homography (rows) applied to (x, y); null at infinity.
static func map_point(h: Array, x: float, y: float):
	var w := float(h[2][0]) * x + float(h[2][1]) * y + float(h[2][2])
	if absf(w) < 1e-12:
		return null
	return Vector2((float(h[0][0]) * x + float(h[0][1]) * y + float(h[0][2])) / w,
		(float(h[1][0]) * x + float(h[1][1]) * y + float(h[1][2])) / w)

## "3 点 / 誤差 平均 0.8 mm・最大 1.4 mm" or why it is not usable.
func calib_summary() -> String:
	var pts: Array = camera_map.get("points", []) if camera_map.get("points") is Array else []
	if camera_map.is_empty():
		return "校正: 状態をまだ受け取っていない"
	if bool(camera_map.get("usable", false)):
		return "校正: %d 点・誤差 平均 %.1f mm／最大 %.1f mm（使える）" % [pts.size(), float(camera_map.get("rms_mm", 0.0)), float(camera_map.get("max_mm", 0.0))]
	return "校正: %d 点・%s" % [pts.size(), str(camera_map.get("problem", ""))]

func _on_camera_map_reply(cmd: String, ok: bool, data: Dictionary) -> void:
	if ok:
		camera_map = data.duplicate()
		camera_map.erase("command")
		match cmd:
			"camera_map_add":
				calib_status = "点を記録しました（アームの XY と組にした）"
			"camera_map_undo":
				calib_status = "最後の点を取り消しました"
			"camera_map_clear":
				calib_status = "校正を消しました"
	else:
		calib_status = "校正できませんでした: " + str(data.get("reason", ""))
	state_changed.emit()

func _on_approach(status: Dictionary) -> void:
	var before := str(approach.get("phase", ""))
	approach = status
	var phase := str(status.get("phase", ""))
	if advice_state == "approaching":
		if phase == "HOLD" and not _captured:
			_captured = true
			_send_advice()  # frames now, while the arm is down
			if robot_link_ready():
				robot_ws.send_command("homework_approach_release")  # back up while the advice is written
		elif phase == "FAULT":
			advice_state = "error"
			advice_status = "アームを止めました: %s（アラーム解除と原点復帰が必要なことがある）" % str(status.get("error", ""))
	elif looking:
		# robot_state may still carry the previous run's IDLE / FAULT: wait for this run to move
		if phase not in ["", "IDLE", "FAULT"]:
			_look_moving = true
		if phase == "HOLD" and before != "HOLD":
			calib_status = "アームのカメラがクリックした場所を見ています。「戻る」で上へ戻る（%d 秒たつと自動で戻る）" % int(_hold_timeout_s())
		elif _look_moving and phase == "FAULT":
			looking = false
			_look_moving = false
			calib_status = "アームを止めました: %s（アラーム解除と原点復帰が必要なことがある）" % str(status.get("error", ""))
		elif _look_moving and phase == "IDLE" and not bool(status.get("active", false)):
			looking = false
			_look_moving = false
			calib_status = "戻りました"
	if phase != before:
		state_changed.emit()

# ------------------------------------------------------------------ helper (#79)
## The stall -> "手伝おうか？" once per stall (again after offer_repeat_s while it lasts).
func _maybe_offer() -> void:
	if not stalled:
		_offered_this_stall = false
		return
	if not helper_offer or not running() or advice_busy() or looking or locate_state == "locating":
		return
	var now := Time.get_ticks_msec()
	if _offered_this_stall and now - _last_offer_ms < int(offer_repeat_s * 1000.0):
		return
	offer_help()

func offer_help() -> void:
	var now := Time.get_ticks_msec()
	_offered_this_stall = true
	_last_offer_ms = now
	_offer_until_ms = now + int(offer_window_s * 1000.0)
	locate_status = "%s（%s かいいねで止まっている問題を見に行く、%s で次の問題）" % [
		offer_text, key_name("stuck"), key_name("next")]
	say(offer_text)
	state_changed.emit()

func offer_pending(now_ms: float) -> bool:
	return now_ms < _offer_until_ms

func key_name(kind: String) -> String:
	return OS.get_keycode_string(int(focus_keys.get(kind, KEY_NONE)))

## The game's unused keys come here: true when it was one of the helper's.
func handle_key(keycode: int) -> bool:
	for kind in ["stuck", "next"]:
		if keycode == int(focus_keys[kind]):
			focus_problem(kind)
			return true
	return false

## A thumbs-up held thumb_hold_ms answers a pending offer. A thumb already up when the
## offer came (or left up after answering) does nothing until it is put down.
func thumb_tick(thumb: bool, now_ms: float) -> void:
	if not thumb:
		_thumb_since_ms = -1.0
		_thumb_spent = false
		return
	if _thumb_spent:
		return
	if not offer_pending(now_ms):
		_thumb_spent = true
		return
	if _thumb_since_ms < 0.0:
		_thumb_since_ms = now_ms
	if now_ms - _thumb_since_ms >= thumb_hold_ms:
		_thumb_spent = true
		focus_problem("stuck")

## Why the arm cannot be sent to a problem now ("" when it can).
func focus_blocker() -> String:
	if not advice_available:
		return "問題を読み取るアシスタントがない（study.provider）"
	if not robot_link_ready():
		return "動かすにはバックエンド（実機 / モック）への接続が要る"
	if not calibration_usable():
		return "カメラの校正がまだ使えない（宿題タブの「校正点を記録」）"
	if cameras == null or not cameras.has_feed(camera_role):
		return "%s カメラに映像がない" % camera_role
	return ""

## Find the problem ("stuck" / "next") in the overview image now and look at it.
func focus_problem(kind: String) -> void:
	_offer_until_ms = 0
	if locate_state == "locating" or advice_busy() or looking:
		locate_status = "いまは別の動きの途中です"
		state_changed.emit()
		return
	var why := focus_blocker()
	if why != "":
		_locate_failed("見に行けません: " + why, "")
		return
	var jpeg := StudyClient.encode_jpeg(cameras.texture(camera_role).get_image(), max_image_edge, max_image_bytes)
	if jpeg.is_empty():
		_locate_failed("画像を上限サイズ内に圧縮できませんでした", "")
		return
	_ensure_link()
	_seq += 1
	locate_kind = kind
	last_locate = {}
	var err := link.send_aux({"type": "homework_locate", "request_id": "hwl-%d" % _seq, "data": {
		"session_id": session_id, "kind": kind, "image_jpeg_base64": Marshalls.raw_to_base64(jpeg)}})
	if err != OK:
		_locate_failed("画像を送れませんでした（WebSocket error %d）" % err, "")
		return
	locate_state = "locating"
	locate_status = ("止まっている問題" if kind == "stuck" else "次に解く問題") + "を読み取っています…"
	say("わかった、見てみるね。" if kind == "stuck" else "次の問題を見てみるね。")
	state_changed.emit()

func _on_locate_result(data: Dictionary) -> void:
	last_locate = data
	var problem := str(data.get("problem", ""))
	if not bool(data.get("usable", false)):
		_locate_failed("場所がはっきりしないので動かしません（%s）: %s" % [problem, str(data.get("reason", ""))],
			"どの問題か、はっきりわからなかったよ。", "unsure")
		return
	locate_state = "done"
	locate_status = "「%s」を見に行きます%s" % [problem, "" if bool(data.get("verified", false)) else "（Jev では未確認）"]
	say(("%sを見に行くね。" % problem) if problem != "" else "見に行くね。")
	look_at(Vector2(float(data.get("u", 0.5)), float(data.get("v", 0.5))))
	state_changed.emit()

func _locate_failed(status: String, spoken: String, new_state := "error") -> void:
	locate_state = new_state
	locate_status = status
	if spoken != "":
		say(spoken)
	state_changed.emit()

## Ask the backend to voice text (nothing when the voice is off or unavailable).
func say(text: String) -> void:
	if not voice_on or text.strip_edges() == "":
		return
	if not speech_available:
		speech_status = "声は使えない（バックエンドの homework.speech）: " + text
		return
	_ensure_link()
	_seq += 1
	if link.send_aux({"type": "homework_say", "request_id": "hws-%d" % _seq, "data": {"text": text}}) != OK:
		speech_status = "声を頼めませんでした: " + text

func _play_speech(data: Dictionary) -> void:
	var wav := Marshalls.base64_to_raw(str(data.get("wav_base64", "")))
	var stream := wav_stream(wav)
	if stream == null:
		speech_status = "音声を読み込めませんでした"
		return
	speech_credit = str(data.get("credit", ""))
	speech_status = "「%s」（%s）" % [str(data.get("text", "")), str(data.get("engine", ""))]
	if voice_on and player != null:
		player.stream = stream
		player.play()

## A WAV file's bytes as a stream (null when they are not a WAV).
static func wav_stream(wav: PackedByteArray) -> AudioStreamWAV:
	if wav.size() < 44 or wav.slice(0, 4).get_string_from_ascii() != "RIFF" or wav.slice(8, 12).get_string_from_ascii() != "WAVE":
		return null
	return AudioStreamWAV.load_from_buffer(wav)

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

class_name UfoWebSocketClient
extends Node
## WebSocket/JSON link to the Python backend (backend/). Feeds RobotState and
## forwards vision events to GameState. Commands carry a request_id and are
## ACK/NACK'd; unanswered ones time out. Motion commands are never resent
## automatically (the backend de-duplicates by request_id anyway).

signal connected
signal disconnected
signal message_received(msg: Dictionary)
signal ack(request_id: String, ok: bool, payload: Dictionary)
signal log_line(text: String)
## A hand joystick event and when it arrived (Time.get_ticks_msec(), this side's
## monotonic clock: freshness is judged by it, never by the sender's timestamp).
signal hand_control(data: Dictionary, recv_ms: float)

## Only listen (vision events): never touch RobotState. Used to get the hand
## gesture from the backend while the game drives its own MockRobot.
var listen_only := false
## What the backend drives ("mock", "real", ...), from its hello.
var server_robot := ""

var url: String = "ws://127.0.0.1:8765"
var auto_reconnect: bool = true
var reconnect_delay: float = 1.0
var command_timeout_ms: int = 3000
var state_timeout_ms: int = 1500
var enabled: bool = false:
	set(v):
		enabled = v
		if v:
			_connect()
		else:
			close()

var _peer := WebSocketPeer.new()
var _was_open := false
var _reconnect_timer := 0.0
var _pending: Dictionary = {} # request_id -> {sent_ms, type}
var _last_state_ms: int = 0
var _seq: int = 0
var rtt_ms: int = 0

func _ready() -> void:
	url = str(GameConfig.get_value("network", "websocket_url", url))
	command_timeout_ms = int(GameConfig.get_value("network", "command_timeout_ms", command_timeout_ms))
	state_timeout_ms = int(GameConfig.get_value("network", "state_timeout_ms", state_timeout_ms))

func _connect() -> void:
	_peer = WebSocketPeer.new()
	var err := _peer.connect_to_url(url)
	if err != OK:
		log_line.emit("connect error %d" % err)
		_reconnect_timer = reconnect_delay

func close() -> void:
	if _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_peer.close()
	if _was_open:
		_was_open = false
		_on_closed()

var _last_jog_nack := ""

func is_open() -> bool:
	return _peer.get_ready_state() == WebSocketPeer.STATE_OPEN

func _process(dt: float) -> void:
	if not enabled:
		return
	_peer.poll()
	var st := _peer.get_ready_state()
	match st:
		WebSocketPeer.STATE_OPEN:
			if not _was_open:
				_was_open = true
				_last_state_ms = Time.get_ticks_msec()
				log_line.emit("connected " + url)
				connected.emit()
				send({"type": "hello", "data": {"client": "godot", "version": 1}})
			while _peer.get_available_packet_count() > 0:
				var txt := _peer.get_packet().get_string_from_utf8()
				var parsed = JSON.parse_string(txt)
				if parsed is Dictionary:
					_handle(parsed)
			_check_timeouts()
		WebSocketPeer.STATE_CLOSED:
			if _was_open:
				_was_open = false
				_on_closed()
			_reconnect_timer -= dt
			if auto_reconnect and _reconnect_timer <= 0.0:
				_reconnect_timer = reconnect_delay
				_connect()
		_:
			pass

func _on_closed() -> void:
	log_line.emit("disconnected (code %d)" % _peer.get_close_code())
	server_robot = ""
	if RobotState.source == "websocket" and not listen_only:
		RobotState.connected = false
		RobotState.machine_state = "UNKNOWN"
	for rid in _pending.keys():
		ack.emit(rid, false, {"reason": "socket_closed"})
	_pending.clear()
	disconnected.emit()

func _check_timeouts() -> void:
	var now := Time.get_ticks_msec()
	for rid in _pending.keys():
		if now - _pending[rid].sent_ms > command_timeout_ms:
			_pending.erase(rid)
			log_line.emit("timeout " + rid)
			ack.emit(rid, false, {"reason": "timeout"})
	# Backend alive but robot samples stale -> treat as link problem.
	if not listen_only and RobotState.source == "websocket" and RobotState.connected and now - _last_state_ms > state_timeout_ms:
		RobotState.report_error("robot_state timeout")
		RobotState.connected = false
		RobotState.machine_state = "UNKNOWN"

func _handle(msg: Dictionary) -> void:
	message_received.emit(msg)
	var t := str(msg.get("type", ""))
	var data: Dictionary = msg.get("data", {}) if msg.get("data") is Dictionary else {}
	if listen_only and t != "vision_event":
		if t == "hello":
			server_robot = str(data.get("robot", ""))
		return
	match t:
		"hello":
			server_robot = str(data.get("robot", ""))
		"robot_state":
			_last_state_ms = Time.get_ticks_msec()
			RobotState.source = "websocket"
			RobotState.homed = bool(data.get("homed", false))
			RobotState.motors_enabled = bool(data.get("motors_enabled", false))
			var was := RobotState.connected
			RobotState.connected = bool(data.get("connected", false))
			RobotState.robot_error = str(data.get("error", ""))
			RobotState.z_reference_set = bool(data.get("z_reference_set", false))
			RobotState.arm_deg = float(data.arm_deg) if data.get("arm_deg") != null else NAN
			RobotState.arm_reference_set = bool(data.get("arm_reference_set", false))
			if data.has("error") and str(data.error) != "":
				RobotState.last_error = str(data.error)
			RobotState.push_pose(float(data.get("x", 0.0)), float(data.get("y", 0.0)), float(data.get("z", 0.0)),
				str(data.get("state", "UNKNOWN")), int(msg.get("timestamp", 0)), bool(data.get("measured", true)))
			if not was and RobotState.connected:
				log_line.emit("robot connected")
		"ack", "nack":
			var rid := str(msg.get("request_id", ""))
			if _pending.has(rid):
				rtt_ms = Time.get_ticks_msec() - _pending[rid].sent_ms
				_pending.erase(rid)
			ack.emit(rid, t == "ack", data)
			# jog is refreshed ~20 Hz while a key is held: log a refusal once per reason
			if str(data.get("command", "")) == "jog":
				var reason := str(data.get("reason", "")) if t == "nack" else ""
				if reason != "" and reason != _last_jog_nack:
					log_line.emit("%s %s %s" % [t, rid, JSON.stringify(data)])
				_last_jog_nack = reason
			else:
				log_line.emit("%s %s %s" % [t, rid, JSON.stringify(data)])
		"error":
			RobotState.report_error(str(data.get("message", "error")))
			log_line.emit("ERROR " + str(data.get("message", "")))
		"vision_event":
			if str(data.get("event", "")) == "hand_control":
				hand_control.emit(data, float(Time.get_ticks_msec()))
			else:
				GameState.post_event(str(data.get("event", "vision")), data)
		"log":
			log_line.emit(str(data.get("line", "")))
		_:
			pass

func send(msg: Dictionary) -> void:
	if not is_open():
		return
	if not msg.has("timestamp"):
		msg["timestamp"] = Time.get_ticks_msec()
	_peer.send_text(JSON.stringify(msg))

## A home / move / grab command is still waiting for its answer.
func has_pending_motion() -> bool:
	for rid in _pending.keys():
		if str(_pending[rid].type) in ["home", "move_xy", "move_z", "grab", "arm_step"]:
			return true
	return false

## Send a command and track it. Returns the request id.
func send_command(name: String, params: Dictionary = {}) -> String:
	_seq += 1
	var rid := "g%d-%d" % [Time.get_ticks_msec(), _seq]
	_pending[rid] = {"sent_ms": Time.get_ticks_msec(), "type": name}
	send({"type": "command", "request_id": rid, "data": {"name": name, "params": params}})
	return rid

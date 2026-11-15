class_name BackendDialHub
extends GameModeDevices
## The peripherals through the backend (#138): devicehub_command / devicehub_status /
## devicehub_stop_all over the game's WebSocket, answered by the backend's DeviceHubService
## (UFO-DeviceHub's own DeviceGateway: sessions, ACKs, retries, de-duplicated events). The
## hub behind it is the real one or the backend's mock (devicehub.port "mock"), where
## devicehub_mock_ball stands for a capsule landing in a Dial.

var ws: UfoWebSocketClient
var _session := 0
var _hub_connected := false
var _mock := false
var _problem := ""
var _meta_rid := ""
var _meta_left := 0.0
var _pending: Dictionary = {}  # rid -> "command" / "status" / "ball"

func setup(link: UfoWebSocketClient) -> void:
	ws = link
	ws.ack.connect(_on_ack)
	ws.message_received.connect(_on_message)
	ws.disconnected.connect(_on_disconnected)

func kind() -> String:
	return "backend"

func available() -> bool:
	return ws != null and ws.enabled and ws.is_open() and _hub_connected

func session_id() -> int:
	return _session if available() else 0

## Why there is no hub: no backend, no hub in the backend, or what the backend says about
## its hub (another UFO system's hub, no port, a port that is not a hub...).
func problem() -> String:
	if available():
		return ""
	if ws == null or not ws.enabled or not ws.is_open():
		return "バックエンドにつながっていない（./start.sh で起動する）"
	return _problem if _problem != "" else "周辺機器のハブに問い合わせ中…"

func can_mock_ball() -> bool:
	return available() and _mock

func command(device: int, name: String, params: Dictionary = {}) -> String:
	return _send("command", "devicehub_command", {"device": device, "name": name, "params": params})

func status(device: int) -> String:
	return _send("status", "devicehub_status", {"device": device})

func stop_all() -> void:
	if ws != null and ws.enabled and ws.is_open():
		ws.send_command("devicehub_stop_all")

func mock_ball(device: int) -> bool:
	if not can_mock_ball():
		return false
	_send("ball", "devicehub_mock_ball", {"device": device})
	return true

## The hub's session and whether it is the backend's mock: asked until the hub answers,
## then now and again (a hub plugged in later).
func tick(dt: float) -> void:
	_meta_left -= dt
	if _meta_left <= 0.0 and _meta_rid == "" and ws != null and ws.enabled and ws.is_open():
		_meta_left = 1.0 if not _hub_connected else 5.0
		_meta_rid = ws.send_command("devicehub_meta")

func _send(what: String, name: String, params: Dictionary) -> String:
	if ws == null or not ws.enabled or not ws.is_open():
		# answered on the next frame, like every other refusal
		var rid := "offline-%d" % Time.get_ticks_usec()
		command_done.emit.call_deferred(rid, false, "NOT_CONNECTED", {})
		return rid
	var id := ws.send_command(name, params)
	_pending[id] = what
	return id

func _on_ack(rid: String, ok: bool, data: Dictionary) -> void:
	if rid == _meta_rid:
		_meta_rid = ""
		var was := _hub_connected
		_hub_connected = ok and bool(data.get("connected", false))
		_mock = ok and str(data.get("port", "")) == "mock"
		# a NACK = the backend has no hub at all (its reason says how to turn it on)
		_problem = str(data.get("problem", "")) if ok else "周辺機器のハブを使っていない: " + str(data.get("reason", ""))
		if ok and not _hub_connected and _problem == "":
			_problem = "周辺機器のハブの応答を待っている"
		var s := int(data.get("session_id", 0)) if ok else 0
		if _hub_connected and (not was or s != _session):
			_session = s
			device_event.emit({"name": "GATEWAY_CONNECTED", "source": null, "data": {"session_id": s},
				"event_id": null, "session_id": null})
		elif was and not _hub_connected:
			device_event.emit({"name": "GATEWAY_DISCONNECTED", "source": null, "data": {"reason": str(data.get("reason", "hub"))},
				"event_id": null, "session_id": null})
		return
	if not _pending.has(rid):
		return
	var what: String = _pending[rid]
	_pending.erase(rid)
	if what == "ball":
		return
	if not ok:  # the backend refused or never answered (not the device's own answer)
		var why := str(data.get("reason", "NACK"))
		command_done.emit(rid, false, "TIMEOUT" if why == "timeout" else ("NOT_CONNECTED" if why == "socket_closed" else why), {})
		return
	if what == "status":
		var st = data.get("status", {})
		command_done.emit(rid, st is Dictionary, "ACCEPTED" if st is Dictionary else "NO_STATUS", {"status": st if st is Dictionary else {}})
		return
	var r = data.get("result", {})
	if not r is Dictionary:
		command_done.emit(rid, false, "NO_RESULT", {})
		return
	command_done.emit(rid, bool(r.get("ok", false)), str(r.get("result", "?")), {"command_id": int(r.get("command_id", 0))})

func _on_message(msg: Dictionary) -> void:
	if str(msg.get("type", "")) != "devicehub_event" or not msg.get("data") is Dictionary:
		return
	var d: Dictionary = msg.data
	var name := str(d.get("name", ""))
	if name == "GATEWAY_CONNECTED":  # the session comes with the next meta (asked at once)
		_meta_left = 0.0
		return
	if name == "GATEWAY_DISCONNECTED":
		_hub_connected = false
	var src = d.get("source")
	var eid = d.get("event_id")
	var sid = d.get("session_id")
	device_event.emit({"name": name, "source": int(src) if src != null else null,
		"data": d.get("data") if d.get("data") is Dictionary else {},
		"event_id": int(eid) if eid != null else null, "session_id": int(sid) if sid != null else null,
		"received_at": d.get("received_at")})

func _on_disconnected() -> void:
	_pending.clear()
	_meta_rid = ""
	if _hub_connected:
		_hub_connected = false
		device_event.emit({"name": "GATEWAY_DISCONNECTED", "source": null, "data": {"reason": "websocket"},
			"event_id": null, "session_id": null})

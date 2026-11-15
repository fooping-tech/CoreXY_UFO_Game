class_name FocusStream
extends Node
## #118: the arm-tip camera, stabilized by the backend (optical flow), received on its own
## WebSocket port (camera.focus.stabilize.port; never the robot's connection). CameraHub shows
## it as the "focus" camera while frames arrive and goes back to its own feed when they stop.
##
## Packets (backend vision_service/focus_stream.py): binary b"FCS1" + uint32 LE header length
## + header JSON + JPEG; text {"type": "focus_status", "data": {state, message?}}.
## JPEGs are decoded on a worker thread, the newest only (a late frame is dropped).
##
## Presentation only: never a robot command.

## A frame older than this: not live (CameraHub falls back to the direct feed).
const STALE_MS := 1000
const RETRY_S := 2.0
const INBOUND_BUFFER := 4 * 1024 * 1024

var url := ""
var stabilize := true
## off / connecting / opening / streaming / error (the backend's state once connected)
var state := "off"
var message := ""
## The last frame's header: seq, w, h, stabilized, dx, dy, rot_deg, points, tracking, fps.
var header := {}
var texture: ImageTexture = null
var frames := 0

var _peer: WebSocketPeer = null
var _retry := 0.0
var _last_frame_ms := -100000
var _pending := {}     # the newest packet waiting to be decoded: {header, jpeg}
var _task := -1
var _decoded: Image = null
var _decoded_head := {}

## {header, jpeg} of a frame packet, {} when it is not one.
static func parse(data: PackedByteArray) -> Dictionary:
	if data.size() < 8 or data.slice(0, 4).get_string_from_ascii() != "FCS1":
		return {}
	var n := data.decode_u32(4)
	if 8 + n > data.size():
		return {}
	var head = JSON.parse_string(data.slice(8, 8 + n).get_string_from_utf8())
	if not head is Dictionary:
		return {}
	return {"header": head, "jpeg": data.slice(8 + n)}

## ws://host:port of the stream next to the game's backend URL.
static func url_for(backend_url: String, port: int) -> String:
	var rest := backend_url.trim_prefix("ws://").trim_prefix("wss://")
	var host := rest.get_slice("/", 0)
	if host.begins_with("["):  # [::1]:8765
		host = host.get_slice("]", 0) + "]"
	elif host.contains(":"):
		host = host.get_slice(":", 0)
	return "ws://%s:%d" % [host if host != "" else "127.0.0.1", port]

func live() -> bool:
	return texture != null and Time.get_ticks_msec() - _last_frame_ms < STALE_MS

func set_stabilize(on: bool) -> void:
	stabilize = on
	if _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_peer.send_text(JSON.stringify({"stabilize": on}))

## Show `img` as the newest frame (from the decoder, or a test).
func apply_frame(head: Dictionary, img: Image) -> void:
	if img == null or img.is_empty():
		return
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	if texture == null or Vector2i(texture.get_size()) != img.get_size():
		texture = ImageTexture.create_from_image(img)
	else:
		texture.update(img)
	header = head
	frames += 1
	_last_frame_ms = Time.get_ticks_msec()

func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if _peer != null:
		_peer.close()

func _process(dt: float) -> void:
	if url == "":
		return
	if _peer == null:
		_retry -= dt
		if _retry > 0.0:
			return
		_retry = RETRY_S
		_peer = WebSocketPeer.new()
		_peer.inbound_buffer_size = INBOUND_BUFFER
		if _peer.connect_to_url(url) != OK:
			_peer = null
			return
		state = "connecting"
	_peer.poll()
	match _peer.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if state == "connecting":
				state = "opening"
				if not stabilize:
					set_stabilize(false)
			while _peer.get_available_packet_count() > 0:
				var data := _peer.get_packet()
				if _peer.was_string_packet():
					_on_status(data.get_string_from_utf8())
				else:
					var p := parse(data)
					if not p.is_empty():
						_pending = p  # an older one not decoded yet is dropped
		WebSocketPeer.STATE_CLOSED:
			_peer = null
			state = "off"
			message = ""
	_decode_step()

func _on_status(text: String) -> void:
	var m = JSON.parse_string(text)
	if m is Dictionary and m.get("type") == "focus_status" and m.get("data") is Dictionary:
		state = str(m.data.get("state", state))
		message = str(m.data.get("message", ""))

func _decode_step() -> void:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		if _decoded != null:
			apply_frame(_decoded_head, _decoded)
		_decoded = null
	if _task < 0 and not _pending.is_empty():
		var p := _pending
		_pending = {}
		_task = WorkerThreadPool.add_task(_decode.bind(p.header, p.jpeg))

func _decode(head: Dictionary, jpeg: PackedByteArray) -> void:
	var img := Image.new()
	if img.load_jpg_from_buffer(jpeg) == OK:
		img.convert(Image.FORMAT_RGB8)
		_decoded_head = head
		_decoded = img
	else:
		_decoded = null

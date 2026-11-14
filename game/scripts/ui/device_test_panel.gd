class_name DeviceTestPanel
extends VBoxContainer
## The settings screen's テスト tab (#108): the peripherals (UFO-DeviceHub: the ESP-NOW hub,
## the Illumination ATOM, M5Dial x2) tested like UFO-DeviceHub's browser console
## (pc.web_console). Every button sends devicehub_command {device, name, params} to the
## backend, which goes through the hub's own DeviceGateway (sessions, ACKs, retries).
## Never the crane: no RobotState, no robot command. STOP ALL (and Space on this tab) stops
## every device (mist and relay off, effects stopped, a release aborted).

const YELLOW := Color("ffe03c")
const CYAN := Color("7ae0ff")
const MUTED := Color("8fa3c4")
const BAD := Color("ff8a8a")
const GOOD := Color("9ff0a8")
const ILL := 0x10
const DIALS := [0x20, 0x21]
const NAMES := {0x10: "Illumination", 0x20: "M5Dial 1", 0x21: "M5Dial 2"}
## As UFO-DeviceHub's protocol.py (the backend's meta replaces them when it answers)
const LIGHT_MODES := ["OFF", "IDLE", "STUDY", "GAME_READY", "GAME_PLAY", "RESULT", "ERROR", "CUSTOM", "AURORA",
	"STORM", "CAMPFIRE", "MIST_GLOW", "MAGIC_PUFF", "NIGHT"]
const EFFECTS := ["GAME_START", "ARM_MOVE", "ARM_DESCEND", "CATCH", "BALL_RECEIVED", "BALL_RELEASED", "SCORE",
	"GAME_CLEAR", "GAME_OVER"]
const POLL_S := 1.0
const LOG_MAX := 14

var main: Node
var meta: Dictionary = {}
var devices: Array = []
var status: Dictionary = {}  # device id -> the last STATUS
var log_lines: Array[String] = []
var result_text := ""
var result_ok := true
var _hub: Label
var _dev: Label
var _ill_state: Label
var _ill_kv: Label
var _dial_state: Dictionary = {}  # id -> Label
var _log: Label
var _lm_mode: OptionButton
var _lm_bright: HSlider
var _lm_speed: HSlider
var _lm_trans: SpinBox
var _lm_color: ColorPickerButton
var _mist_dur: SpinBox
var _fx_dur: SpinBox
var _fx_int: HSlider
var _relay_ms: SpinBox
var _buttons: Array[Button] = []
var _pending: Dictionary = {}  # backend request kind -> request id (one at a time)
var _poll_left := 0.0

func setup(m: Node) -> void:
	main = m
	add_theme_constant_override("separation", 6)
	_note("周辺機器（UFO-DeviceHub）の動作テスト。ブラウザの試験画面（pc.web_console）と同じ操作を、ゲームの"
		+ "バックエンド経由で行う（設定の「周辺機器のハブを使う」をオンにして ./start.sh。試験画面とは同時に使えない）。"
		+ "ミスト・リレー・サーボが実際に動く。止めるときは STOP ALL か Space。クレーンには何も送らない。")
	var top := _row()
	_hub = StudyHud.label("", 18, YELLOW, 3)
	_hub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hub.custom_minimum_size = Vector2(600, 0)
	top.add_child(_hub)
	var stop := _button(top, "STOP ALL（Space）", stop_all)
	stop.add_theme_color_override("font_color", BAD)

	_head("機器")
	_dev = _value()
	var row := _row()
	_button(row, "診断（GET_DIAG）", func(): _request("diag", "devicehub_diag", {}))

	_head("Illumination")
	_ill_state = _value()
	_sub("照明モード")
	row = _row()
	_lm_mode = OptionButton.new()
	_lm_mode.focus_mode = Control.FOCUS_NONE
	for mode in LIGHT_MODES:
		_lm_mode.add_item(mode)
	_lm_mode.select(LIGHT_MODES.find("AURORA"))
	row.add_child(_lm_mode)
	_lm_bright = _slider(row, "明るさ", 0, 255, 160)
	_lm_speed = _slider(row, "速さ", 0, 255, 128)
	row = _row()
	_lm_trans = _spin(row, "フェード ms", 0, 65535, 500)
	_lm_color = ColorPickerButton.new()
	_lm_color.color = Color("ff8800")
	_lm_color.edit_alpha = false
	_lm_color.custom_minimum_size = Vector2(60, 30)
	_lm_color.focus_mode = Control.FOCUS_NONE
	row.add_child(StudyHud.label("色", 16, MUTED, 2))
	row.add_child(_lm_color)
	_button(row, "適用", apply_light)
	_sub("ミスト")
	row = _row()
	_mist_dur = _spin(row, "時間 s（0 = 最大 10 分）", 0, 65535, 60)
	for p in [["CONTINUOUS", "連続"], ["BREATH", "BREATH 8s/6s"], ["PUFF", "PUFF 3s/9s"], ["OFF", "OFF"]]:
		var pattern: String = p[0]
		_button(row, p[1], func(): mist(pattern))
	_sub("演出（TRIGGER_EFFECT）")
	row = _row()
	_fx_dur = _spin(row, "時間 ms（0 = 既定）", 0, 10000, 0)
	_fx_int = _slider(row, "強さ", 0, 255, 255)
	var grid := GridContainer.new()
	grid.columns = 5
	add_child(grid)
	for e in EFFECTS:
		var effect: String = e
		_button(grid, effect, func(): trigger(effect))
	_sub("蒸気リレー")
	row = _row()
	_relay_ms = _spin(row, "ms", 1, 65535, 1000)
	_button(row, "RELAY_PULSE", func(): send(ILL, "RELAY_PULSE", {"relay_id": 0, "duration_ms": int(_relay_ms.value)}))
	_button(row, "RELAY_OFF", func(): send(ILL, "RELAY_OFF", {}))
	_ill_kv = _value()

	for id in DIALS:
		var dev: int = id
		_head(NAMES[dev])
		_dial_state[dev] = _value()
		row = _row()
		_button(row, "GAME モード", func(): send(dev, "SET_MODE", {"mode": "GAME"}))
		_button(row, "STANDBY", func(): send(dev, "SET_MODE", {"mode": "STANDBY"}))
		_button(row, "受取待ち（ARM）", func(): send(dev, "ARM_RECEIVER", {}))
		_button(row, "解除（DISARM）", func(): send(dev, "DISARM_RECEIVER", {}))
		_button(row, "排出（RELEASE）", func(): send(dev, "RELEASE_BALL", {}))

	_head("イベント")
	_log = _value()
	_log.add_theme_color_override("font_color", MUTED)
	if main.get("ws") != null:
		main.ws.ack.connect(_on_ack)
		main.ws.message_received.connect(_on_message)
		main.ws.disconnected.connect(_forget)

## The backend is gone: nothing it said about the hub holds any more.
func _forget() -> void:
	meta = {}
	devices = []
	status = {}
	_pending.clear()

# ------------------------------------------------------------------ building
func _head(text: String) -> void:
	add_child(StudyHud.label(text, 24, CYAN, 6))

func _sub(text: String) -> void:
	add_child(StudyHud.label(text, 18, Color.WHITE, 3))

func _note(text: String) -> void:
	var l := StudyHud.label(text, 16, MUTED, 2)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(860, 0)
	add_child(l)

func _value() -> Label:
	var l := StudyHud.label("", 17, Color.WHITE, 3)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(860, 0)
	add_child(l)
	return l

func _row() -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 10)
	add_child(r)
	return r

func _button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 17)
	b.focus_mode = Control.FOCUS_NONE  # Space stays the stop key
	b.pressed.connect(cb)
	parent.add_child(b)
	_buttons.append(b)
	return b

func _slider(parent: Control, label: String, lo: float, hi: float, v: float) -> HSlider:
	parent.add_child(StudyHud.label(label, 16, MUTED, 2))
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 1
	s.value = v
	s.custom_minimum_size = Vector2(140, 0)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE
	parent.add_child(s)
	return s

func _spin(parent: Control, label: String, lo: float, hi: float, v: float) -> SpinBox:
	parent.add_child(StudyHud.label(label, 16, MUTED, 2))
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 1
	s.value = v
	parent.add_child(s)
	return s

# ------------------------------------------------------------------ actions
func backend_ready() -> bool:
	return main != null and main.ws.enabled and main.ws.is_open()

func send(device: int, name: String, params: Dictionary) -> String:
	if not backend_ready():
		_result(false, "バックエンドにつながっていない（./start.sh で起動する）")
		return ""
	_add_log("→ %s %s %s" % [NAMES.get(device, str(device)), name, JSON.stringify(params) if not params.is_empty() else ""])
	return main.ws.send_command("devicehub_command", {"device": device, "name": name, "params": params})

func light_params() -> Dictionary:
	var c := _lm_color.color
	return {"mode": _lm_mode.get_item_text(_lm_mode.selected), "brightness": int(_lm_bright.value),
		"speed": int(_lm_speed.value), "transition_ms": int(_lm_trans.value),
		"color": [int(round(c.r * 255)), int(round(c.g * 255)), int(round(c.b * 255))]}

func apply_light() -> void:
	send(ILL, "SET_LIGHT_MODE", light_params())

func mist(pattern: String) -> void:
	send(ILL, "SET_MIST", {"pattern": "OFF"} if pattern == "OFF" else {"pattern": pattern, "duration_s": int(_mist_dur.value)})

func trigger(effect: String) -> void:
	send(ILL, "TRIGGER_EFFECT", {"effect": effect, "duration_ms": int(_fx_dur.value), "intensity": int(_fx_int.value)})

## Every device: mist and relay off, effects stopped, a ball release aborted.
func stop_all() -> void:
	if backend_ready():
		_add_log("→ STOP_ALL")
		main.ws.send_command("devicehub_stop_all")

func _request(kind: String, command: String, params: Dictionary) -> void:
	if not backend_ready() or _pending.has(kind):
		return
	_pending[kind] = main.ws.send_command(command, params)

## When the tab opens: ask at once.
func opened() -> void:
	_pending.clear()
	_poll_left = 0.0
	refresh()

## Called each frame while the tab shows: polls the hub (as the console does, once a second).
func tick(dt: float) -> void:
	_poll_left -= dt
	if _poll_left <= 0.0:
		_poll_left = POLL_S
		_request("meta", "devicehub_meta", {})
		if bool(meta.get("connected", false)):
			_request("devices", "devicehub_devices", {})
			for d in devices:
				if d is Dictionary and bool(d.get("online", false)):
					_request("status%d" % int(d.get("id", 0)), "devicehub_status", {"device": int(d.get("id", 0))})
	refresh()

func _on_ack(rid: String, ok: bool, data: Dictionary) -> void:
	var cmd := str(data.get("command", ""))
	if not cmd.begins_with("devicehub_"):
		return
	for k in _pending.keys():
		if _pending[k] == rid:
			_pending.erase(k)
	if not ok:
		if cmd in ["devicehub_command", "devicehub_stop_all", "devicehub_diag"] or meta.is_empty():
			_result(false, str(data.get("reason", "断られました")))
		if cmd == "devicehub_meta":
			meta = {"connected": false, "error": str(data.get("reason", ""))}
		return
	match cmd:
		"devicehub_meta":
			meta = data
		"devicehub_devices":
			devices = data.get("devices", []) if data.get("devices") is Array else []
		"devicehub_status":
			if data.get("status") is Dictionary:
				status[int(data.get("device", 0))] = data.status
		"devicehub_diag":
			_add_log("診断: " + JSON.stringify(data.get("diag", {})))
			_result(true, "診断を受け取りました（イベントの欄）")
		"devicehub_command":
			var r: Dictionary = data.result if data.get("result") is Dictionary else {}
			var good := bool(r.get("ok", false))
			var line := "%s → %s: %s%s" % [NAMES.get(int(r.get("destination", 0)), "?"), str(r.get("name", "")),
				str(r.get("result", "")), ("（" + str(r.reason) + "）") if r.get("reason") != null else ""]
			_add_log(("✓ " if good else "✗ ") + line)
			_result(good, line)
		"devicehub_stop_all":
			var parts: Array[String] = []
			var res: Dictionary = data.results if data.get("results") is Dictionary else {}
			for k in res.keys():
				parts.append("%s=%s" % [NAMES.get(int(k), str(k)), str(res[k].get("result", "")) if res[k] is Dictionary else "?"])
			_add_log("STOP_ALL: " + " ".join(parts))
			_result(true, "STOP ALL: " + " ".join(parts))

func _on_message(msg: Dictionary) -> void:
	if str(msg.get("type", "")) != "devicehub_event" or not msg.get("data") is Dictionary:
		return
	var e: Dictionary = msg.data
	var src := int(e.get("source", 0))
	var extra := {}
	for k in e.keys():
		if not k in ["time", "name", "source", "type", "event_id", "session_id", "raw"]:
			extra[k] = e[k]
	_add_log("%s  %s  %s %s" % [str(e.get("time", "")), NAMES.get(src, "hub" if src == 1 else str(src)),
		str(e.get("name", "")), JSON.stringify(extra) if not extra.is_empty() else ""])

func _result(ok: bool, text: String) -> void:
	result_ok = ok
	result_text = text

func _add_log(line: String) -> void:
	log_lines.append(line)
	while log_lines.size() > LOG_MAX:
		log_lines.pop_front()

# ------------------------------------------------------------------ view
## A JSON number as the console shows it (Godot reads them all as floats).
static func _num(v) -> String:
	if v == null:
		return "-"
	if v is float and is_equal_approx(v, roundf(v)):
		return str(int(v))
	return str(v)

func refresh() -> void:
	var ready := backend_ready()
	for b in _buttons:
		b.disabled = not ready
	var connected := bool(meta.get("connected", false))
	if meta.is_empty():
		_hub.text = "ハブに問い合わせ中…" if ready else "バックエンドにつながっていない（./start.sh で起動する）"
	elif meta.has("error") and str(meta.error) != "":
		_hub.text = "ハブを使っていない: " + str(meta.error)
	else:
		_hub.text = "ハブ: %s　システム %s　ポート %s　セッション %s" % ["接続" if connected else "接続待ち（つなぎ直し中）",
			str(int(meta.get("system_id", 0))), str(meta.get("port", "?")),
			str(int(meta.get("session_id", 0))) if connected else "-"]
	_hub.add_theme_color_override("font_color", GOOD if connected else YELLOW)
	var rows: Array[String] = []
	for d in devices:
		if d is Dictionary:
			var on := bool(d.get("online", false))
			rows.append("%s %s　%s　RTT %s　セッション %s　fw %s" % ["●" if on else "○",
				NAMES.get(int(d.get("id", 0)), str(d.get("name", ""))), str(d.get("state", "-")) if on else "offline",
				("%s ms" % _num(d.rtt_ms)) if on and d.get("rtt_ms") != null else "-",
				("ok" if bool(d.get("session_ok", false)) else "同期中") if on else "-",
				str(status.get(int(d.get("id", 0)), {}).get("fw", d.get("fw", "-")))])
	_dev.text = "\n".join(rows) if not rows.is_empty() else ("機器の一覧を待っています" if connected else "-")
	var ill: Dictionary = status.get(ILL, {})
	_ill_state.text = "状態: %s　モード: %s" % [str(ill.get("state", "-")), str(ill.get("op_mode", "-"))]
	_ill_kv.text = "" if ill.is_empty() else "ミスト %s（%s、残り %s）　照明 %s / %s　リレー %s　ローカル操作 %s" % [
		str(ill.get("mist_pattern", "-")), "ON" if bool(ill.get("mist_on", false)) else "OFF",
		("%s s" % _num(ill.get("mist_remaining_s", 0))) if str(ill.get("mist_pattern", "OFF")) != "OFF" else "-",
		str(ill.get("light_mode", "-")), _num(ill.get("brightness")), _num(ill.get("relay_on_mask", 0)),
		"中" if bool(ill.get("local_mode", false)) else "-"]
	for id in DIALS:
		var st: Dictionary = status.get(id, {})
		(_dial_state[id] as Label).text = "状態: %s　モード: %s　受取 %s 回　排出 %s 回" % [str(st.get("dial_state", st.get("state", "-"))),
			str(st.get("op_mode", "-")), _num(st.get("cycle")), _num(st.get("releases"))]
	_log.text = "\n".join(log_lines) if not log_lines.is_empty() else "（まだありません）"

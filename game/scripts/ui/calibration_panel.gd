class_name CalibrationPanel
extends VBoxContainer
## The settings screen's 校正 tab (#98): the values measured on this machine
## (config/calibration.json, #96), each with its steps, its state and its buttons.
## Every button sends the same backend command as the debug panel (z_set, arm_set,
## homework_spot_set, camera_map_*, enable_motors, home): the backend checks and saves,
## the game never writes RobotState. While this tab shows, main.gd lets the keys move the
## arm (arrows, W / S, [ ], Q / A); gestures and the auto catch stay off, Space stops.

const YELLOW := Color("ffe03c")
const CYAN := Color("7ae0ff")
const MUTED := Color("8fa3c4")
const BAD := Color("ff8a8a")
const GOOD := Color("9ff0a8")

var main: Node
var hw: HomeworkClient
var _link: Label
var _z: Label
var _claw: Label
var _spot: Label
var _cam: Label
var _overview: OverviewPicker
var _focus: OverviewPicker
var _ws_buttons: Array[Button] = []  # need the backend
## The last calibration command's answer from the backend ("" = none yet), shown by the
## settings screen under the tabs (visible wherever the tab is scrolled).
var result_text := ""
var result_ok := true

## The commands this tab sends (directly or through main.gd / the homework client), with
## the words shown for their answer.
const COMMANDS := {
	"enable_motors": "モーター", "home": "原点復帰", "z_set": "Z の記録",
	"arm_step": "爪を回す", "arm_set": "爪の記録", "arm_goto": "爪の開け閉め",
	"homework_spot_set": "宿題の位置の記録",
	"camera_map_add": "カメラの点の追加", "camera_map_undo": "カメラの点を戻す",
	"camera_map_clear": "カメラの点を消す",
}

func setup(m: Node) -> void:
	main = m
	hw = main.homework_for_calibration()
	if main.get("ws") != null:
		main.ws.ack.connect(_on_ack)
	add_theme_constant_override("separation", 6)
	_note("この画面を開いている間は、キーでアームを動かせる: 矢印 = XY、W / S = 上下、[ ] = 爪を回す、"
		+ "Q / A = 爪を開く / 閉じる、Space = 止める。測った値はバックエンドが config/calibration.json に保存する"
		+ "（この機械だけの値。Git には入らない）。")

	_head("つながり")
	_link = _value()
	var row := _row()
	_ws_button(row, "モーター有効", func(): main.ws.send_command("enable_motors", {"enable": true}))
	_ws_button(row, "モーター無効", func(): main.ws.send_command("enable_motors", {"enable": false}))
	_ws_button(row, "原点復帰", func(): main.ws.send_command("home"))

	_head("1. Z の上下（最初に測る）")
	_note("W でアームを一番上まで巻き上げて「上を記録」。続けて S で一番下まで下げて「下を記録」。"
		+ "2 点のカウント差から Z の 1 単位あたりのカウントと向きを求める。")
	_z = _value()
	row = _row()
	_ws_button(row, "ここを上に記録", func(): main.ws.send_command("z_set", {"which": "top"}))
	_ws_button(row, "ここを下に記録", func(): main.ws.send_command("z_set", {"which": "bottom"}))
	_ws_button(row, "Z をやり直す（記録を消す）", func(): main.ws.send_command("z_set", {"which": "clear"}))

	_head("2. 爪の開き・閉じ")
	_note("[ ] か下のボタンで爪を回し、開いた位置で「開きに記録」、閉じた位置で「閉じに記録」。"
		+ "記録すると Q / A で開け閉めできる。")
	_claw = _value()
	row = _row()
	for d in [-10.0, -1.0, 1.0, 10.0]:
		var deg: float = d
		_button(row, ("%+d°" % int(deg)), func(): main.arm_step(deg))
	row = _row()
	_button(row, "ここを開きに記録", func(): main.arm_set("open"))
	_button(row, "ここを閉じに記録", func(): main.arm_set("closed"))
	_button(row, "開く（Q）", func(): main.arm_goto("open"))
	_button(row, "閉じる（A）", func(): main.arm_goto("closed"))

	_head("3. 宿題を見に行く位置")
	_note("原点復帰と Z の上の記録のあとで。爪を開き（Q）、矢印と S でアームをプリントの上へ下ろし、"
		+ "開いた爪がプリントに立つ高さで「ここを記録」。子どもの手の上には下ろさない。")
	_spot = _value()
	row = _row()
	_ws_button(row, "ここを宿題の位置に記録", func(): if hw != null: hw.record_spot())

	_head("4. 俯瞰カメラ → XY")
	_note("アームの先のカメラ（右）の十字が紙の印に重なるように矢印で動かし、"
		+ "俯瞰カメラの画像（左）でその印をクリック。場所を変えて 4 点以上。原点復帰のあとで。")
	var cams := HBoxContainer.new()
	cams.add_theme_constant_override("separation", 10)
	add_child(cams)
	_overview = OverviewPicker.new()
	_overview.hw = hw
	_overview.clickable = true
	_overview.custom_minimum_size = Vector2(440, 248)
	_overview.picked.connect(_on_picked)
	cams.add_child(_overview)
	_focus = OverviewPicker.new()
	_focus.hw = hw
	_focus.center_cross = true
	_focus.custom_minimum_size = Vector2(330, 248)
	cams.add_child(_focus)
	if main.cameras != null:
		_overview.texture = main.cameras.texture(hw.camera_role if hw != null else "overview")
		_overview.use_material(main.cameras.view_material(false))
		_focus.texture = main.cameras.texture("focus")
		_focus.use_material(main.cameras.view_material(false))
	_cam = _value()
	row = _row()
	_ws_button(row, "1 点戻す", func(): if hw != null: hw.calib_undo())
	_ws_button(row, "全部消す", func(): if hw != null: hw.calib_clear())

func _head(text: String) -> void:
	add_child(StudyHud.label(text, 24, CYAN, 6))

func _note(text: String) -> void:
	var l := StudyHud.label(text, 16, MUTED, 2)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(860, 0)
	add_child(l)

func _value() -> Label:
	var l := StudyHud.label("", 18, Color.WHITE, 3)
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
	b.add_theme_font_size_override("font_size", 18)
	b.focus_mode = Control.FOCUS_NONE  # Space stays the stop key
	b.pressed.connect(cb)
	parent.add_child(b)
	return b

func _ws_button(parent: Control, text: String, cb: Callable) -> Button:
	var b := _button(parent, text, cb)
	_ws_buttons.append(b)
	return b

## A calibration command answered (ack / nack): kept for the screen while the tab shows.
func _on_ack(_rid: String, ok: bool, data: Dictionary) -> void:
	var cmd := str(data.get("command", ""))
	if not COMMANDS.has(cmd) or not is_visible_in_tree():
		return
	result_ok = ok
	result_text = ("%s: できました" % COMMANDS[cmd]) if ok else \
		("%s は断られました: %s" % [COMMANDS[cmd], reason_text(str(data.get("reason", "")))])

## A refusal's reason as what to do next (the backend's own words when it is not known).
static func reason_text(reason: String) -> String:
	var r := reason.to_lower()
	if r.contains("wind the arm up") or r.contains("not wound up"):
		return "先に W でアームを一番上まで巻き上げる（Z の上を記録してから原点復帰）。" + reason
	if r == "timeout":
		return "バックエンドから返事がない"
	if r == "socket_closed":
		return "バックエンドとの接続が切れた"
	if r.contains("not connected"):
		return "実機に未接続（バックエンドとシリアルを確認）"
	if r.contains("motors not enabled"):
		return "モーターが無効:「モーター有効」を押す"
	if r.contains("alarm"):
		return "アラーム中: デバッグパネル（F1）でアラーム解除 →「原点復帰」"
	if r.contains("not homed") or r.contains("not_homed"):
		return "原点復帰が必要:「原点復帰」を押す"
	if r.contains("busy"):
		return "ほかの動きの途中: 終わるまで待つか Space で止める"
	return reason if reason != "" else "理由不明"

func _on_picked(uv: Vector2) -> void:
	if hw != null:
		hw.calib_add(uv)

## When the tab opens: ask the backend for the camera map's state.
func opened() -> void:
	result_text = ""
	result_ok = true
	if hw != null and backend_ready():
		hw.request_camera_map()
	refresh()

func backend_ready() -> bool:
	return main != null and RobotState.source == "websocket" and main.ws.enabled and main.ws.is_open()

static func deg_text(v: float) -> String:
	return "未記録" if is_nan(v) else "%.1f°" % v

func refresh() -> void:
	var ready := backend_ready()
	for b in _ws_buttons:
		b.disabled = not ready
	if RobotState.source != "websocket":
		_link.text = "ゲーム内の仮想クレーン（バックエンドなし）: 爪だけ試せる。Z・宿題の位置・カメラの校正には ./start.sh で起動する"
	elif not ready:
		_link.text = "バックエンドにつながっていない"
	else:
		var what := "実機" if str(main.ws.server_robot) == "real" else "仮想クレーン（バックエンドの Mock）"
		_link.text = "%s　モーター: %s　原点: %s　状態: %s%s" % [what,
			"有効" if RobotState.motors_enabled else "無効（動かすには「モーター有効」）",
			"済" if RobotState.homed else "まだ", RobotState.machine_state,
			("　" + RobotState.robot_error) if RobotState.robot_error != "" else ""]
	_link.add_theme_color_override("font_color", GOOD if ready and RobotState.motors_enabled else YELLOW)
	_z.text = "上: %s　下: %s　換算: %s" % ["記録済" if RobotState.z_top_set or RobotState.z_reference_set else "まだ",
		"記録済" if RobotState.z_bottom_set else "まだ",
		"測った値（calibration.json）" if RobotState.z_calibrated else "設定ファイルの仮の値（まだ測っていない）"]
	_z.add_theme_color_override("font_color", GOOD if RobotState.z_calibrated else BAD)
	_claw.text = "いま %s　開き: %s　閉じ: %s" % ["%.1f°" % RobotState.arm_deg if RobotState.arm_reference_set else "?",
		deg_text(RobotState.arm_open_deg), deg_text(RobotState.arm_closed_deg)]
	var claw_ok := not is_nan(RobotState.arm_open_deg) and not is_nan(RobotState.arm_closed_deg)
	_claw.add_theme_color_override("font_color", GOOD if claw_ok else BAD)
	if hw == null:
		_spot.text = "（宿題の見守りがありません）"
		_cam.text = ""
		return
	var spot = hw.approach.get("spot")
	_spot.text = ("記録済: X %.0f / Y %.0f / Z %.0f" % [float(spot.x), float(spot.y), float(spot.z)]
		if spot is Dictionary else "まだ") + ("　" + hw.advice_status if hw.advice_status != "" else "")
	_spot.add_theme_color_override("font_color", GOOD if spot is Dictionary else BAD)
	_cam.text = hw.calib_summary() + ("　" + hw.calib_status if hw.calib_status != "" else "")
	_cam.add_theme_color_override("font_color", GOOD if hw.calibration_usable() else BAD)
	_overview.overlay.queue_redraw()

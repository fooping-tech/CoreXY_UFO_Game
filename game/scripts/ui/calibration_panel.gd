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
## #114: Jev / the tutor AI / Claude Code / VOICEVOX reachable? (services_check)
var services: Array = []
var _services: Label  # the whole list as text (tests; hidden)
var _services_box: VBoxContainer  # one coloured line per check
var _services_shown := ""
var _services_asking := false
var _asked := false  # this opening's requests went out (the backend may connect later)
## #110: the study mode's capture heights
var height_status: Dictionary = {}
var _height: Label
var _drum: SpinBox
var _height_filled := false
var _z_restore: Label  # #106: the call-back's estimate, for a grown-up to check
var _z_use: Button
var restore_estimate: Dictionary = {}
## The last calibration command's answer from the backend ("" = none yet), shown by the
## settings screen under the tabs (visible wherever the tab is scrolled).
var result_text := ""
var result_ok := true

## The commands this tab sends (directly or through main.gd / the homework client), with
## the words shown for their answer.
const COMMANDS := {
	"enable_motors": "モーター", "home": "原点復帰", "z_set": "Z の記録", "z_restore": "前回の Z の呼び出し",
	"arm_step": "爪を回す", "arm_set": "爪の記録", "arm_goto": "爪の開け閉め",
	"homework_spot_set": "宿題の位置の記録",
	"camera_map_add": "カメラの点の追加", "camera_map_undo": "カメラの点を戻す",
	"camera_map_clear": "カメラの点を消す",
	"study_height_set": "撮影の高さの保存", "study_height_confirm": "撮影の高さの確認", "move_z": "Z の移動",
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

	_head("0. AI・外部サービス")
	_note("勉強モードで使う外部のサービスにつながるか（タブを開くと確かめる。推論・課金はしない）。"
		+ "「AI に試しに質問する」は、サンプルのプリント 1 枚と短い質問を解説の AI に 1 回送る。")
	_services = _value()
	_services.visible = false
	_services_box = VBoxContainer.new()
	add_child(_services_box)
	var srow := _row()
	_ws_button(srow, "もう一度確かめる", func(): check_services(false))
	_ws_button(srow, "AI に試しに質問する", func(): check_services(true))

	_head("つながり")
	_link = _value()
	var row := _row()
	_ws_button(row, "モーター有効", func(): main.ws.send_command("enable_motors", {"enable": true}))
	_ws_button(row, "モーター無効", func(): main.ws.send_command("enable_motors", {"enable": false}))
	_ws_button(row, "原点復帰", func(): main.ws.send_command("home"))

	_head("1. Z の上下（最初に測る）")
	_note("電源を入れ直したあとは、Z の換算（1 単位あたりのカウントと向き）は残っていて、上下の記録だけが消える。"
		+ "「前回の上下を呼び出す」→ 表示された Z とアームの高さが合っていれば「これを使う」。合わなければ W で一番上まで"
		+ "巻き上げて「上を記録」だけでよい（下はロープの長さを変えたときだけ）。")
	_z_restore = _value()
	row = _row()
	_ws_button(row, "前回の上下を呼び出す", func():
		restore_estimate = {}
		main.ws.send_command("z_restore", {"apply": false}))
	_z_use = _ws_button(row, "これを使う（アームの高さを確かめてから）", func():
		if not restore_estimate.is_empty():
			main.ws.send_command("z_restore", {"apply": true, "turns": int(restore_estimate.get("turns", 0))}))
	_note("初めて測るとき・ロープの長さを変えたとき: W でアームを一番上まで巻き上げて「上を記録」。続けて S で一番下まで下げて「下を記録」。"
		+ "2 点のカウント差から Z の 1 単位あたりのカウントと向きを求める。この画面では前に測った範囲で止まらない"
		+ "（下ろす量を変えたときに測り直せる）。巻き過ぎ・下ろし過ぎに注意して、押している間だけ動かす。")
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

	_head("5. 勉強モードの撮影の高さ")
	_note("HELP でアームを下ろして撮る高さ（爪先が机から 10cm）。1 の Z の上下だけで決まる: 1cm あたりの Z は"
		+ "巻き上げドラムの半径と Z の換算から計算し、机は 1 の「下」の記録（爪先を机に付けて記録したところ）。"
		+ "「保存」→「10cm へ動かす（試す）」で爪先と机の間を定規で確かめて「確かめた」。"
		+ "ロープが重なって巻かれると計算がずれるので、この確認だけは要る。")
	row = _row()
	_drum = _spin(row, "巻き上げドラムの半径 mm", 3.0, 100.0, 0.5, 15.0)
	_ws_button(row, "保存（机 = Z の下の記録）", func(): save_height("bottom"))
	_ws_button(row, "ここを机に記録して保存", func(): save_height("here"))
	_height = _value()
	row = _row()
	_ws_button(row, "10cm へ動かす（試す）", func(): try_height(StudyServices.stage_names()[0]))
	row = _row()
	_ws_button(row, "確かめた（勉強モードで使う）", func(): main.ws.send_command("study_height_confirm", {"confirmed": true}))
	_ws_button(row, "確認を外す", func(): main.ws.send_command("study_height_confirm", {"confirmed": false}))

func _spin(parent: Control, label: String, lo: float, hi: float, step: float, v: float) -> SpinBox:
	parent.add_child(StudyHud.label(label, 16, MUTED, 2))
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = v
	parent.add_child(s)
	return s

## #110: the entered values -> the backend (calibration.json#study_height), unconfirmed.
## desk: "bottom" = the Z calibration's bottom, "here" = the arm's Z now.
func height_params(desk: String) -> Dictionary:
	return {"drum_radius_mm": _drum.value, "desk": desk}

func save_height(desk: String) -> void:
	main.ws.send_command("study_height_set", height_params(desk))

## The Z of a stage as saved (confirmed or not): where the test move goes.
func stage_z(stage: String) -> float:
	var stages: Array = height_status.get("stages", []) if not (height_status.get("stages", []) as Array).is_empty() \
		else height_status.get("trial_stages", [])
	for s in stages:
		if s is Dictionary and str(s.get("name", "")) == stage:
			return float(s.get("z", NAN))
	return NAN

func try_height(stage: String) -> void:
	var z := stage_z(stage)
	if is_nan(z):
		_set_result(false, "撮影の高さがまだ使えない: " + str(height_status.get("trial_problem", height_status.get("problem", "保存して"))))
		return
	main.ws.send_command("move_z", {"z": z})

## The backend's heights; the saved values fill the inputs once (they stay as typed after).
func show_heights(st: Dictionary) -> void:
	height_status = st
	var saved: Dictionary = st.saved if st.get("saved") is Dictionary else {}
	if not _height_filled and not saved.is_empty():
		_height_filled = true
		_drum.value = float(saved.get("drum_radius_mm", _drum.value))
	elif not _height_filled and st.get("default_drum_radius_mm") != null:
		_drum.value = float(st.default_drum_radius_mm)

func _set_result(ok: bool, text: String) -> void:
	result_ok = ok
	result_text = text

## The backend's heights in words (#110).
static func height_text(st: Dictionary) -> String:
	if st.is_empty():
		return "（まだ問い合わせていない）"
	var v: Dictionary = st.get("values", {}) if st.get("values") is Dictionary else {}
	var lines: Array[String] = []
	if not bool(st.get("z_calibrated", true)):
		lines.append("1 の Z の上下をまだ測っていない（1cm あたりの Z を計算できない）")
	if bool(st.get("z_changed", false)):
		lines.append("Z を測り直したので、撮影の高さを「保存」し直して、試してから「確かめた」")
	if v.get("z_per_cm") != null:
		lines.append("1cm = Z %.2f　机 = Z %s" % [float(v.z_per_cm), str(v.get("z_desk_tip", "?"))])
	var stages: Array = st.get("stages", []) if not (st.get("stages", []) as Array).is_empty() else st.get("trial_stages", [])
	var parts: Array[String] = []
	for s in stages:
		if s is Dictionary:
			parts.append("%s: Z %.1f（爪先 %.1f cm）" % [str(s.name), float(s.z), float(s.tip_cm)])
	if not parts.is_empty():
		lines.append("　".join(parts))
	if bool(st.get("usable", false)):
		lines.append("確認済み: 勉強モードで使う")
	elif st.has("trial_problem"):
		lines.append("このままでは使えない: " + str(st.trial_problem))
	elif st.get("saved") != null:
		lines.append("まだ確認していない: 試してから「確かめた」")
	else:
		lines.append("まだ保存していない")
	return "\n".join(lines)

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
	if cmd == "services_check":
		_services_asking = false
		if ok and data.get("results") is Array:
			# an "ask" run adds its line to the last check
			var asked: Array = (data.results as Array).filter(func(r): return r is Dictionary and r.get("name") == "ask")
			if asked.is_empty() or services.is_empty():
				services = data.results
			else:
				services = services.filter(func(r): return r is Dictionary and r.get("name") != "ask") + asked
		elif not ok:
			services = [{"name": "backend", "label": "バックエンド", "status": "ng", "detail": str(data.get("reason", ""))}]
		return
	if cmd == "study_height_status":  # asked when the tab opens: no message
		if ok:
			show_heights(data)
		return
	if not COMMANDS.has(cmd) or not is_visible_in_tree():
		return
	if ok and cmd in ["study_height_set", "study_height_confirm"]:
		show_heights(data)
	result_ok = ok
	result_text = ("%s: できました" % COMMANDS[cmd]) if ok else \
		("%s は断られました: %s" % [COMMANDS[cmd], reason_text(str(data.get("reason", "")))])
	if cmd == "z_restore":
		var r: Dictionary = data.restore if ok and data.get("restore") is Dictionary else {}
		restore_estimate = {} if r.is_empty() or bool(r.get("applied", false)) or bool(r.get("too_far", false)) else r
		_z_restore.text = restore_text(r) if ok else ""
		if ok and bool(r.get("applied", false)):
			result_text = "前回の上下を呼び出しました（Z %.1f）" % float(r.get("z", 0.0))

## The call-back's estimate in words (#106).
static func restore_text(r: Dictionary) -> String:
	if r.is_empty():
		return ""
	if bool(r.get("applied", false)):
		return "呼び出しました: いま Z %.1f" % float(r.get("z", 0.0))
	var s := "前回の記録から: いま Z 約 %.1f（0 = 一番下、100 = 一番上）。前回止めた所から %+.1f 単位" % [
		float(r.get("z", 0.0)), float(r.get("drift_units", 0.0))]
	if bool(r.get("too_far", false)):
		return s + "。ずれが大きすぎる（電源を切っている間に回った）: 一番上まで巻き上げて「上を記録」"
	return s + "。アームの高さが合っていれば「これを使う」"

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
	restore_estimate = {}
	_z_restore.text = ""
	_asked = false
	_ask_backend()
	refresh()

## The tab's questions to the backend, once per opening: at once, or when it connects (the tab
## opens at start, #114, often before the backend's WebSocket is up).
func _ask_backend() -> void:
	if _asked or not backend_ready():
		return
	_asked = true
	if hw != null:
		hw.request_camera_map()
	main.ws.send_command("study_height_status")
	check_services(false)

func check_services(ask: bool) -> void:
	if not backend_ready():
		return
	_services_asking = true
	main.ws.send_command("services_check", {"ask": ask})

## The checks in words (#114): ✓ ok, ✗ the reason, － not used here.
static func services_text(rows: Array, asking: bool) -> String:
	if rows.is_empty():
		return "確かめています…" if asking else "（バックエンドにつながると確かめる）"
	var lines: Array[String] = []
	for r in rows:
		if r is Dictionary:
			var mark: String = {"ok": "✓", "ng": "✗"}.get(str(r.get("status", "")), "－")
			lines.append("%s %s: %s" % [mark, str(r.get("label", r.get("name", ""))), str(r.get("detail", ""))])
	if asking:
		lines.append("（確かめています…）")
	return "\n".join(lines)

func backend_ready() -> bool:
	return main != null and RobotState.source == "websocket" and main.ws.enabled and main.ws.is_open()

static func deg_text(v: float) -> String:
	return "未記録" if is_nan(v) else "%.1f°" % v

func refresh() -> void:
	var ready := backend_ready()
	for b in _ws_buttons:
		b.disabled = not ready
	if ready and not _asked and is_visible_in_tree():
		_ask_backend()
	_services.text = services_text(services, _services_asking)
	if _services.text != _services_shown:  # one line per check, coloured by its own result
		_services_shown = _services.text
		for c in _services_box.get_children():
			c.queue_free()
		var lines := _services.text.split("\n")
		for line in lines:
			var l := StudyHud.label(line, 17, YELLOW, 2)
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size = Vector2(860, 0)
			var colour: Color = GOOD if line.begins_with("✓") else (BAD if line.begins_with("✗") else (MUTED if line.begins_with("－") else YELLOW))
			l.add_theme_color_override("font_color", colour)
			_services_box.add_child(l)
	_height.text = height_text(height_status)
	_height.add_theme_color_override("font_color", GOOD if bool(height_status.get("usable", false)) else YELLOW)
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
	_z_use.disabled = not ready or restore_estimate.is_empty()
	_z_restore.add_theme_color_override("font_color", YELLOW)
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

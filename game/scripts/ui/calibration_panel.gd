class_name CalibrationPanel
extends VBoxContainer
## The settings screen's 校正 tab (#98): the values measured on this machine
## (config/calibration.json, #96), each with its steps, its state and its buttons.
## Every button sends the same backend command as the debug panel (z_set, arm_set,
## homework_spot_set, camera_map_*, enable_motors, home): the backend checks and saves,
## the game never writes RobotState. While this tab shows, main.gd lets the keys move the
## arm (arrows, W / S, [ ], Q / A); gestures and the auto catch stay off, Space stops.

const YELLOW := PanelKit.YELLOW
const CYAN := PanelKit.CYAN
const MUTED := PanelKit.MUTED
const BAD := PanelKit.BAD
const GOOD := PanelKit.GOOD
const INK := Color("e8eefc")
const CARD_BG := Color("1f2a44")
const CARD_BORDER := Color("34446a")
const WIDTH := 590.0  # wrapped text inside a card (portrait, #157: the settings panel is 690 wide)

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
## the rows only an "ask" run adds (#230: the worksheet reader, POST /v1/sheet)
const ASK_ROWS := ["ask", "sheet"]
var _asked := false  # this opening's requests went out (the backend may connect later)
## #124: the backend's word on the robot's serial link (list_ports' "robot"), asked again
## every LINK_ASK_MS while the real robot is not connected.
var link_info: Dictionary = {}
const LINK_ASK_MS := 5000
var _link_asked_ms := -100000
## #110: the study mode's capture heights
var height_status: Dictionary = {}
var _height: Label
var _drum: SpinBox
var _height_filled := false
## #169: the easy mode's drop points over the two Dials, as the backend has them (easy_status)
var easy_status: Dictionary = {}
## #242: the arm-tip camera's calibration (focus_status), and the run that makes it
var focus_status: Dictionary = {}
var focus_cal := FocusCalibrator.new()
var _focus_label: Label
var _easy: Label
var _prep_was_active := false
var _z_restore: Label  # #106: the call-back's estimate, for a grown-up to check
var _z_use: Button
## #126: to the recorded top / bottom (move_z), like the claw's 開く / 閉じる
var _z_up: Button
var _z_down: Button
var restore_estimate: Dictionary = {}
## The last calibration command's answer from the backend ("" = none yet), shown by the
## settings screen under the tabs (visible wherever the tab is scrolled).
var result_text := ""
var result_ok := true
## #120: where new rows go (the panel itself, or the card being built)
var _box: Container = self
## section key -> {card: PanelContainer, badge: Label, badge_bg: StyleBoxFlat}
var _cards := {}
## the summary at the top: section key -> Button; the next thing to do
var _summary := {}
var _next: Label
var _summary_shown := ""
## #167: the one-button preparation
var _prepare: Button
var _prepare_label: Label
var _alarm_clear: Button

## The sections in order (#120): key, title. The summary lists them; section_states() says how
## each one is.
const SECTIONS := [
	["link", "つながりとモーター"], ["z", "Z の上下と原点復帰"], ["claw", "爪の開き・閉じ"],
	["spot", "宿題を見に行く位置"], ["camera", "俯瞰カメラ → XY"], ["height", "学習モードの撮影の高さ"],
	["focus", "先端カメラの校正（問題を見に行く）"], ["services", "AI・外部サービス"],
]

## The commands this tab sends (directly or through main.gd / the homework client), with
## the words shown for their answer.
const COMMANDS := {
	"enable_motors": "モーター", "home": "原点復帰", "z_set": "Z の記録", "z_restore": "前回の Z の呼び出し",
	"arm_step": "爪を回す", "arm_set": "爪の記録", "arm_goto": "爪の開け閉め",
	"homework_spot_set": "宿題の位置の記録",
	"camera_map_add": "カメラの点の追加", "camera_map_undo": "カメラの点を戻す",
	"camera_map_clear": "カメラの点を消す",
	"calibration_prepare": "準備をまとめて実行", "clear_alarm": "アラーム解除", "study_height_set": "撮影の高さの保存", "study_height_confirm": "撮影の高さの確認", "move_z": "Z の移動",
	"focus_calibrate": "先端カメラの校正",
	"easy_dial_set": "投入の高さ・ポータルの記録",
}

func setup(m: Node) -> void:
	main = m
	hw = main.homework_for_calibration()
	if main.get("ws") != null:
		main.ws.ack.connect(_on_ack)
	add_theme_constant_override("separation", 12)

	# --- the summary: what is done, what is next (#120)
	var top := _card_panel()
	add_child(top)
	var tv := _card_box(top)
	var th := HBoxContainer.new()
	tv.add_child(th)
	th.add_child(StudyHud.label("準備のようす", 24, CYAN, 4))
	var keys := StudyHud.label("キー: 矢印 = XY　W / S = 上下　[ ] = 爪を回す　Q / A = 開く / 閉じる　Space = 止める",
		15, MUTED, 2)
	keys.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	keys.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	keys.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	th.add_child(keys)
	_next = StudyHud.label("", 19, YELLOW, 3)
	_next.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_next.custom_minimum_size = Vector2(WIDTH, 0)
	tv.add_child(_next)
	# #167: everything done by hand after a start, one press (never on opening the tab)
	var pc := StudyHud.label("起動したら: アームの周りに物がなく、アームの高さが前回止めたときと同じなら押す。"
		+ "モーター有効 → 前回の Z の上下を呼び出す → アームを一番上へ → 爪を開いて閉じる → 原点復帰 → ステージの真ん中へ → 爪を開いておく。"
		+ "Space でいつでも止まる。", 15, YELLOW, 2)
	pc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pc.custom_minimum_size = Vector2(WIDTH, 0)
	tv.add_child(pc)
	var prow := HBoxContainer.new()
	tv.add_child(prow)
	_prepare = _ws_button(prow, "準備をまとめて実行", func(): main.ws.send_command("calibration_prepare"), "primary")
	# #249: an alarm (a failed homing, the stop key...) is cleared here too, not only in the
	# debug panel. Moves nothing; homing is needed again after it
	_alarm_clear = _ws_button(prow, "アラーム解除", func(): main.ws.send_command("clear_alarm"))
	_alarm_clear.tooltip_text = "アラームを解除する（機械は動かない）。解除したら原点復帰からやり直す"
	_prepare_label = StudyHud.label("", 15, MUTED, 2)
	_prepare_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_prepare_label.custom_minimum_size = Vector2(WIDTH, 0)
	tv.add_child(_prepare_label)
	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 0)
	tv.add_child(grid)
	for sec in SECTIONS:
		var key: String = sec[0]
		var b := Button.new()
		b.flat = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(WIDTH, 0)
		b.add_theme_font_size_override("font_size", 16)
		b.focus_mode = Control.FOCUS_NONE
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.pressed.connect(func(): scroll_to(key))
		grid.add_child(b)
		_summary[key] = b

	# --- 1. the backend and the motors
	_card("link", "つながっているか、モーターが有効かを確かめる。測った値はこの機械だけの値として "
		+ "config/calibration.json に保存される（Git には入らない）。")
	_link = _value()
	var row := _row()
	_ws_button(row, "モーター有効", func(): main.ws.send_command("enable_motors", {"enable": true}), "primary")
	_ws_button(row, "モーター無効", func(): main.ws.send_command("enable_motors", {"enable": false}))

	# --- 2. Z
	_card("z", "アームの一番上と一番下を記録して、Z（0 = 下、100 = 上）を決める。電源を入れ直すと記録は消えるが、"
		+ "換算（1 単位あたりの回転と向き）は残る。スコアゲームで自動で動く場所（ポータルの XY と投入の高さ）もここで記録する"
		+ "（#299: キャッチの高さは下と同じ。どれかがないと実機のゲームは始まらない）。")
	_z = _value()
	_easy = _value()
	_easy.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_easy.custom_minimum_size = Vector2(WIDTH, 0)
	_sub("いつもは（電源を入れ直したあと）")
	_step("①", "「前回の上下を呼び出す」を押す")
	_step("②", "出た Z とアームの高さが合っていれば「これを使う」。合わなければ下の「初めて・ロープを変えたとき」の ① だけ")
	_z_restore = _value()
	row = _row()
	_ws_button(row, "前回の上下を呼び出す", func():
		restore_estimate = {}
		main.ws.send_command("z_restore", {"apply": false}), "primary")
	_z_use = _ws_button(row, "これを使う（アームの高さを確かめてから）", func():
		if not restore_estimate.is_empty():
			main.ws.send_command("z_restore", {"apply": true, "turns": int(restore_estimate.get("turns", 0))}))
	_sub("初めて・ロープの長さを変えたとき")
	_step("①", "W を押し続けて一番上まで巻き上げ、「ここを上に記録」")
	_step("②", "S を押し続けて一番下まで下げ、「ここを下に記録」（撮影の高さの机にもなる: 爪先を机に付ける。"
		+ "かんたんモードのキャッチの高さもここ）")
	_step("③", "「下げる」「上げる」で、記録した下・上まで動くか確かめる（上下を両方記録すると押せる）")
	row = _row()
	_ws_button(row, "ここを上に記録", func(): main.ws.send_command("z_set", {"which": "top"}), "primary")
	_ws_button(row, "ここを下に記録", func(): main.ws.send_command("z_set", {"which": "bottom"}), "primary")
	_z_up = _ws_button(row, "上げる（上の記録へ）", func(): move_z_to("top"))
	_z_down = _ws_button(row, "下げる（下の記録へ）", func(): move_z_to("bottom"))
	row = _row()
	_ws_button(row, "Z をやり直す（記録を消す）", func(): main.ws.send_command("z_set", {"which": "clear"}), "danger")
	_caution("W / S では前に測った範囲で止まらない。押している間だけ動くので、巻き過ぎ・下ろし過ぎに注意。"
		+ "「上げる」「下げる」は記録した上・下で止まる（Space で止める）。")
	_sub("最後に")
	_step("④", "W か「上げる」で一番上まで巻き上げてから「原点復帰」（XY の原点を決める）")
	row = _row()
	_ws_button(row, "原点復帰", func(): main.ws.send_command("home"), "primary")
	# #299: the easy mode's portal and release height, recorded with the Z records (the catch
	# height is the bottom record). Kept across starts; the score game does not start without them.
	_sub("スコアゲームで自動で動く場所（原点復帰のあとで。次の起動でも使う）")
	_step("⑤", "矢印キーでアームをポータル（左の Dial 1）の受け口の真上へ動かして「ポータルの XY を記録」")
	_step("⑥", "受け口の上で、爪を開けばカプセルが入る高さまで S で下ろして「投入の高さに記録」（Z を測り直したら記録し直す）")
	row = _row()
	_ws_button(row, "ポータルの XY を記録", func(): main.ws.send_command("easy_dial_set", {"which": "dial_1"}), "primary")
	_ws_button(row, "投入の高さに記録", func(): main.ws.send_command("easy_dial_set", {"which": "release_z"}), "primary")
	_caution("アームが届かない所にポータルがあるときは記録しない（置き場所を直す）。キャッチは記録した下（Z 0）まで下ろす。"
		+ "移動の高さは Z の一番上。")

	# --- 3. the claw
	_card("claw", "爪を開いた位置と閉じた位置を記録する。記録すると Q / A で開け閉めできる。")
	_claw = _value()
	_step("①", "[ ] か下のボタンで爪を回す")
	row = _row()
	for d in [-10.0, -1.0, 1.0, 10.0]:
		var deg: float = d
		_button(row, ("%+d°" % int(deg)), func(): main.arm_step(deg))
	_step("②", "開いた位置で「開きに記録」、閉じた位置で「閉じに記録」")
	row = _row()
	_button(row, "ここを開きに記録", func(): main.arm_set("open"), "primary")
	_button(row, "ここを閉じに記録", func(): main.arm_set("closed"), "primary")
	_button(row, "開く（Q）", func(): main.arm_goto("open"))
	_button(row, "閉じる（A）", func(): main.arm_goto("closed"))

	# --- 4. the homework spot
	_card("spot", "宿題を見に行くときにアームを下ろす場所。2 の Z の上と原点復帰のあとで。")
	_spot = _value()
	_step("①", "Q で爪を開き、矢印と S でアームをプリントの上へ下ろす")
	_step("②", "開いた爪がプリントに立つ高さで「ここを宿題の位置に記録」")
	_caution("子どもの手の上には下ろさない。")
	row = _row()
	_ws_button(row, "ここを宿題の位置に記録", func(): if hw != null: hw.record_spot(), "primary")

	# --- 5. the overview camera -> XY
	_card("camera", "俯瞰カメラの画像のどこがアームの XY のどこかを覚えさせる。原点復帰のあとで。")
	_cam = _value()
	_step("①", "アームの先のカメラ（右）の十字が紙の印に重なるように、矢印でアームを動かす")
	_step("②", "俯瞰カメラの画像（左）で、その印をクリック")
	_step("③", "場所を変えて 4 点以上")
	var cams := HBoxContainer.new()
	cams.add_theme_constant_override("separation", 10)
	_box.add_child(cams)
	_overview = OverviewPicker.new()
	_overview.hw = hw
	_overview.clickable = true
	_overview.custom_minimum_size = Vector2(336, 189)
	_overview.picked.connect(_on_picked)
	cams.add_child(_overview)
	_focus = OverviewPicker.new()
	_focus.hw = hw
	_focus.center_cross = true
	_focus.custom_minimum_size = Vector2(252, 189)
	cams.add_child(_focus)
	if main.cameras != null:
		_overview.texture = main.cameras.texture(hw.camera_role if hw != null else "overview")
		_overview.use_material(main.cameras.view_material(false))
		_focus.texture = main.cameras.texture("focus")
		_focus.use_material(main.cameras.view_material(false))
	row = _row()
	_ws_button(row, "1 点戻す", func(): if hw != null: hw.calib_undo())
	_ws_button(row, "全部消す", func(): if hw != null: hw.calib_clear(), "danger")

	# --- 6. the study mode's capture height
	_card("height", "HELP でアームを下ろして撮る高さ。2 の Z の「下」の記録を机として、そこから 10cm 巻き上げた所"
		+ "（爪先が机から 10cm）。2 の上下を記録すれば、そのまま学習モードで使う（保存・確認は要らない）。")
	_height = _value()
	_step("（任意）", "巻き上げドラムの半径が 15mm でなければ、入れて「保存」")
	row = _row()
	_drum = _spin(row, "巻き上げドラムの半径 mm", 3.0, 100.0, 0.5, 15.0)
	_ws_button(row, "保存（机 = Z の下の記録）", func(): save_height("bottom"), "primary")
	_ws_button(row, "ここを机に記録して保存", func(): save_height("here"))
	_step("（任意）", "「10cm へ動かす（試す）」で高さを見る")
	row = _row()
	_ws_button(row, "10cm へ動かす（試す）", func(): try_height(StudyServices.stage_names()[0]), "primary")

	# --- 7. the arm-tip camera's calibration (#242)
	_card("focus", "HELP で「〇ばんが わからない」と言われたとき、先端カメラの画像を見てアームを問題の真上へ動かすための校正。"
		+ "アームを 1cm ずつ動かして、先端カメラの画像がどれだけずれるかを測る。2 の Z と原点復帰、6 の高さのあとで。")
	_focus_label = _value()
	_focus_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_focus_label.custom_minimum_size = Vector2(WIDTH, 0)
	_step("①", "文字の書いてあるプリントをステージに置き、動かないようにする")
	_step("②", "6 の「10cm へ動かす（試す）」でアームを撮影の高さへ。矢印キーでプリントの真上へ（先端カメラに文字が写る所）")
	_step("③", "「先端カメラを校正する」: アームが前後左右に 1cm ずつ動いて撮り、もとの位置へ戻る（30 秒ほど）")
	_caution("校正の間はプリントや手を動かさない。Space でいつでも止まる。")
	row = _row()
	_ws_button(row, "先端カメラを校正する", func(): start_focus_calibration(), "primary")

	# --- 8. the AI / outside services
	_card("services", "学習モードで使う外部のサービスにつながるか（開くと自動で確かめる。推論・課金はしない）。"
		+ "「AI に試しに質問する」は、サンプルのプリント 1 枚と短い質問を解説の AI に 1 回だけ送る。")
	_services = _value()
	_services.visible = false
	_services_box = VBoxContainer.new()
	_box.add_child(_services_box)
	var srow := _row()
	_ws_button(srow, "もう一度確かめる", func(): check_services(false))
	_ws_button(srow, "AI に試しに質問する", func(): check_services(true))

	_box = self

## How each section is (#120): [{key, title, state: ok|todo|wait|na, text}], in order.
func section_states() -> Array[Dictionary]:
	var ready := backend_ready()
	var out: Array[Dictionary] = []
	for sec in SECTIONS:
		var key: String = sec[0]
		var st := "todo"
		var text := ""
		if RobotState.source != "websocket" and key not in ["link", "claw"]:
			out.append({"key": key, "title": str(sec[1]), "state": "na", "text": "バックエンドが要る（./start.sh）"})
			continue
		match key:
			"link":
				var ls := link_state(RobotState.source, ready, RobotState.connected, RobotState.motors_enabled,
					str(main.ws.server_robot) if main != null and main.get("ws") != null else "", link_info)
				st = ls.state
				text = ls.text
			"z":
				var ref: bool = RobotState.z_top_set or RobotState.z_reference_set
				if RobotState.z_calibrated and ref:
					var es := easy_state(easy_status)
					if not RobotState.homed:
						text = "上下は記録済み。一番上で「原点復帰」"
					elif es.state in ["todo", "wait"]:
						st = "todo" if es.state == "todo" else "wait"
						text = "自動で動く場所: " + str(es.text)  # #299: the portal and the release height
					else:
						st = "ok"
						text = "上下を記録・原点復帰も済み" + ("・ポータルと投入の高さも記録済み" if es.state == "ok" else "")
				elif RobotState.z_calibrated:
					text = "電源を入れ直した: 「前回の上下を呼び出す」"
				else:
					text = "まだ測っていない: 上と下を記録"
			"claw":
				if not is_nan(RobotState.arm_open_deg) and not is_nan(RobotState.arm_closed_deg):
					st = "ok"
					text = "開き・閉じを記録済み"
				else:
					text = "開き・閉じを記録する"
			"spot":
				if hw == null:
					st = "na"
					text = "宿題の見守りがない"
				elif hw.approach.get("spot") is Dictionary:
					st = "ok"
					text = "記録済み"
				else:
					text = "まだ記録していない"
			"camera":
				if hw == null:
					st = "na"
					text = "宿題の見守りがない"
				elif hw.calibration_usable():
					st = "ok"
					text = hw.calib_summary()
				else:
					text = hw.calib_summary()
			"height":
				if bool(height_status.get("usable", false)):
					st = "ok"
					text = "使う（Z の下 + 10cm）"
				elif height_status.is_empty():
					st = "wait"
					text = "問い合わせ中"
				elif not bool(height_status.get("z_calibrated", true)):
					text = "2 の Z の上と下を記録すると使える"
				else:
					text = "使えない: " + str(height_status.get("problem", ""))
			"focus":
				var fs := focus_state(focus_status, focus_cal)
				st = fs.state
				text = fs.text
			"services":
				if services.is_empty():
					st = "wait"
					text = "確かめています…" if _services_asking else "バックエンドにつながると確かめる"
				else:
					var ng: Array[String] = []
					for r in services:
						if r is Dictionary and str(r.get("status", "")) == "ng":
							ng.append(str(r.get("label", r.get("name", ""))))
					if ng.is_empty():
						st = "ok"
						text = "つながる"
					else:
						text = "つながらない: " + "、".join(ng)
		out.append({"key": key, "title": str(sec[1]), "state": st, "text": text})
	return out

## The easy mode's portal and release height (#169, #299) from the backend's easy_status: part of
## the "Z の上下と原点復帰" section. The simulated crane uses made-up values (nothing to record).
## #299: what is recorded is used (no confirmation step); the catch height is the Z bottom.
static func easy_state(st: Dictionary) -> Dictionary:
	if st.is_empty():
		return {"state": "wait", "text": "問い合わせ中"}
	var d: Dictionary = st.dials if st.get("dials") is Dictionary else {}
	if str(d.get("profile", "")) != "real":
		return {"state": "na", "text": "仮想クレーンは模擬の値を使う（記録は実機でだけ）"}
	var missing: Array[String] = []
	for k in EASY_VALUES:
		if d.get(k[0]) == null:
			missing.append(str(k[1]))
	if not missing.is_empty():
		return {"state": "todo", "text": "まだ: " + "、".join(missing)}
	if bool(d.get("stale_z", false)):
		return {"state": "todo", "text": "Z を測り直した: 投入の高さを記録し直す"}
	var problems: Array = st.problems if st.get("problems") is Array else []
	if not problems.is_empty():
		return {"state": "todo", "text": "まだ動かせない: " + str(problems[0])}
	return {"state": "ok", "text": "記録済み（次の起動でもこの値を使う）"}

## the easy mode's recorded values (#200: Dial 1 only; #299: the catch height is the Z bottom):
## key in easy_status.dials, its name
const EASY_VALUES := [["dial_1", "ポータルの XY"], ["release_z", "投入の高さ"]]

static func easy_text(st: Dictionary) -> String:
	var d: Dictionary = st.dials if st.get("dials") is Dictionary else {}
	if d.is_empty():
		return "（バックエンドに問い合わせ中）"
	var xy := func(v) -> String: return "X %.0f / Y %.0f" % [float(v[0]), float(v[1])] if v is Array and v.size() == 2 else "まだ"
	if str(d.get("profile", "")) != "real":
		return "仮想クレーン: 模擬の値を使う（ポータル %s　投入 Z %.0f）" % [xy.call(d.get("dial_1")),
			float(d.release_z) if d.get("release_z") != null else 0.0]
	var z := func(v) -> String: return ("Z %.1f" % float(v)) if v != null else "まだ"
	var when := str(d.get("saved_at", "")).replace("T", " ")
	return "ポータル（左の Dial 1）: %s　投入の高さ: %s　キャッチの高さ: %s\n%s→ %s" % [
		xy.call(d.get("dial_1")), z.call(d.get("release_z")),
		("下（%s）" % z.call(d.get("catch_z"))) if d.get("catch_z") != null else "下（Z の下を記録してから）",
		("%s に記録した値　" % when) if when != "" else "", str(easy_state(st).text)]

## The first section not done, in words ("" when all are).
static func next_text(states: Array) -> String:
	for i in states.size():
		var s: Dictionary = states[i]
		if s.state in ["todo", "wait"]:
			return "次にやること → %d. %s: %s" % [i + 1, s.title, s.text]
	return "すべて済み。閉じる（Esc）とタイトルへ"

static func mark(state: String) -> String:
	return {"ok": "✓", "todo": "✗", "wait": "…", "na": "－"}.get(state, "－")

static func state_colour(state: String) -> Color:
	return {"ok": GOOD, "todo": BAD, "wait": YELLOW}.get(state, MUTED)

static func badge_text(state: String) -> String:
	return {"ok": "済", "todo": "まだ", "wait": "確認待ち", "na": "使えない"}.get(state, "")

## Scroll the tab so that section's card is at the top (the summary's rows).
func scroll_to(key: String) -> void:
	if not _cards.has(key):
		return
	var card: Control = _cards[key].card
	var p := get_parent()
	if p is ScrollContainer:
		(p as ScrollContainer).scroll_vertical = int(card.position.y)

func _spin(parent: Control, label: String, lo: float, hi: float, step: float, v: float) -> SpinBox:
	return PanelKit.spin(parent, label, lo, hi, step, v)

## #110: the entered values -> the backend (calibration.json#study_height), unconfirmed.
## desk: "bottom" = the Z calibration's bottom, "here" = the arm's Z now.
## #242: the arm-tip camera's calibration at the first capture height (6's "10cm").
func start_focus_calibration() -> void:
	focus_cal.capture = func() -> Image:
		var cams: CameraHub = main.cameras if main != null else null
		return cams.texture("focus").get_image() if cams != null and cams.has_feed("focus") else null
	focus_cal.send = func(name: String, params: Dictionary) -> String: return main.ws.send_command(name, params)
	focus_cal.log_line = func(line: String) -> void: main.debug_log.emit(line)
	var stage: String = StudyServices.stage_names()[0]
	var why := focus_height_blocker(RobotState.z_mm, stage_z(stage), stage)
	if why == "":
		why = focus_cal.start(stage)
	if why != "":
		_set_result(false, "先端カメラの校正を始められない: " + why)
	else:
		_set_result(true, focus_cal.progress_text())

## Every frame while the tab shows (settings_screen.gd); the run stops when the tab hides.
func tick(dt: float) -> void:
	if not focus_cal.active():
		return
	if not backend_ready():
		focus_cal.cancel("バックエンドとの接続が切れた")
	else:
		focus_cal.tick(dt)
	if focus_cal.state != FocusCalibrator.COMPUTING or result_text == "":
		_set_result(focus_cal.state != FocusCalibrator.FAILED, focus_cal.progress_text())

## Space (main.gd stop_key): the run ends (soft_stop stops the arm).
func on_stop_key() -> void:
	if focus_cal.active():
		focus_cal.cancel("Space で止めました")
		_set_result(false, focus_cal.progress_text())

## The calibration is for HELP's capture height: the arm must be there (Z within 2 units).
static func focus_height_blocker(z: float, stage_at: float, stage: String) -> String:
	if is_nan(stage_at):
		return "6 の撮影の高さがまだ使えない（2 の Z の上と下を記録する）"
	if is_nan(z) or absf(z - stage_at) > 2.0:
		return "先に 6 の「%s へ動かす（試す）」でアームを撮影の高さへ（いま Z %.0f、%s は Z %.0f）" % [stage, z, stage, stage_at]
	return ""

## The arm-tip camera's calibration in words: {state, text}.
static func focus_state(st: Dictionary, cal: FocusCalibrator) -> Dictionary:
	if cal != null and cal.active():
		return {"state": "wait", "text": "校正中"}
	if cal != null and cal.state == FocusCalibrator.FAILED and not (st.get("heights") is Dictionary
			and (st.heights as Dictionary).has(StudyServices.stage_names()[0])):
		return {"state": "todo", "text": "できなかった: " + cal.error}
	if st.is_empty():
		return {"state": "wait", "text": "問い合わせ中"}
	var heights: Dictionary = st.heights if st.get("heights") is Dictionary else {}
	var stage := StudyServices.stage_names()[0]
	if heights.get(stage) is Dictionary:
		var h: Dictionary = heights[stage]
		return {"state": "ok", "text": "%s で校正済み（1 mm = %.1f px）" % [stage, float(h.get("px_per_mm", 0.0) if h.get("px_per_mm") != null else 0.0)]}
	return {"state": "todo", "text": "まだ: HELP でアームが問題を見に行けない"}

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

## #126: the Z of the recorded top / bottom (the backend counts Z from them: top = the
## upper end of the range, bottom = the lower one).
static func z_end(which: String) -> float:
	var r := GameConfig.robot()
	var top: float = r.z_max_mm if r.z_up_is_positive else r.z_min_mm
	var bottom: float = r.z_min_mm if r.z_up_is_positive else r.z_max_mm
	return top if which == "top" else bottom

## Both Z points recorded this session: 上げる / 下げる can go there.
static func z_range_recorded() -> bool:
	return RobotState.z_top_set and RobotState.z_bottom_set

## 上げる / 下げる (#126): move_z to the recorded top / bottom (the backend checks the rest).
func move_z_to(which: String) -> void:
	if not z_range_recorded():
		_set_result(false, "Z の上と下を両方記録してから")
		return
	main.ws.send_command("move_z", {"z": z_end(which)})

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
		lines.append("2 の Z の上下をまだ測っていない（1cm あたりの Z を計算できない）")
	if bool(st.get("z_changed", false)):
		lines.append("Z を測り直したので、記録した机の Z は使えない:「保存（机 = Z の下の記録）」か「ここを机に記録して保存」をやり直す")
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
		lines.append("学習モードで使う（Z の下 + 10cm）")
	elif st.has("trial_problem"):
		lines.append("このままでは使えない: " + str(st.trial_problem))
	elif str(st.get("problem", "")) != "":
		lines.append("このままでは使えない: " + str(st.problem))
	return "\n".join(lines)

func _card_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", card_style())
	return p

## A card's frame (#120; the settings tab's sections use it too, #126).
static func card_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = CARD_BG
	sb.border_color = CARD_BORDER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 12
	sb.content_margin_bottom = 14
	return sb

func _card_box(p: PanelContainer) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	p.add_child(v)
	return v

## A section's card: number and title, its state badge, what it is for. Rows added after go in it.
func _card(key: String, purpose: String) -> void:
	var idx := 0
	var title := key
	for i in SECTIONS.size():
		if SECTIONS[i][0] == key:
			idx = i + 1
			title = SECTIONS[i][1]
	var p := _card_panel()
	add_child(p)
	_box = _card_box(p)
	var h := HBoxContainer.new()
	_box.add_child(h)
	var t := StudyHud.label("%d. %s" % [idx, title], 24, CYAN, 4)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(t)
	var bp := PanelContainer.new()
	var bs := StyleBoxFlat.new()
	bs.set_corner_radius_all(12)
	bs.content_margin_left = 12
	bs.content_margin_right = 12
	bs.content_margin_top = 2
	bs.content_margin_bottom = 2
	bp.add_theme_stylebox_override("panel", bs)
	bp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var badge := StudyHud.label("", 16, Color("10182c"))
	bp.add_child(badge)
	h.add_child(bp)
	_cards[key] = {"card": p, "badge": badge, "badge_bg": bs}
	_note(purpose)

func _note(text: String) -> void:
	PanelKit.wrapped(_box, text, 16, MUTED, 2, WIDTH)

## A small heading inside a card ("いつもは", "最後に").
func _sub(text: String) -> void:
	var l := StudyHud.label(text, 17, Color("b8c8ea"), 2)
	_box.add_child(l)

## One step: its mark (①) and what to do.
func _step(n: String, text: String) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	_box.add_child(h)
	h.add_child(StudyHud.label(n, 18, YELLOW, 2))
	PanelKit.wrapped(h, text, 17, INK, 2, WIDTH - 30)

func _caution(text: String) -> void:
	PanelKit.wrapped(_box, "⚠ " + text, 15, Color("ffc87a"), 2, WIDTH)

func _value() -> Label:
	return PanelKit.wrapped(_box, "", 18, Color.WHITE, 3, WIDTH)

func _row() -> HBoxContainer:
	return PanelKit.row(_box)

## kind: "" (plain), "primary" (the step's main button), "danger" (it erases a record).
func _button(parent: Control, text: String, cb: Callable, kind := "") -> Button:
	var b := PanelKit.button(text, 18, cb)
	if kind != "":
		var col := Color("2f6fb3") if kind == "primary" else Color("6a2a35")
		for st in ["normal", "hover", "pressed", "disabled"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = col.lightened(0.15) if st == "hover" else (col.darkened(0.2) if st == "pressed" else col)
			if st == "disabled":
				sb.bg_color = col.darkened(0.55)
			sb.set_corner_radius_all(6)
			sb.content_margin_left = 12
			sb.content_margin_right = 12
			sb.content_margin_top = 4
			sb.content_margin_bottom = 4
			b.add_theme_stylebox_override(st, sb)
		b.add_theme_color_override("font_color", Color.WHITE)
		b.add_theme_color_override("font_hover_color", Color.WHITE)
		b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.35))
	parent.add_child(b)
	return b

## The first section's row in the summary (#124: a real robot that is not connected is a
## problem of the link, never "done").
static func link_state(source: String, ready: bool, connected: bool, motors: bool, server_robot: String,
		info: Dictionary) -> Dictionary:
	if source != "websocket":
		return {"state": "todo", "text": "バックエンドなし（./start.sh で起動する）"}
	if not ready:
		return {"state": "todo", "text": "バックエンドにつながっていない"}
	if not connected:
		return {"state": "todo", "text": link_problem_text(info, true)}
	if not motors:
		return {"state": "todo", "text": "モーターが無効:「モーター有効」を押す"}
	return {"state": "ok", "text": "実機" if server_robot == "real" else "仮想クレーン"}

## Why the robot is not connected, in words (#124), from the backend's list_ports answer
## (its "robot"). short: the summary's one line; otherwise with what to do about it.
static func link_problem_text(info: Dictionary, short := false) -> String:
	var problem := str(info.get("problem", ""))
	var reg: Array = info.registered if info.get("registered") is Array else []
	var others: Array = info.others if info.get("others") is Array else []
	var err := str(info.get("error", ""))
	var again := "直したら ./start.sh を起動し直す（ポートは起動のときだけ開く）"
	match problem:
		"port_missing":
			if short:
				return "実機に未接続: 登録したポートが見つからない"
			var s := "実機に未接続: 登録したシリアルポート（%s）が見つからない。" % "、".join(reg)
			if others.is_empty():
				s += "USB ケーブルと基板の電源を確かめる。"
			else:
				s += "いま見えているポート: %s。それがロボットの基板（Core2）なら、「設定」タブの「シリアルポート 2 台目」に登録する（周辺機器のハブのポートは登録しない）。" % "、".join(others)
			return s + again
		"no_port":
			if short:
				return "実機に未接続: シリアルポートが見つからない"
			return "実機に未接続: シリアルポートが 1 つも見つからない。USB ケーブルと基板の電源を確かめる。" + again
		"silent":  # #161: the link stopped answering while running; the backend reopens it
			if short:
				return "実機から返事が来ない: つなぎ直しています"
			return ("実機から返事が来なくなった（ポート %s）。USB ハブかケーブルの不調で、実機からの受信だけが止まることがある。"
				+ "バックエンドが数秒おきに自動でつなぎ直している。続くなら Core2 の USB をカメラと同じハブから外し、Mac に直接挿す。"
				+ "つながったら「モーター有効」からやり直す（Z の上下の記録も消えている）") % str(info.get("port", ""))
		"open_failed":
			if short:
				return "実機に未接続: ポートを開けない・返事がない"
			return "実機に未接続: ポート %s はあるが、つながらない%s。ほかのプログラム（シリアルモニターなど）が使っていないか、基板の電源を確かめる。%s" % [
				str(info.get("port", "")), ("（%s）" % err) if err != "" else "", again]
	return "実機に未接続（シリアルを確かめています…）" if short else \
		"実機に未接続（バックエンドがシリアルを確かめています…）"

func _ws_button(parent: Control, text: String, cb: Callable, kind := "") -> Button:
	var b := _button(parent, text, cb, kind)
	_ws_buttons.append(b)
	return b

## A calibration command answered (ack / nack): kept for the screen while the tab shows.
func _on_ack(_rid: String, ok: bool, data: Dictionary) -> void:
	var cmd := str(data.get("command", ""))
	if cmd == "services_check":
		_services_asking = false
		if ok and data.get("results") is Array:
			# an "ask" run adds its lines (the question, and the worksheet reader #230) to the last check
			var asked: Array = (data.results as Array).filter(func(r): return r is Dictionary and r.get("name") in ASK_ROWS)
			if asked.is_empty() or services.is_empty():
				services = data.results
			else:
				services = services.filter(func(r): return r is Dictionary and not r.get("name") in ASK_ROWS) + asked
		elif not ok:
			services = [{"name": "backend", "label": "バックエンド", "status": "ng", "detail": str(data.get("reason", ""))}]
		return
	if cmd == "list_ports":  # #124: asked while the robot is not connected: no message
		if ok and data.get("robot") is Dictionary:
			link_info = data.robot
		return
	if cmd == "study_height_status":  # asked when the tab opens: no message
		if ok:
			show_heights(data)
		return
	if cmd == "focus_status":  # asked when the tab opens: no message
		if ok:
			focus_status = data
		return
	focus_cal.on_ack(_rid, ok, data)
	if cmd == "focus_calibrate":
		if main != null and main.get("ws") != null:
			main.ws.send_command("focus_status")
		_set_result(ok, focus_cal.progress_text() if focus_cal.state in [FocusCalibrator.DONE, FocusCalibrator.FAILED]
			else ("先端カメラの校正: " + reason_text(str(data.get("reason", "")))))
		return
	if cmd == "easy_status":  # asked when the tab opens: no message
		if ok:
			easy_status = data
		return
	if ok and cmd in ["z_set", "z_restore", "calibration_prepare"] and main != null and main.get("ws") != null \
			and is_visible_in_tree():  # (only while the tab shows: it asks again when it opens)
		main.ws.send_command("easy_status")  # the easy mode's heights follow the Z calibration
	if ok and cmd == "easy_dial_set":
		easy_status = data
	if not COMMANDS.has(cmd) or not is_visible_in_tree():
		return
	if ok and cmd in ["study_height_set", "study_height_confirm"]:
		show_heights(data)
	if ok and cmd in ["z_set", "z_restore"] and main != null and main.get("ws") != null:
		main.ws.send_command("study_height_status")  # #165: the heights follow the Z records
	result_ok = ok
	result_text = ("%s: できました" % COMMANDS[cmd]) if ok else \
		("%s は断られました: %s" % [COMMANDS[cmd], reason_text(str(data.get("reason", "")))])
	if cmd == "calibration_prepare" and ok:
		result_text = "準備を始めた（進み具合は上の「準備のようす」に出る）"
	if cmd == "clear_alarm" and ok:
		result_text = "アラームを解除しました（次は原点復帰）"
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

## #163: what to do when the firmware refuses a servo's jogs until its power is cut and
## restored ("" when none is refused).
static func servo_power_cycle_text(z: bool, arm: bool) -> String:
	if not z and not arm:
		return ""
	var which := "巻き上げサーボと爪のサーボ" if z and arm else ("巻き上げサーボ" if z else "爪のサーボ")
	var s := ("⚠ %sが動かない: Core2 だけが再起動して、サーボの回転数が分からなくなった（ファームウェアが拒否している）。"
		+ "サーボの電源（Core2 の USB ではない）を一度切って入れ直す。") % which
	if z:
		s += "トルクが切れているので、アームが重みで下がることがある（下に物がないか確かめる）。入れ直したら Z の上と下を記録し直す"
	else:
		s += "入れ直したら爪の開き・閉じを確かめる"
	return s

## #167: the preparation's steps and, when it stopped, why ("" before the first run).
static func prepare_text(st: Dictionary) -> String:
	var steps: Array = st.get("steps", []) if st.get("steps") is Array else []
	if steps.is_empty():
		return ""
	var marks := {"done": "✓", "skip": "－", "run": "…", "fail": "✗", "todo": "・"}
	var lines: Array[String] = []
	for s in steps:
		if not s is Dictionary:
			continue
		var note := str(s.get("note", ""))
		lines.append("%s %s%s" % [marks.get(str(s.get("state", "todo")), "・"), str(s.get("label", s.get("key", ""))),
			("（%s）" % note) if note != "" else ""])
	var text := "　".join(lines)
	if bool(st.get("active", false)):
		return "実行中: " + text
	if str(st.get("last_result", "")) == "done":
		return "準備できた: " + text
	if str(st.get("last_result", "")) == "fault":
		return "止まった: " + text + "\n理由: " + reason_text(str(st.get("error", "")))
	return text

## A refusal's reason as what to do next (the backend's own words when it is not known).
static func reason_text(reason: String) -> String:
	var r := reason.to_lower()
	if r.contains("wind the arm up") or r.contains("not wound up"):
		return "先に W でアームを一番上まで巻き上げる（Z の上を記録してから原点復帰）。" + reason
	if r == "timeout":
		return "バックエンドから返事がない"
	if r.contains("no reply from the robot") or r.begins_with("timeout after") \
			or r.begins_with("internal error: timeout after"):
		# #161: the firmware did not answer (a USB hub / cable trouble can stop the replies alone)
		return "実機から返事がない（USB ケーブル・ハブを確認。止まったままならバックエンドが数秒でつなぎ直す）。" + reason
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
	main.ws.send_command("easy_status")
	main.ws.send_command("focus_status")
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
			lines.append("%s %s: %s" % [mark, str(r.get("label", r.get("name", ""))), short_detail(str(r.get("detail", "")))])
	if asking:
		lines.append("（確かめています…）")
	return "\n".join(lines)

## A check's detail without file paths (#120: "2.1.325 (Claude Code)（/Users/.../claude）" -> "2.1.325 (Claude Code)").
static func short_detail(d: String) -> String:
	var re := RegEx.create_from_string("[（(][^（）()]*[/\\\\][^（）()]*[）)]")
	return re.sub(d, "", true).strip_edges()

func backend_ready() -> bool:
	return main != null and RobotState.source == "websocket" and main.ws.enabled and main.ws.is_open()

static func deg_text(v: float) -> String:
	return "未記録" if is_nan(v) else "%.1f°" % v

func refresh() -> void:
	var ready := backend_ready()
	_refresh_summary()
	for b in _ws_buttons:
		b.disabled = not ready
	var prep := RobotState.calibration_prepare if RobotState.source == "websocket" else {}
	_prepare.disabled = not ready or bool(prep.get("active", false))
	if _prep_was_active and not bool(prep.get("active", false)) and ready:
		main.ws.send_command("easy_status")  # the preparation ended: Z is back, the easy mode's values count again
	_prep_was_active = bool(prep.get("active", false))
	_prepare_label.text = prepare_text(prep)
	_prepare_label.add_theme_color_override("font_color", BAD if str(prep.get("last_result", "")) == "fault"
		else (GOOD if str(prep.get("last_result", "")) == "done" else MUTED))
	if ready and not _asked and is_visible_in_tree():
		_ask_backend()
	if RobotState.connected or not ready:
		link_info = {}
		_link_asked_ms = -100000
	elif is_visible_in_tree() and Time.get_ticks_msec() - _link_asked_ms >= LINK_ASK_MS:
		_link_asked_ms = Time.get_ticks_msec()
		main.ws.send_command("list_ports")  # read only: the ports and why the robot's is not open
	_services.text = services_text(services, _services_asking)
	if _services.text != _services_shown:  # one line per check, coloured by its own result
		_services_shown = _services.text
		for c in _services_box.get_children():
			c.queue_free()
		var lines := _services.text.split("\n")
		for line in lines:
			var l := StudyHud.label(line, 17, YELLOW, 2)
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size = Vector2(WIDTH, 0)
			var colour: Color = GOOD if line.begins_with("✓") else (BAD if line.begins_with("✗") else (MUTED if line.begins_with("－") else YELLOW))
			l.add_theme_color_override("font_color", colour)
			_services_box.add_child(l)
	_height.text = height_text(height_status)
	_focus_label.text = focus_cal.progress_text() if focus_cal.active() or focus_cal.state == FocusCalibrator.FAILED \
		else focus_state(focus_status, focus_cal).text
	_height.add_theme_color_override("font_color", GOOD if bool(height_status.get("usable", false)) else YELLOW)
	if RobotState.source != "websocket":
		_link.text = "ゲーム内の仮想クレーン（バックエンドなし）: 爪だけ試せる。Z・宿題の位置・カメラの校正には ./start.sh で起動する"
	elif not ready:
		_link.text = "バックエンドにつながっていない"
	elif not RobotState.connected:
		_link.text = link_problem_text(link_info)
	else:
		var what := "実機" if str(main.ws.server_robot) == "real" else "仮想クレーン（バックエンドの Mock）"
		_link.text = "%s　モーター: %s　原点: %s　状態: %s%s" % [what,
			"有効" if RobotState.motors_enabled else "無効（動かすには「モーター有効」）",
			"済" if RobotState.homed else "まだ", RobotState.machine_state,
			("　" + RobotState.robot_error) if RobotState.robot_error != "" else ""]
	_link.add_theme_color_override("font_color", BAD if ready and not RobotState.connected
		else (GOOD if ready and RobotState.motors_enabled else YELLOW))
	_z.text = "上: %s　下: %s　換算: %s" % ["記録済" if RobotState.z_top_set or RobotState.z_reference_set else "まだ",
		"記録済" if RobotState.z_bottom_set else "まだ",
		"測った値（calibration.json）" if RobotState.z_calibrated else "設定ファイルの仮の値（まだ測っていない）"]
	var power_cycle := servo_power_cycle_text(RobotState.z_servo_power_cycle, RobotState.arm_servo_power_cycle) \
		if RobotState.source == "websocket" and RobotState.connected else ""
	if power_cycle != "":
		_z.text += "\n" + power_cycle
	_z.add_theme_color_override("font_color", GOOD if RobotState.z_calibrated and power_cycle == "" else BAD)
	_z_use.disabled = not ready or restore_estimate.is_empty()
	_z_up.disabled = not ready or not z_range_recorded()
	_z_down.disabled = _z_up.disabled
	_z_up.tooltip_text = "" if z_range_recorded() else "Z の上と下を両方記録すると押せる"
	_z_down.tooltip_text = _z_up.tooltip_text
	_z_restore.add_theme_color_override("font_color", YELLOW)
	_easy.text = easy_text(easy_status)
	_easy.add_theme_color_override("font_color", GOOD if easy_state(easy_status).state == "ok" else
		(MUTED if easy_state(easy_status).state in ["na", "wait"] else BAD))
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

## The summary rows, the next thing to do and each card's badge (#120).
func _refresh_summary() -> void:
	var states := section_states()
	var sig := str(states)
	if sig == _summary_shown:
		return
	_summary_shown = sig
	for i in states.size():
		var stt: Dictionary = states[i]
		var b: Button = _summary.get(stt.key)
		if b != null:
			b.text = "%s %d. %s — %s" % [mark(stt.state), i + 1, stt.title, stt.text]
			b.tooltip_text = b.text
			var c := state_colour(stt.state)
			b.add_theme_color_override("font_color", c)
			b.add_theme_color_override("font_hover_color", c.lightened(0.25))
			b.add_theme_color_override("font_pressed_color", c.lightened(0.25))
		if _cards.has(stt.key):
			var card: Dictionary = _cards[stt.key]
			(card.badge as Label).text = badge_text(stt.state)
			(card.badge_bg as StyleBoxFlat).bg_color = state_colour(stt.state)
	_next.text = next_text(states)
	_next.add_theme_color_override("font_color", GOOD if _next.text.begins_with("すべて") else YELLOW)

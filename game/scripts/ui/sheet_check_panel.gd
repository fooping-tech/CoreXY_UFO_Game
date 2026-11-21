class_name SheetCheckPanel
extends VBoxContainer
## The settings screen's プリント tab (#230): try the learning support AI's worksheet reader
## (POST /v1/sheet) with a connected camera (the overview or the arm camera).
##
## The frame is put right here before it is sent: the part with the worksheet is cut out (a
## rectangle dragged on the live view, per camera) and turned upright (0 / 90 / 180 / 270°, per
## camera); both are kept in user://sheet_check.cfg (SheetFrame), and the study mode's overview frames
## use them too (#232). What was sent is shown with the answer drawn
## over it (each problem's box and answer box, coloured by the answer's state), the list below,
## and the server's answer as JSON. The whole frame (with the rectangle) can be shown again.
## Never the crane: no RobotState, no robot command. Nothing is saved but the two settings.

const YELLOW := PanelKit.YELLOW
const CYAN := PanelKit.CYAN
const MUTED := PanelKit.MUTED
const BAD := PanelKit.BAD
const GOOD := PanelKit.GOOD
const WIDTH := 630.0
const VIEW_H := 470.0
const IMAGE_EDGE := 1600  # the server shrinks to ~0.65 MP: more does not help
const IMAGE_BYTES := 600000  # the main link's send buffer (and the backend's 1 MiB message)
const WAIT_S := 200.0  # ~10 s a sheet; up to 3 x 503 waits and the backend's 180 s
const SETTINGS_PATH := SheetFrame.SETTINGS_PATH
const CAMERAS := [["overview", "俯瞰カメラ"], ["focus", "アームのカメラ"]]
const ROTATIONS := [[0, "そのまま"], [180, "上下反転（180°）"], [90, "右に 90°"], [270, "左に 90°"]]
const STATUS_NAMES := {"correct": "正解", "incorrect": "まちがい", "blank": "空白", "partial": "書きかけ",
	"unreadable": "読めない"}
const STATUS_MARKS := {"correct": "○", "incorrect": "×", "blank": "□", "partial": "△", "unreadable": "？"}
const STATUS_COLORS := {"correct": Color("6be37a"), "incorrect": Color("ff5c5c"), "blank": Color("5cb8ff"),
	"partial": Color("ffb03c"), "unreadable": Color("b0b0b0")}

var main: Node
var role := "overview"
var crop := true  # the server's own paper crop (it finds the paper's outline in what we send)
var calc := true
## per camera: the turn (degrees clockwise) and the part sent (0..1 of the frame; no area = all)
var rotations := {}
var regions := {}
var settings_path := SETTINGS_PATH  # "" = remember nothing (tests)
## what the view shows: "live", "sent" (what was sent, with the answer) or "frame" (the whole frame)
var view_mode := "live"
var frame: Image  # the camera frame taken
var sent: Image  # the part of it sent, turned upright
var sent_bytes := 0
var sending := false  # false = only a look at what would be sent
## the last answer (sheet_read's ack data)
var result: Dictionary = {}
var result_text := ""
var result_ok := true
var _rid := ""
var _wait := 0.0
var _picking := false
var _drag_from := Vector2(-1, -1)
var _drag_to := Vector2(-1, -1)
var _camera_buttons: Dictionary = {}  # role -> Button
var _rotation: OptionButton
var _pick_b: Button
var _clear_b: Button
var _region_label: Label
var _read_b: Button
var _look_b: Button
var _live_b: Button
var _sent_b: Button
var _frame_b: Button
var _camera_state: Label
var _view_label: Label
var _holder: Control
var _view: TextureRect
var _overlay: Control
var _summary: Label
var _list: Label
var _json: TextEdit

func setup(m: Node) -> void:
	main = m
	add_theme_constant_override("separation", 8)
	_load()
	PanelKit.wrapped(self, "学習支援 AI のプリント読み取り（/v1/sheet）を、つないだカメラで試す。送る前に、プリントの部分だけを"
		+ "切り出し、向きをまっすぐにする（どちらもカメラごとに覚える）。「撮って読む」で送り、送った画像に問題ごとの枠と"
		+ "答えの状態を重ね、サーバの返事（JSON）も出す（1 回 約 10 秒）。結果はモデルの推定。アームは動かさない。", 16, MUTED, 2, WIDTH)
	var row := PanelKit.row(self)
	for c in CAMERAS:
		var r: String = c[0]
		var b := PanelKit.button(c[1], 18, func(): pick_camera(r))
		b.toggle_mode = true
		row.add_child(b)
		_camera_buttons[r] = b
	_camera_state = StudyHud.label("", 15, MUTED, 2)
	row.add_child(_camera_state)

	row = PanelKit.row(self)
	row.add_child(StudyHud.label("向き", 17, Color.WHITE, 2))
	_rotation = OptionButton.new()
	_rotation.focus_mode = Control.FOCUS_NONE
	_rotation.add_theme_font_size_override("font_size", 16)
	for r in ROTATIONS:
		_rotation.add_item(r[1], r[0])
	_rotation.item_selected.connect(func(i: int): set_rotation_deg(_rotation.get_item_id(i)))
	row.add_child(_rotation)
	_pick_b = PanelKit.button("送る範囲をドラッグで決める", 16, start_pick)
	row.add_child(_pick_b)
	_clear_b = PanelKit.button("範囲を消す", 16, func(): set_region(Rect2()))
	row.add_child(_clear_b)
	_region_label = PanelKit.wrapped(self, "", 15, MUTED, 2, WIDTH)

	row = PanelKit.row(self)
	for o in [["crop", "サーバでも紙を切り出す（crop）"], ["calc", "式を計算し直す（calc）"]]:
		var key: String = o[0]
		var cb := CheckBox.new()
		cb.text = o[1]
		cb.button_pressed = true
		cb.focus_mode = Control.FOCUS_NONE
		cb.add_theme_font_size_override("font_size", 15)
		cb.toggled.connect(func(on: bool): set(key, on))
		row.add_child(cb)

	row = PanelKit.row(self)
	_read_b = PanelKit.button("撮って読む", 22, read_now)
	_read_b.custom_minimum_size = Vector2(190, 0)
	row.add_child(_read_b)
	_look_b = PanelKit.button("送る画像を見る", 16, look_now)
	row.add_child(_look_b)
	_live_b = PanelKit.button("ライブ", 16, show_live)
	_sent_b = PanelKit.button("送った画像", 16, func(): show_view("sent"))
	_frame_b = PanelKit.button("撮った画像", 16, func(): show_view("frame"))
	for b in [_live_b, _sent_b, _frame_b]:
		b.toggle_mode = true
		row.add_child(b)

	_view_label = PanelKit.wrapped(self, "", 15, CYAN, 2, WIDTH)
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("0b1122")
	sb.border_color = Color("4a5a78")
	sb.set_border_width_all(2)
	box.add_theme_stylebox_override("panel", sb)
	add_child(box)
	_holder = Control.new()
	_holder.custom_minimum_size = Vector2(WIDTH, VIEW_H)
	_holder.clip_contents = true
	_holder.mouse_filter = Control.MOUSE_FILTER_STOP
	_holder.gui_input.connect(_on_view_input)
	box.add_child(_holder)
	_view = TextureRect.new()
	_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_holder.add_child(_view)
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	_holder.add_child(_overlay)

	PanelKit.wrapped(self, "枠の色: 緑 正解・赤 まちがい・青 空白・橙 書きかけ・灰 読めない。細い枠が答えのらん、点線がサーバの切り出した紙。"
		+ "ライブと撮った画像の黄色の枠が送る範囲。", 14, MUTED, 2, WIDTH)
	_summary = PanelKit.wrapped(self, "", 20, YELLOW, 3, WIDTH)
	_list = PanelKit.wrapped(self, "", 17, Color.WHITE, 2, WIDTH)
	row = PanelKit.row(self)
	row.add_child(StudyHud.label("サーバの返事（JSON）", 17, CYAN, 2))
	row.add_child(PanelKit.button("コピー", 15, func(): DisplayServer.clipboard_set(_json.text)))
	_json = TextEdit.new()
	_json.editable = false
	_json.custom_minimum_size = Vector2(WIDTH, 260)
	_json.add_theme_font_size_override("font_size", 13)
	_json.focus_mode = Control.FOCUS_NONE
	add_child(_json)
	if main != null and main.get("ws") != null:
		main.ws.ack.connect(_on_ack)
	pick_camera(role)

# ------------------------------------------------------------------ settings per camera
func rotation_deg(r := role) -> int:
	return int(rotations.get(r, 0))

func region(r := role) -> Rect2:
	var v = regions.get(r, Rect2())
	return v if v is Rect2 else Rect2()

func set_rotation_deg(deg: int) -> void:
	rotations[role] = deg if deg in [0, 90, 180, 270] else 0
	_save()
	refresh()

## The part of the frame sent (0..1 of it); no area = the whole frame.
func set_region(r: Rect2) -> void:
	r = r.abs().intersection(Rect2(0, 0, 1, 1))
	regions[role] = r if r.size.x > 0.02 and r.size.y > 0.02 else Rect2()
	_picking = false
	_drag_from = Vector2(-1, -1)
	_save()
	_overlay.queue_redraw()
	refresh()

func _load() -> void:
	var saved := SheetFrame.load_settings(settings_path)
	for r in saved:
		rotations[r] = int(saved[r].rotation)
		regions[r] = saved[r].region

func _save() -> void:
	var out := {}
	for c in CAMERAS:
		var r: String = c[0]
		out[r] = {"rotation": rotation_deg(r), "region": region(r)}
	SheetFrame.save_settings(out, settings_path)

## The frame -> what is sent (SheetFrame.prepare: the study mode does the same, #232).
static func prepare(img: Image, deg: int, part: Rect2) -> Image:
	return SheetFrame.prepare(img, deg, part)

# ------------------------------------------------------------------ the camera and the view
func backend_ready() -> bool:
	return main != null and RobotState.source == "websocket" and main.ws.enabled and main.ws.is_open()

func _cameras() -> CameraHub:
	return main.get("cameras") if main != null else null

func has_camera(r: String) -> bool:
	var cams := _cameras()
	return cams != null and cams.has_feed(r)

func waiting() -> bool:
	return _rid != ""

## The tab shows: the live frame again unless something taken is on screen.
func opened() -> void:
	if frame == null:
		show_live()
	refresh()

func pick_camera(r: String) -> void:
	if waiting():
		return
	role = r
	for k in _camera_buttons:
		(_camera_buttons[k] as Button).button_pressed = k == r
	show_live()

func show_live() -> void:
	view_mode = "live"
	var cams := _cameras()
	_view.texture = cams.texture(role) if cams != null and has_camera(role) else null
	_overlay.queue_redraw()
	refresh()

func show_view(mode: String) -> void:
	if mode == "sent" and sent != null:
		view_mode = mode
		_view.texture = ImageTexture.create_from_image(sent)
	elif mode == "frame" and frame != null:
		view_mode = mode
		_view.texture = ImageTexture.create_from_image(frame)
	_overlay.queue_redraw()
	refresh()

func start_pick() -> void:
	if view_mode == "sent":
		show_live()
	_picking = true
	_drag_from = Vector2(-1, -1)
	refresh()

## The image the view shows, as shown (kept aspect, centred).
func _shown() -> Rect2:
	if _view.texture == null:
		return Rect2()
	return frame_rect(Vector2(_view.texture.get_size()), _holder.size)

func _on_view_input(ev: InputEvent) -> void:
	if not _picking or view_mode == "sent":
		return
	var shown := _shown()
	if not shown.has_area():
		return
	var mb := ev as InputEventMouseButton
	var mm := ev as InputEventMouseMotion
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		var at: Vector2 = ((mb.position - shown.position) / shown.size).clamp(Vector2.ZERO, Vector2.ONE)
		if mb.pressed:
			_drag_from = at
			_drag_to = at
		elif _drag_from.x >= 0.0:
			set_region(Rect2(_drag_from, at - _drag_from))
		_overlay.queue_redraw()
	elif mm != null and _drag_from.x >= 0.0:
		_drag_to = ((mm.position - shown.position) / shown.size).clamp(Vector2.ZERO, Vector2.ONE)
		_overlay.queue_redraw()

# ------------------------------------------------------------------ taking and sending
## A frame of the chosen camera, cut out and turned upright: shown, not sent.
func look_now() -> void:
	_take(false)

## A frame of the chosen camera, cut out and turned upright -> sheet_read.
func read_now() -> void:
	_take(true)

func _take(send: bool) -> void:
	if waiting():
		return
	if send and not backend_ready():
		_result(false, "バックエンドにつながっていない（./start.sh で起動する）")
		return
	if not has_camera(role):
		_result(false, "%sがつながっていない（デバッグパネルのカメラの選択を確かめる）" % _camera_name(role))
		return
	var img := _cameras().texture(role).get_image()
	if img == null or img.is_empty():
		_result(false, "カメラの画像を取れなかった")
		return
	img.convert(Image.FORMAT_RGB8)
	take_frame(img, send)

## The frame taken (also the tests' entry): prepared, shown, and sent when `send`.
func take_frame(img: Image, send: bool) -> void:
	var out := prepare(img, rotation_deg(), region())
	var jpeg := StudyClient.encode_jpeg(out, IMAGE_EDGE, IMAGE_BYTES)
	if jpeg.is_empty():
		_result(false, "画像を %d KB 以下の JPEG にできなかった" % (IMAGE_BYTES / 1000))
		return
	if send:
		var rid: String = main.ws.send_command("sheet_read",
			{"image_jpeg_base64": Marshalls.raw_to_base64(jpeg), "crop": crop, "calc": calc})
		if main.ws.last_send_error != OK:
			main.ws.forget(rid)
			_result(false, "送れなかった（WebSocket error %d、%d KB）" % [main.ws.last_send_error, jpeg.size() / 1000])
			return
		_rid = rid
		_wait = WAIT_S
	frame = img
	# what the server gets, exactly (the JPEG decoded again)
	var shown := Image.new()
	sent = shown if shown.load_jpg_from_buffer(jpeg) == OK else out
	sent_bytes = jpeg.size()
	sending = send
	result = {}
	_list.text = ""
	_json.text = ""
	result_text = ""
	_summary.text = ("読んでいます…（約 10 秒）" if send else "送る画像（まだ送っていない）")
	show_view("sent")

## The tab is hidden (or the screen closed): an answer still on its way may still time out.
func tick_hidden(dt: float) -> void:
	if waiting():
		_count_down(dt)

func tick(dt: float) -> void:
	_count_down(dt)
	if view_mode == "live":
		_overlay.queue_redraw()
	refresh()

func _count_down(dt: float) -> void:
	if waiting():
		_wait -= dt
		if _wait <= 0.0:
			_rid = ""
			_summary.text = ""
			_result(false, "%d 秒たっても返事がない（学習支援 AI のサーバを確かめる）" % int(WAIT_S))

func _on_ack(rid: String, ok: bool, data: Dictionary) -> void:
	if rid == "" or rid != _rid:
		return
	# the link gives up on every command after a few seconds; reading takes ~10 s: keep waiting
	if not ok and str(data.get("reason", "")) == "timeout" and not data.has("command"):
		return
	_rid = ""
	if not ok:
		_summary.text = ""
		_json.text = JSON.stringify(data, "  ")
		_result(false, "読み取りに失敗: " + str(data.get("reason", "?")))
		return
	show_result(data)

## sheet_read's answer, over the image that was sent (also the tests' entry).
func show_result(data: Dictionary) -> void:
	result = data
	_summary.text = summary_text(data)
	_list.text = "\n".join(problem_lines(data))
	_json.text = JSON.stringify(data.get("response", data), "  ")
	_result(bool(data.get("read_anything", false)), "プリント読み取り: " + str(data.get("summary", "")))
	if sent != null:
		show_view("sent")

func _result(ok: bool, text: String) -> void:
	result_ok = ok
	result_text = text
	if not ok and not waiting() and frame == null:
		_summary.text = text

func refresh() -> void:
	var ready := backend_ready()
	var cam := has_camera(role)
	_read_b.disabled = waiting() or not ready or not cam
	_look_b.disabled = waiting() or not cam
	_read_b.text = "読んでいます…" if waiting() else "撮って読む"
	for k in _camera_buttons:
		(_camera_buttons[k] as Button).disabled = waiting()
	_live_b.set_pressed_no_signal(view_mode == "live")
	_sent_b.set_pressed_no_signal(view_mode == "sent")
	_frame_b.set_pressed_no_signal(view_mode == "frame")
	_sent_b.disabled = sent == null
	_frame_b.disabled = frame == null
	_clear_b.disabled = not region().has_area()
	var at := _rotation.get_item_index(rotation_deg())
	if at >= 0 and _rotation.selected != at:
		_rotation.select(at)
	_pick_b.text = "ライブか撮った画像の上でドラッグ…" if _picking else "送る範囲をドラッグで決める"
	var rg := region()
	_region_label.text = ("送る範囲: 全体" if not rg.has_area() else
		"送る範囲: 左 %d%%・上 %d%%・幅 %d%%・高さ %d%%" % [roundi(rg.position.x * 100), roundi(rg.position.y * 100),
			roundi(rg.size.x * 100), roundi(rg.size.y * 100)]) + "（%sの分として覚える）" % _camera_name(role)
	if not cam:
		_camera_state.text = "%sがつながっていない" % _camera_name(role)
	elif not ready:
		_camera_state.text = "バックエンドにつながっていない（送る画像は見られる）"
	else:
		var cams := _cameras()
		_camera_state.text = "● " + (cams.feed_name(role) if cams != null else "")
	_view_label.text = view_text()

## What the view shows, in words (sizes of what was sent).
func view_text() -> String:
	match view_mode:
		"sent":
			if sent == null:
				return ""
			var s := "%s: %d×%d・%d KB・向き %s・%s" % ["送った画像" if sending else "送る画像（まだ送っていない）",
				sent.get_width(), sent.get_height(), sent_bytes / 1000, _rotation_name(rotation_deg()),
				"範囲で切り出し" if region().has_area() else "全体"]
			var resp: Dictionary = result.response if result.get("response") is Dictionary else {}
			var got = resp.get("image")
			if got is Dictionary:
				s += "（サーバが受け取ったのは %d×%d）" % [int(got.get("width", 0)), int(got.get("height", 0))]
			return s
		"frame":
			if frame == null:
				return ""
			return "撮った画像: %d×%d（黄色の枠が送る範囲）" % [frame.get_width(), frame.get_height()]
	return "ライブ（黄色の枠が送る範囲）"

static func _rotation_name(deg: int) -> String:
	for r in ROTATIONS:
		if r[0] == deg:
			return r[1]
	return "%d°" % deg

static func _camera_name(r: String) -> String:
	for c in CAMERAS:
		if c[0] == r:
			return c[1]
	return r

static func summary_text(data: Dictionary) -> String:
	if not bool(data.get("read_anything", false)):
		return "読めなかった（向き・範囲を直す。紙を大きく・明るく写す。学習したものと違う形式のプリントかもしれない）"
	var s := str(data.get("summary", ""))
	var sec = data.get("seconds")
	if sec is float or sec is int:
		s += "・%.1f 秒" % float(sec)
	s += "・サーバの紙の切り出し: " + ("あり" if data.get("paper") is Array else "なし")
	return s

static func problem_lines(data: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var probs: Array = data.problems if data.get("problems") is Array else []
	for p in probs:
		if not p is Dictionary:
			continue
		var st := str(p.get("answer_status", "unreadable"))
		var line := "%s %d. %s　答え「%s」" % [STATUS_MARKS.get(st, "？"), int(p.get("number", 0)), STATUS_NAMES.get(st, st),
			str(p.get("student_answer", ""))]
		if p.get("correct_answer") != null and str(p.correct_answer) != "":
			line += "　正答 " + str(p.correct_answer)
		if str(p.get("visible", "")) == "partial":
			line += "（見切れ）"
		var notes: Array = p.notes if p.get("notes") is Array else []
		for n in notes:
			line += "　※" + str(n)
		out.append(line)
	var sheet_notes: Array = data.notes if data.get("notes") is Array else []
	for n in sheet_notes:
		out.append("※ " + str(n))
	return out

## Where an image of `image_size` shows in a view of `view_size` (kept aspect, centred).
static func frame_rect(image_size: Vector2, view_size: Vector2) -> Rect2:
	if image_size.x <= 0 or image_size.y <= 0:
		return Rect2()
	var k := minf(view_size.x / image_size.x, view_size.y / image_size.y)
	var sz := image_size * k
	return Rect2((view_size - sz) / 2.0, sz)

## A [x1, y1, x2, y2] box on the 0..1000 scale of the image, in that image's shown rect.
static func box_rect(box, shown: Rect2) -> Rect2:
	if not box is Array or (box as Array).size() != 4:
		return Rect2()
	var a := Vector2(float(box[0]), float(box[1])) / 1000.0
	var b := Vector2(float(box[2]), float(box[3])) / 1000.0
	return Rect2(shown.position + a * shown.size, (b - a) * shown.size).abs()

func _draw_overlay() -> void:
	var shown := _shown()
	if not shown.has_area():
		return
	if view_mode != "sent":
		# the part sent (and the one being dragged)
		var rg := region()
		if _picking and _drag_from.x >= 0.0:
			rg = Rect2(_drag_from, _drag_to - _drag_from).abs()
		if rg.has_area():
			_overlay.draw_rect(Rect2(shown.position + rg.position * shown.size, rg.size * shown.size), YELLOW, false, 3.0)
		return
	if result.is_empty():
		return
	if result.get("paper") is Array and (result.paper as Array).size() == 4:
		var pts := PackedVector2Array()
		for c in result.paper:
			pts.append(shown.position + Vector2(float(c[0]), float(c[1])) * shown.size)
		pts.append(pts[0])
		for i in range(4):
			_overlay.draw_dashed_line(pts[i], pts[i + 1], CYAN, 2.0, 8.0)
	var font := ThemeDB.fallback_font
	var probs: Array = result.problems if result.get("problems") is Array else []
	for p in probs:
		if not p is Dictionary:
			continue
		var col: Color = STATUS_COLORS.get(str(p.get("answer_status", "")), Color("b0b0b0"))
		var r := box_rect(p.get("box"), shown)
		if r.size != Vector2.ZERO:
			_overlay.draw_rect(r, col, false, 3.0)
			var tag := "%d %s" % [int(p.get("number", 0)), STATUS_MARKS.get(str(p.get("answer_status", "")), "？")]
			_overlay.draw_rect(Rect2(r.position, Vector2(44, 22)), Color(0, 0, 0, 0.6))
			_overlay.draw_string(font, r.position + Vector2(4, 17), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, col)
		var ar := box_rect(p.get("answer_box"), shown)
		if ar.size != Vector2.ZERO:
			_overlay.draw_rect(ar, col, false, 1.5)

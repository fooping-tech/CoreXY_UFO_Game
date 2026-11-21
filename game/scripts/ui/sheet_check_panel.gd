class_name SheetCheckPanel
extends VBoxContainer
## The settings screen's プリント tab (#230): try the learning support AI's worksheet reader
## (POST /v1/sheet) with a connected camera. The live frame of the overview or the arm camera is
## shown; 撮って読む sends one frame (sheet_read) and draws what came back over that frame: each
## problem's box and its answer box, coloured by the answer's state, and the list below.
## Never the crane: no RobotState, no robot command. The backend keeps nothing; neither does this.

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
const CAMERAS := [["overview", "俯瞰カメラ"], ["focus", "アームのカメラ"]]
const STATUS_NAMES := {"correct": "正解", "incorrect": "まちがい", "blank": "空白", "partial": "書きかけ",
	"unreadable": "読めない"}
const STATUS_MARKS := {"correct": "○", "incorrect": "×", "blank": "□", "partial": "△", "unreadable": "？"}
const STATUS_COLORS := {"correct": Color("6be37a"), "incorrect": Color("ff5c5c"), "blank": Color("5cb8ff"),
	"partial": Color("ffb03c"), "unreadable": Color("b0b0b0")}

var main: Node
var role := "overview"
var crop := true
var calc := true
## the last answer (sheet_read's ack data) and the frame it is about
var result: Dictionary = {}
var shot: Image
var result_text := ""
var result_ok := true
var _rid := ""
var _wait := 0.0
var _camera_buttons: Dictionary = {}  # role -> Button
var _read_b: Button
var _live_b: Button
var _camera_state: Label
var _view: TextureRect
var _overlay: Control
var _summary: Label
var _list: Label

func setup(m: Node) -> void:
	main = m
	add_theme_constant_override("separation", 8)
	PanelKit.wrapped(self, "学習支援 AI のプリント読み取り（/v1/sheet）を、つないだカメラで試す。プリント全体が写るようにして"
		+ "「撮って読む」を押すと、1 枚撮って送り、問題ごとの枠と答えの状態を重ねて出す（1 回 約 10 秒）。"
		+ "接続先は設定の「学習支援 AI の URL」。結果はモデルの推定。アームは動かさない。", 16, MUTED, 2, WIDTH)
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
	for o in [["crop", "紙を切り出す（crop）"], ["calc", "式を計算し直す（calc）"]]:
		var key: String = o[0]
		var cb := CheckBox.new()
		cb.text = o[1]
		cb.button_pressed = true
		cb.focus_mode = Control.FOCUS_NONE
		cb.add_theme_font_size_override("font_size", 16)
		cb.toggled.connect(func(on: bool): set(key, on))
		row.add_child(cb)
	row = PanelKit.row(self)
	_read_b = PanelKit.button("撮って読む", 22, read_now)
	_read_b.custom_minimum_size = Vector2(200, 0)
	row.add_child(_read_b)
	_live_b = PanelKit.button("ライブに戻す", 18, show_live)
	row.add_child(_live_b)

	var frame := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("0b1122")
	sb.border_color = Color("4a5a78")
	sb.set_border_width_all(2)
	frame.add_theme_stylebox_override("panel", sb)
	add_child(frame)
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(WIDTH, VIEW_H)
	holder.clip_contents = true
	frame.add_child(holder)
	_view = TextureRect.new()
	_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	holder.add_child(_view)
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	holder.add_child(_overlay)

	PanelKit.wrapped(self, "枠の色: 緑 正解・赤 まちがい・青 空白・橙 書きかけ・灰 読めない。細い枠が答えのらん、点線が切り出した紙。",
		14, MUTED, 2, WIDTH)
	_summary = PanelKit.wrapped(self, "", 20, YELLOW, 3, WIDTH)
	_list = PanelKit.wrapped(self, "", 17, Color.WHITE, 2, WIDTH)
	if main != null and main.get("ws") != null:
		main.ws.ack.connect(_on_ack)
	pick_camera(role)

func backend_ready() -> bool:
	return main != null and RobotState.source == "websocket" and main.ws.enabled and main.ws.is_open()

func _cameras() -> CameraHub:
	return main.get("cameras") if main != null else null

func has_camera(r: String) -> bool:
	var cams := _cameras()
	return cams != null and cams.has_feed(r)

func waiting() -> bool:
	return _rid != ""

## The tab shows: the live frame again unless an answer is on screen.
func opened() -> void:
	if shot == null:
		show_live()
	refresh()

func pick_camera(r: String) -> void:
	role = r
	for k in _camera_buttons:
		(_camera_buttons[k] as Button).button_pressed = k == r
	if not waiting():
		show_live()

func show_live() -> void:
	if waiting():
		return
	shot = null
	result = {}
	_summary.text = ""
	_list.text = ""
	var cams := _cameras()
	_view.texture = cams.texture(role) if cams != null and has_camera(role) else null
	_overlay.queue_redraw()
	refresh()

## One frame of the chosen camera -> sheet_read. The frame stays on screen for the answer.
func read_now() -> void:
	if waiting():
		return
	if not backend_ready():
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
	var jpeg := StudyClient.encode_jpeg(img, IMAGE_EDGE, IMAGE_BYTES)
	if jpeg.is_empty():
		_result(false, "画像を %d KB 以下の JPEG にできなかった" % (IMAGE_BYTES / 1000))
		return
	var rid: String = main.ws.send_command("sheet_read",
		{"image_jpeg_base64": Marshalls.raw_to_base64(jpeg), "crop": crop, "calc": calc})
	if main.ws.last_send_error != OK:
		main.ws.forget(rid)
		_result(false, "送れなかった（WebSocket error %d、%d KB）" % [main.ws.last_send_error, jpeg.size() / 1000])
		return
	shot = img
	result = {}
	_view.texture = ImageTexture.create_from_image(img)
	_rid = rid
	_wait = WAIT_S
	_summary.text = "読んでいます…（約 10 秒。%s・%d KB）" % [_camera_name(role), jpeg.size() / 1000]
	_list.text = ""
	result_text = ""
	_overlay.queue_redraw()
	refresh()

## The tab is hidden (or the screen closed): an answer still on its way may still time out.
func tick_hidden(dt: float) -> void:
	if waiting():
		_count_down(dt)

func tick(dt: float) -> void:
	_count_down(dt)
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
		_result(false, "読み取りに失敗: " + str(data.get("reason", "?")))
		return
	show_result(data)

## sheet_read's answer, over the frame that was sent (also the tests' entry).
func show_result(data: Dictionary) -> void:
	result = data
	_summary.text = summary_text(data)
	_list.text = "\n".join(problem_lines(data))
	_result(bool(data.get("read_anything", false)), "プリント読み取り: " + str(data.get("summary", "")))
	_overlay.queue_redraw()

func _result(ok: bool, text: String) -> void:
	result_ok = ok
	result_text = text
	if not ok and not waiting() and shot == null:
		_summary.text = text

func refresh() -> void:
	var ready := backend_ready()
	_read_b.disabled = waiting() or not ready or not has_camera(role)
	_live_b.disabled = waiting() or shot == null
	_read_b.text = "読んでいます…" if waiting() else "撮って読む"
	for k in _camera_buttons:
		(_camera_buttons[k] as Button).disabled = waiting()
	if not ready:
		_camera_state.text = "バックエンドにつながっていない"
	elif not has_camera(role):
		_camera_state.text = "%sがつながっていない" % _camera_name(role)
	else:
		var cams := _cameras()
		_camera_state.text = "● " + (cams.feed_name(role) if cams != null else "")

static func _camera_name(r: String) -> String:
	for c in CAMERAS:
		if c[0] == r:
			return c[1]
	return r

static func summary_text(data: Dictionary) -> String:
	if not bool(data.get("read_anything", false)):
		return "読めなかった（紙を大きく・明るく写す。学習したものと違う形式のプリントかもしれない）"
	var s := str(data.get("summary", ""))
	var sec = data.get("seconds")
	if sec is float or sec is int:
		s += "・%.1f 秒" % float(sec)
	s += "・紙の切り出し: " + ("あり" if data.get("paper") is Array else "なし")
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
	if shot == null or result.is_empty():
		return
	var shown := frame_rect(Vector2(shot.get_size()), _overlay.size)
	if result.get("paper") is Array and (result.paper as Array).size() == 4:
		var pts := PackedVector2Array()
		for c in result.paper:
			pts.append(shown.position + Vector2(float(c[0]), float(c[1])) * shown.size)
		pts.append(pts[0])
		_overlay.draw_dashed_line(pts[0], pts[1], CYAN, 2.0, 8.0)
		for i in range(1, 4):
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

class_name StudyServices
extends Node
## What the study mode asks of the outside world, for each demo mode
## (study_mode.demo.source). The controller never talks to the robot, the cameras,
## Jev or the assistant itself: only to this node, which answers with signals.
##
##   simulated : the worksheet, the answers (keys 1/2/3, or auto), the problem's place
##               and the explanation (the worksheet's own hints) are simulated: no
##               camera, no Jev, no AI, nothing leaves the machine. The arm moves on the
##               backend's mock robot (`./start.sh --mock --study-mode`) or, without a
##               backend, on the game's own MockRobot; never on the real crane.
##   camera    : the overview camera. With study.ai "local" (the default, #232) everything is
##               read by the local LLM server (the worksheet reader for the watch and the
##               locate, the tutor for the explanation; the frames cut out and turned upright
##               as the プリント tab says, SheetFrame); with "cloud": Jev (HomeworkClient's watch
##               with the worksheet), Claude / Codex (locate + explain).
##
## Which robot is not chosen here (#92): it is the one start.sh connected (--real /
## --mock). With the real crane the backend still refuses what is not calibrated.
##
## Robot motion is always one sequence run by the backend (homework_approach with
## stages, study_cleanup_*) under its motion lock, or the game's mock walking its
## own targets: never jogs. Results that come back after `abort()` are ignored.

signal worksheet_seen
## each problem's reading by its printed number: [{number, filled_prob}] (#237: any count)
signal reading(questions: Array, held: bool, reason: String)
signal located(target: Dictionary)
signal locate_failed(reason: String)
## kind: "help" | "cleanup"; data: the sequence's status
signal motion_update(kind: String, phase: String, stage: String, holding: bool, data: Dictionary)
signal motion_done(kind: String)
signal motion_fault(kind: String, reason: String)
signal explained(result: Dictionary)
signal explain_failed(reason: String, fallback: Dictionary)
## The tutor AI's "look d_mm further" turned into the next target (#104; nothing moves yet)
signal navigated(target: Dictionary)
signal navigate_failed(reason: String)
## #237: the answer check's reading of the whole sheet ([{number, answer_status, student_answer?, visible?}])
signal graded(problems: Array)
signal grade_failed(reason: String)

const MODES := ["simulated", "camera"]
## the earlier study_mode.demo.mode values (#86), read as the new ones
const LEGACY_MODES := {"mock": "simulated", "real": "camera"}
const MOCK_READING_S := 1.5

var main: Node
var homework: HomeworkClient
var mode := "simulated"
var worksheet: Dictionary = {}
var grade_label := ""
## the next action of this kind fails (debug): "" | locate | motion | ai | cleanup | occlude
var inject_fail := ""
## tests: navigate replies the simulated explanation carries, one per explanation (#104)
var inject_navigate: Array = []
var status := ""
## the mock demo
var worksheet_wait_s := 4.0
var auto_answer := false
var auto_answer_s := 6.0
var mock_origin := Vector2(90.0, 0.0)
var mock_scale := 1.0
var _mock_probs: Array = [0.02, 0.02, 0.02]
var _mock_t := 0.0
var _mock_next_reading := 0.0
var _mock_seen_at := -1.0
var _occlude_left := 0
var watching := false
var seen := false
## pending work ("" = none): results with another id are ignored
var _locate_rid := ""
## #232: how the last located frame was cut and turned ({rotation, region, size}; {} = as it was)
var _locate_prep := {}
## #237: the last per-problem reading the watch brought (camera mode: its answer states)
var last_answers: Array = []
## the simulated mode's answer check: the result of each problem the first time (study_mode.answer_check.demo_results);
## a rescan finds the ones to look at again written right (the child rewrote them)
var demo_results: Array = ["correct", "incorrect", "correct"]
var _grade_token := 0
var _grade_rid := ""
## #237: the picture the answer check read (cut out, upright): the ○ go on it (null = the drawn sheet)
var graded_image: Image
const GRADE_WAIT_S := 120.0  # the reader: ~10 s, more when busy
var _explain_rid := ""
var _help_rid := ""
var _nav_rid := ""
## #116: the worksheet's corner marks in the overview frame (as shown): {tl, tr, bl, br: Vector2 0..1}
const SHEET_FIND_S := 1.5  # how often the frame is sent to find them
const SHEET_FRESH_MS := 8000  # older than this: the drawn sheet again
const SHEET_JUMP := 0.04  # an answer further than this (0..1 of the image) waits for the next
const SHEET_AGREE := 0.02  # ... which must be this close to it
const SHEET_BLEND := 0.5  # a near answer moves the shown corners this much of the way
## The frame sent to find them: the robot link's backend takes at most 1 MiB per message
## (websockets' max_size) and base64 adds a third, so 1024 px / 600 kB stays well inside.
## The corners come back as 0..1 of the image, so the size does not move them.
const SHEET_IMAGE_EDGE := 1024
const SHEET_IMAGE_BYTES := 600000
## The robot link's send buffer for that frame (Godot's default, 64 KiB, refused it: #130).
const SHEET_SEND_BUFFER := 1048576
var sheet_corners: Dictionary = {}
var sheet_seen_ms := -1
var _sheet_pending: Dictionary = {}
var _sheet_left := 0.0
var _sheet_rid := ""
var _sheet_jpeg_bytes := 0
var _sheet_last_note := ""
var _motion_last_note := ""
## The last staged capture's target ({u, v} or {xy}): where "d_mm further" starts from (#104)
var last_help_target: Dictionary = {}
var _cleanup_rid := ""
var _help_active := false
var _help_started := false
var _cleanup_active := false
var _cleanup_started := false
var _seq := 0
var _timers: Array = []  # [seconds_left, Callable, token]
var _token := 0  # bumped by abort(): delayed mock callbacks of before are dropped
## the game's mock walking its own targets: [{p: Vector3, phase, stage, hold, dwell, confirm}]
var _walk: Array = []
var _walk_kind := ""
var _walk_wait := 0.0
var _walk_released := false
var _walk_confirmed := false
var captures: Dictionary = {}  # stage -> Image (focus camera), "overview" -> Image
var voice_status := ""
var _help_problem := 3
var _helper_offer_was := true
var voice_credit := ""
## Callable(rid, stream, credit) / Callable(rid, message): the speech queue
var on_voice: Callable
var on_voice_error: Callable

func setup(m: Node, hw: HomeworkClient) -> void:
	main = m
	homework = hw
	if homework != null:
		homework.aux_message.connect(_on_aux)
	if main != null and main.ws != null:
		main.ws.message_received.connect(_on_robot_message)
		main.ws.ack.connect(_on_robot_ack)
	load_demo_config()
	_log_signals()
	trace("mode %s (%s)" % [mode, mode_label()])

## study_mode.demo (again after the settings screen's 保存, #93).
func load_demo_config() -> void:
	var d = GameConfig.get_value("study_mode", "demo", {})
	if d is Dictionary:
		mode = normalize_mode(str(d.get("source", d.get("mode", mode))))
		worksheet_wait_s = float(d.get("worksheet_wait_s", worksheet_wait_s))
		auto_answer = bool(d.get("auto_answer", auto_answer))
		auto_answer_s = maxf(float(d.get("auto_answer_s", auto_answer_s)), 1.0)
		var md = d.get("mock_desk", {})
		if md is Dictionary and md.get("origin_xy_mm") is Array:
			mock_origin = Vector2(float(md.origin_xy_mm[0]), float(md.origin_xy_mm[1]))
			mock_scale = float(md.get("mm_per_paper_mm", 1.0))

## "simulated" / "camera"; the earlier names are read (mock -> simulated, real -> camera)
## and anything else is the safe one, simulated (nothing leaves the machine).
static func normalize_mode(m: String) -> String:
	m = LEGACY_MODES.get(m, m)
	return m if m in MODES else "simulated"

func set_mode(m: String) -> void:
	mode = normalize_mode(m)

func mode_label() -> String:
	var what: String = {"simulated": "模擬デモ", "camera": "カメラ連携デモ"}.get(mode, mode)
	match motion_route():
		"backend":
			return what + ("・実機" if robot_is_real() else "・Mock")
		"game_mock":
			return what + "・ゲーム内 Mock"
	return what

## Everything stops: pending results are ignored, the mock's walk ends, and a backend
## sequence this node started is ended with soft_stop (the backend then ABORTs it).
## Says nothing back: the caller decides what the story does next.
func abort(reason := "") -> void:
	_token += 1
	_timers.clear()
	_locate_rid = ""
	_explain_rid = ""
	if not _walk.is_empty():
		_walk.clear()
		_walk_kind = ""
		if main != null and main.mock != null:
			main.mock.set_target(main.mock.pos)  # the game's mock stops where it is
	if (_help_active or _cleanup_active) and backend_robot():
		main.ws.send_command("soft_stop")
	_help_active = false
	_help_started = false
	_cleanup_active = false
	_cleanup_started = false
	_help_rid = ""
	_nav_rid = ""
	_sheet_rid = ""
	_cleanup_rid = ""
	_last_seq_key.clear()
	status = reason

func begin(ws: Dictionary, label: String) -> void:
	abort()
	worksheet = ws
	grade_label = label
	captures.clear()
	seen = false
	_mock_probs = [0.02, 0.02, 0.02]
	_mock_t = 0.0
	_mock_next_reading = 0.0
	_mock_seen_at = -1.0
	_occlude_left = 0
	last_answers = []
	_grade_token += 1
	if homework != null:
		homework._ensure_link()  # the voice and the answers come over its aux link

# ------------------------------------------------------------------ timers
func _after(secs: float, f: Callable) -> void:
	_timers.append([secs, f, _token])

func _process(dt: float) -> void:
	for t in _timers.duplicate():
		t[0] -= dt
		if t[0] <= 0.0:
			_timers.erase(t)
			if int(t[2]) == _token:
				t[1].call()
	if watching and mode == "simulated":
		_mock_tick(dt)
	if not _walk.is_empty():
		_walk_tick(dt)
	_sheet_tick(dt)

## #116: in the camera mode, the overview frame goes to the backend now and then to find the
## worksheet's corner marks (OpenCV there, no AI, nothing kept); the HUD then shows the real
## sheet, straightened, from the live camera.
func _sheet_tick(dt: float) -> void:
	_sheet_left -= dt
	# only while the study mode watches the sheet (review on #117: not during the game)
	if not watching or _sheet_left > 0.0 or mode != "camera" or _sheet_rid != "" or not backend_robot():
		return
	_sheet_left = SHEET_FIND_S
	var img := _overview_image()
	if img == null or img.is_empty():
		return
	var jpeg := StudyClient.encode_jpeg(img, SHEET_IMAGE_EDGE, SHEET_IMAGE_BYTES)
	if jpeg.is_empty():
		return
	var rid: String = main.ws.send_command("worksheet_find", {"image_jpeg_base64": Marshalls.raw_to_base64(jpeg)})
	if main.ws.last_send_error != OK:
		main.ws.forget(rid)  # not sent: no answer will come, try again next time
		_sheet_note("not sent (error %d, %d bytes)" % [main.ws.last_send_error, jpeg.size()])
		return
	_sheet_rid = rid
	_sheet_jpeg_bytes = jpeg.size()

## The corner marks while fresh, else {} (the drawn sheet).
func sheet_marks(now_ms: int = -1) -> Dictionary:
	var now := Time.get_ticks_msec() if now_ms < 0 else now_ms
	return sheet_corners if sheet_seen_ms >= 0 and now - sheet_seen_ms <= SHEET_FRESH_MS else {}

func _on_sheet_found(ok: bool, payload: Dictionary) -> void:
	if not ok:
		_sheet_note("refused: %s (%d bytes)" % [str(payload.get("reason", payload.get("message", "?"))), _sheet_jpeg_bytes])
		return
	if not bool(payload.get("found", false)) or not payload.get("corners") is Dictionary:
		_sheet_note("marks not found in the overview frame")
		return  # the last ones age out (SHEET_FRESH_MS)
	var c: Dictionary = payload.corners
	var out := {}
	for k in ["tl", "tr", "bl", "br"]:
		if not c.get(k) is Array or (c[k] as Array).size() != 2:
			return
		out[k] = Vector2(float(c[k][0]), float(c[k][1]))
	var inferred := str(payload.get("inferred", ""))
	_sheet_note("marks found" + ((" (%s computed from the other three)" % inferred) if inferred != "" else ""))
	_sheet_take(out, Time.get_ticks_msec())

## #130: a new answer far from the shown one is taken only when the next one agrees (one odd
## frame does not throw the picture), a near one is blended in (no shaking), and the last ones
## stay while nothing is found for SHEET_FRESH_MS (a hand or a cable over the sheet).
func _sheet_take(out: Dictionary, now: int) -> void:
	var shown := sheet_marks(now)
	if shown.is_empty() or corners_apart(shown, out) <= SHEET_JUMP:
		_sheet_pending = {}
		if not shown.is_empty():
			for k in out.keys():
				out[k] = shown[k].lerp(out[k], SHEET_BLEND)
		sheet_corners = out
		sheet_seen_ms = now
		return
	if not _sheet_pending.is_empty() and corners_apart(_sheet_pending, out) <= SHEET_AGREE:
		trace("sheet search: moved (%.3f of the image)" % corners_apart(shown, out))
		_sheet_pending = {}
		sheet_corners = out
		sheet_seen_ms = now
		return
	trace("sheet search: an answer %.3f away held back until the next one agrees" % corners_apart(shown, out))
	_sheet_pending = out

## The largest distance between two sets of corners (0..1 of the image).
static func corners_apart(a: Dictionary, b: Dictionary) -> float:
	var d := 0.0
	for k in ["tl", "tr", "bl", "br"]:
		d = maxf(d, (a[k] as Vector2).distance_to(b[k]))
	return d

## The sheet search's outcome, logged when it changes (it runs every SHEET_FIND_S).
func _sheet_note(what: String) -> void:
	if what == _sheet_last_note:
		return
	_sheet_last_note = what
	trace("sheet search: " + what)

## One line in the debug log (F1 panel) and Godot's log file.
func trace(text: String) -> void:
	var t := "study: " + text
	if main != null and main.has_signal("debug_log"):
		main.debug_log.emit(t)
	else:
		print("[log] " + t)

func _log_signals() -> void:
	located.connect(func(t): trace("located %s" % JSON.stringify(t)))
	locate_failed.connect(func(r): trace("locate failed: " + r))
	navigated.connect(func(t): trace("navigated %s" % JSON.stringify(t)))
	navigate_failed.connect(func(r): trace("navigate failed: " + r))
	explained.connect(func(r): trace("explained (%s)" % str(r.get("source", r.get("provider", "?")))))
	explain_failed.connect(func(r, _fb): trace("explain failed: " + r))
	motion_update.connect(func(k, ph, st, _h, _d):
		var m := "motion %s %s %s" % [k, ph, st]
		if m != _motion_last_note:
			_motion_last_note = m
			trace(m))
	motion_done.connect(func(k): trace("motion done " + k))
	motion_fault.connect(func(k, r): trace("motion fault %s: %s" % [k, r]))
	worksheet_seen.connect(func(): trace("worksheet seen"))

# ------------------------------------------------------------------ the watch
func watch_start() -> void:
	watching = true
	if mode == "simulated":
		_mock_seen_at = worksheet_wait_s if not seen else -1.0
		return
	if homework == null:
		status = "宿題の見守り（HomeworkClient）がありません"
		return
	homework.stop()
	homework.worksheet_id = str(worksheet.get("worksheet_id", ""))
	_helper_offer_was = homework.helper_offer
	homework.helper_offer = false  # the study mode has its own HELP: no "手伝おうか？" moving the arm
	homework.start()
	status = "カメラでプリントを見ています（%s）" % ("ローカル LLM" if homework.study_local else "Jev")

func watch_stop() -> void:
	var was := watching
	watching = false
	sheet_corners = {}
	sheet_seen_ms = -1
	_sheet_pending = {}
	if mode != "simulated" and homework != null and was:
		if homework.running():
			homework.stop("勉強モードの見守りを終えました")
		homework.worksheet_id = ""
		homework.helper_offer = _helper_offer_was

## Enter while waiting: the sheet is on the desk (when the camera has not seen it yet).
func mark_seen() -> void:
	if not seen:
		seen = true
		worksheet_seen.emit()

## Mock: the child writes in problem n (writing now, written at the next reading).
func demo_fill(n: int) -> void:
	if n < 1 or n > _mock_probs.size():
		return
	_mock_probs[n - 1] = 0.45 if float(_mock_probs[n - 1]) < 0.3 else 0.95
	_mock_next_reading = minf(_mock_next_reading, 0.3)

func demo_occlude(readings := 2) -> void:
	_occlude_left = readings

func _mock_tick(dt: float) -> void:
	_mock_t += dt
	if not seen and _mock_seen_at >= 0.0 and _mock_t >= _mock_seen_at:
		mark_seen()
	if not seen:
		return
	if auto_answer:
		for n in [1, 2]:
			if _mock_t >= auto_answer_s * n and float(_mock_probs[n - 1]) < 0.3:
				demo_fill(n)
	_mock_next_reading -= dt
	if _mock_next_reading > 0.0:
		return
	_mock_next_reading = MOCK_READING_S
	for i in _mock_probs.size():
		if is_equal_approx(float(_mock_probs[i]), 0.45):
			_mock_probs[i] = 0.46  # shown as writing once, then written
		elif is_equal_approx(float(_mock_probs[i]), 0.46):
			_mock_probs[i] = 0.95
	if _occlude_left > 0:
		_occlude_left -= 1
		reading.emit([], true, "occluded")
		return
	var qs: Array = []
	var probs: Array = worksheet.get("problems", []) if worksheet.get("problems") is Array else []
	for i in mini(probs.size(), _mock_probs.size()):
		qs.append({"number": int(probs[i].number), "filled_prob": _mock_probs[i]})
	reading.emit(qs, false, "")

func _on_progress(data: Dictionary) -> void:
	if not watching:
		return
	var reason := str(data.get("held_reason", ""))
	var visible = data.get("visible_prob")
	if not seen and reason != "not_visible" and (visible == null or float(visible) >= 0.5):
		mark_seen()
	if not seen:
		return
	var qs: Array = []
	for q in data.get("questions", []) if data.get("questions") is Array else []:
		if q is Dictionary and q.get("number") != null:
			qs.append({"number": int(q.number), "filled_prob": q.get("filled_prob")})
	if data.get("answers") is Array and not (data.answers as Array).is_empty():
		last_answers = (data.answers as Array).duplicate(true)
	reading.emit(qs, bool(data.get("held", false)), reason)

## #237: the problems are the ones read on the real print (any number, any count), not the
## sample sheet's: the camera mode read by the local LLM server.
func reads_whole_sheet() -> bool:
	return mode == "camera" and homework != null and homework.reads_locally()

# ------------------------------------------------------------------ the answer check (#237)
## Read the whole sheet once for the answer check -> graded(problems) / grade_failed(reason).
## `rescan`: after the child rewrote what was to be looked at again.
func grade(rescan := false) -> void:
	_grade_token += 1
	var tok := _grade_token
	graded_image = null
	if inject_fail == "grade":
		inject_fail = ""
		_after(1.0, func(): if tok == _grade_token: grade_failed.emit("プリントを読めませんでした（失敗の注入）"))
		return
	if mode == "simulated":
		var out: Array = []
		var probs: Array = worksheet.get("problems", []) if worksheet.get("problems") is Array else []
		for i in probs.size():
			var st := str(demo_results[i]) if i < demo_results.size() else "correct"
			if rescan and st != "unreadable":
				st = "correct"  # rewritten
			out.append({"number": int(probs[i].number), "answer_status": st, "visible": "full"})
		_after(1.5, func(): if tok == _grade_token: graded.emit(out))
		return
	# camera, read locally: the overview frame now, cut out and turned upright (as the watch's,
	# SheetFrame) -> the worksheet reader once (the backend's sheet_read)
	if reads_whole_sheet() and backend_robot():
		var img := _overview_image()
		if img != null and not img.is_empty():
			img.convert(Image.FORMAT_RGB8)
			graded_image = homework.watch_image(img)  # the ○ are drawn on this very picture
			var jpeg := StudyClient.encode_jpeg(graded_image, 1600, 600000)
			if not jpeg.is_empty():
				_grade_rid = main.ws.send_command("sheet_read", {"image_jpeg_base64": Marshalls.raw_to_base64(jpeg)})
				if main.ws.last_send_error == OK:
					_after(GRADE_WAIT_S, func():
						if tok == _grade_token and _grade_rid != "":
							_grade_rid = ""
							grade_failed.emit("プリントの読み取りの返事が来ませんでした"))
					return
				main.ws.forget(_grade_rid)
				_grade_rid = ""
	# otherwise: what the watch read last
	var got := last_answers.duplicate(true)
	_after(0.5, func():
		if tok != _grade_token:
			return
		if got.is_empty():
			grade_failed.emit("まだプリントを読めていません")
		else:
			graded.emit(got))

func cancel_grade() -> void:
	_grade_token += 1
	_grade_rid = ""

func _on_graded_by_reader(ok: bool, payload: Dictionary) -> void:
	if not ok:
		var why := str(payload.get("reason", "?"))
		trace("answer check: the reader refused: " + why)
		if not last_answers.is_empty():  # what the watch read last is better than nothing
			graded.emit(last_answers.duplicate(true))
		else:
			grade_failed.emit("プリントを読めませんでした（%s）" % why)
		return
	var probs: Array = payload.problems if payload.get("problems") is Array else []
	if probs.is_empty():
		grade_failed.emit("プリントの問題を読み取れませんでした")
		return
	var out: Array = []
	for p in probs:  # the state and what was written only: the right answer stays out
		if p is Dictionary and p.get("number") != null:
			out.append({"number": int(p.number), "answer_status": str(p.get("answer_status", "")),
				"student_answer": str(p.get("student_answer", "")), "visible": str(p.get("visible", "full")),
				"answer_box": p.get("answer_box"), "box": p.get("box")})
	graded.emit(out)

# ------------------------------------------------------------------ robot routing
func backend_robot() -> bool:
	return main != null and RobotState.source == "websocket" and main.ws.enabled and main.ws.is_open()

## "backend" | "game_mock" | "" (nothing to move)
func motion_route() -> String:
	if backend_robot():
		return "backend"
	if main != null and mode == "simulated" and RobotState.source == "mock" and main.mock != null and main.mock.enabled:
		return "game_mock"
	return ""

func robot_is_real() -> bool:
	return backend_robot() and str(main.ws.server_robot) == "real"

## The backend's mock robot starts disarmed (motors off, not homed), like the real one.
## The mock demo arms it only after a grown-up's Enter (never the real robot).
func mock_needs_prepare() -> bool:
	return backend_robot() and not robot_is_real() and (not RobotState.motors_enabled or not RobotState.homed)

func prepare_mock_robot() -> void:
	if not mock_needs_prepare():
		return
	if not RobotState.motors_enabled:
		main.ws.send_command("enable_motors", {"enable": true})
	if not RobotState.homed:
		main.ws.send_command("home")

## Why the arm may not move now ("" = it may).
func motion_blocker() -> String:
	return blocker_for(motion_route(), robot_is_real(), mode)

## The rule alone (tests): route = motion_route(), real = the backend runs the real crane.
static func blocker_for(route: String, real: bool, demo_source: String) -> String:
	if route == "":
		return "ロボット（Mock / 実機）につながっていません"
	if real and demo_source != "camera":
		# the simulated places come from the worksheet data, not the desk: never on the crane
		return "実機につながっています。模擬デモでは実機を動かしません（study_mode.demo.source を camera に）"
	return ""

# ------------------------------------------------------------------ HELP: where is problem n
func locate_help(problem: int) -> void:
	_help_problem = problem
	captures.clear()  # #136: another problem's photos are not this one's
	var tok := _token
	if inject_fail == "locate":
		inject_fail = ""
		_after(1.0, func(): locate_failed.emit("カメラの座標校正が使えません（失敗の注入）"))
		return
	if mode == "simulated":
		var p := WorksheetCatalog.problem(worksheet, problem)
		if p.is_empty():
			locate_failed.emit("プリントに問題 %d がありません" % problem)
			return
		var xy := mock_target_xy(p)
		_after(1.2, func(): if tok == _token: located.emit({"xy": xy, "problem": problem, "source": "worksheet"}))
		return
	var why := ""
	if homework == null:
		why = "宿題の見守りがありません"
	else:
		why = homework.focus_blocker()
	if why != "":
		locate_failed.emit(why)
		return
	var img := _overview_image()
	if img == null:
		locate_failed.emit("俯瞰カメラの映像がありません")
		return
	captures["overview"] = img
	# #232: read locally, the frame goes cut out and turned upright; the answer is put back on it
	_locate_prep = homework.sheet_settings()
	_locate_prep["size"] = img.get_size()
	var jpeg := StudyClient.encode_jpeg(SheetFrame.prepare(img, int(_locate_prep.rotation), _locate_prep.region),
		homework.max_image_edge, homework.max_image_bytes)
	if jpeg.is_empty():
		locate_failed.emit("俯瞰カメラの画像を上限サイズ内に圧縮できませんでした")
		return
	_locate_rid = _rid("loc")
	var err := homework.link.send_aux({"type": "homework_locate", "request_id": _locate_rid, "data": {
		"session_id": homework.session_id, "kind": "problem", "problem": problem,
		"worksheet_id": str(worksheet.get("worksheet_id", "")), "image_jpeg_base64": Marshalls.raw_to_base64(jpeg)}})
	if err != OK:
		_locate_rid = ""
		locate_failed.emit("画像を送れませんでした（WebSocket error %d）" % err)

## The located point (0..1 of the image sent) on the whole overview frame (#232).
func located_point(p: Vector2) -> Vector2:
	if _locate_prep.is_empty():
		return p
	return SheetFrame.to_frame(p, int(_locate_prep.rotation), _locate_prep.region, _locate_prep.size)

## The mock desk: where problem p's answer box is in robot XY (mm).
func mock_target_xy(p: Dictionary) -> Vector2:
	var c := WorksheetCatalog.box_centre(p.get("answer_box_mm", [0, 0, 0, 0]))
	var r := GameConfig.robot()
	var xy := mock_origin + c * mock_scale
	return Vector2(clampf(xy.x, float(r.x_min_mm), float(r.x_max_mm)), clampf(xy.y, float(r.y_min_mm), float(r.y_max_mm)))

func _overview_image() -> Image:
	var cams: CameraHub = main.cameras if main != null else null
	if cams == null or not cams.has_feed("overview"):
		return null
	return cams.texture("overview").get_image()

## The arm camera's frame now (null without one).
func focus_image() -> Image:
	var cams: CameraHub = main.cameras if main != null else null
	if cams == null or not cams.has_feed("focus"):
		return null
	return cams.texture("focus").get_image()

# ------------------------------------------------------------------ HELP: the staged capture
func start_help(target: Dictionary) -> void:
	last_help_target = target.duplicate()
	var why := motion_blocker()
	if why != "":
		motion_fault.emit("help", why)
		return
	captures.erase("10cm")
	captures.erase("5cm")
	captures.erase("landing")
	if motion_route() == "game_mock":
		_start_walk("help", _help_walk(target.get("xy", Vector2(195, 100))))
		return
	var params := {"stages": "study"}
	if target.has("xy"):
		params["xy"] = [target.xy.x, target.xy.y]
	else:
		params["u"] = float(target.get("u", 0.5))
		params["v"] = float(target.get("v", 0.5))
		params["camera"] = homework.camera_signature() if homework != null else {}
	_help_active = true
	_help_started = false
	_help_rid = main.ws.send_command("homework_approach", params)

## The tutor AI says the problem is d_mm away from the last capture (#104): the next target.
## The backend checks it (homework_navigate: at most 60 mm, inside the soft limits and the
## trusted camera calibration) and moves nothing; start_help (the usual staged capture) moves.
const NAV_MAX_STEP_MM := 60.0
const NAV_MIN_STEP_MM := 3.0

func navigate_help(d_mm: Array) -> void:
	if d_mm.size() != 2 or last_help_target.is_empty():
		navigate_failed.emit("前に撮った場所が分かりません")
		return
	var d := Vector2(float(d_mm[0]), float(d_mm[1]))
	if motion_route() == "game_mock":  # the game's own mock: the same checks here
		var from: Vector2 = last_help_target.get("xy", Vector2(195, 100))
		var why := mock_navigate_refusal(from, d)
		if why != "":
			navigate_failed.emit(why)
		else:
			var tok := _token
			_after(0.3, func(): if tok == _token: navigated.emit({"xy": from + d, "problem": _help_problem,
				"source": "navigate"}))
		return
	if not backend_robot():
		navigate_failed.emit("アームにつながっていません")
		return
	var params := {"d_mm": [d.x, d.y]}
	if last_help_target.has("xy"):
		params["xy"] = [last_help_target.xy.x, last_help_target.xy.y]
	else:
		params["u"] = float(last_help_target.get("u", 0.5))
		params["v"] = float(last_help_target.get("v", 0.5))
		params["camera"] = homework.camera_signature() if homework != null else {}
	_nav_rid = main.ws.send_command("homework_navigate", params)

static func mock_navigate_refusal(from: Vector2, d: Vector2) -> String:
	if not (is_finite(d.x) and is_finite(d.y)):
		return "移動量が数ではありません"
	if d.length() > NAV_MAX_STEP_MM:
		return "1 回の移動が大きすぎます（%.0f mm）" % d.length()
	if d.length() < NAV_MIN_STEP_MM:
		return "移動量が小さすぎます（もう写っているはず）"
	var r := GameConfig.robot()
	var to := from + d
	if to.x < float(r.x_min_mm) or to.x > float(r.x_max_mm) or to.y < float(r.y_min_mm) or to.y > float(r.y_max_mm):
		return "移動先が可動範囲の外です"
	return ""

## Mock: the close-up of this stage is taken; the arm moves on.
func release_stage(stage: String) -> void:
	if _walk_kind == "help" and not _walk.is_empty():
		_walk_released = true
		return
	if backend_robot():
		main.ws.send_command("homework_approach_release", {"stage": stage})

func capture(stage: String) -> void:
	var img := focus_image()
	if img != null:
		captures[stage] = img

func _help_walk(xy: Vector2) -> Array:
	var r := GameConfig.robot()
	var top := float(r.z_max_mm) if r.z_up_is_positive else float(r.z_min_mm)
	var here: Vector3 = main.mock.pos
	var out := [{"p": Vector3(here.x, here.y, top), "phase": "RAISE"},
		{"p": Vector3(xy.x, xy.y, top), "phase": "MOVE_XY"}]
	for st in dry_run_stages():
		out.append({"p": Vector3(xy.x, xy.y, st.z), "phase": "LOWER", "stage": st.name})
		out.append({"p": Vector3(xy.x, xy.y, st.z), "phase": "SETTLE", "stage": st.name, "dwell": 0.6})
		out.append({"p": Vector3(xy.x, xy.y, st.z), "phase": "HOLD", "stage": st.name, "hold": true})
	out.append({"p": Vector3(xy.x, xy.y, top), "phase": "RAISE_BACK"})
	out.append({"p": Vector3(here.x, here.y, top), "phase": "RETURN_XY"})
	return out

## The close-ups HELP takes, in order (study_mode.height: capture_heights_cm 10[, 5], then the
## landing when on). #110: 10 cm only. The last one starts the explanation.
static func stage_names() -> Array[String]:
	var h = GameConfig.get_value("study_mode", "height", {})
	var heights: Array = h.get("capture_heights_cm", [10.0]) if h is Dictionary and h.get("capture_heights_cm") is Array else [10.0]
	var out: Array[String] = []
	for i in mini(heights.size(), 2):
		out.append(["10cm", "5cm"][i])
	if h is Dictionary and h.get("landing", true) != false:
		out.append("landing")
	return out

static func last_stage() -> String:
	var names := stage_names()
	return names[-1] if not names.is_empty() else "10cm"

## The dry-run heights (study_mode.height.dry_run), as the backend computes them.
static func dry_run_stages() -> Array:
	var h = GameConfig.get_value("study_mode", "height", {})
	var d: Dictionary = h.get("dry_run", {}) if h is Dictionary and h.get("dry_run") is Dictionary else {}
	var heights: Array = h.get("capture_heights_cm", [10.0]) if h is Dictionary and h.get("capture_heights_cm") is Array else [10.0]
	var up := 1.0 if GameConfig.robot().z_up_is_positive else -1.0
	var desk := float(d.get("z_desk_tip", 20.0))
	var per := float(d.get("z_per_cm", 4.0))
	var off := float(d.get("camera_offset_cm", 3.0))
	var out: Array = []
	for name in stage_names():
		if name == "landing":
			out.append({"name": "landing", "z": desk + up * float(d.get("landing_tip_cm", 1.5)) * per})
		else:
			out.append({"name": name, "z": desk + up * (float(heights[0 if name == "10cm" else 1]) - off) * per})
	return out

# ------------------------------------------------------------------ the explanation
func explain(problem: int) -> void:
	_help_problem = problem
	var tok := _token
	var p := WorksheetCatalog.problem(worksheet, problem)
	var fb := fallback_explanation(p, problem)
	if inject_fail == "ai":
		inject_fail = ""
		_after(1.5, func(): explain_failed.emit("AI につながりませんでした（失敗の注入）", fb))
		return
	if mode == "simulated":
		var demo := fb.duplicate()
		demo["source"] = "demo"
		if not inject_navigate.is_empty():  # tests: the tutor AI's "not in the picture" (#104)
			demo["navigate"] = inject_navigate.pop_front()
		_after(2.0, func(): if tok == _token: explained.emit(demo))
		return
	if homework == null or not (homework.advice_available or homework.study_local):
		explain_failed.emit("解説するアシスタント（study.provider）が使えません", fb)
		return
	var images: Array = []
	for role in ["overview", "10cm", "5cm", "landing"]:
		var img: Image = captures.get(role)
		if role == "overview" and img == null:
			img = _overview_image()
		if img == null:
			continue
		var jpeg := StudyClient.encode_jpeg(img, 1280, homework.max_image_bytes)
		if not jpeg.is_empty():
			images.append({"role": role, "image_jpeg_base64": Marshalls.raw_to_base64(jpeg)})
	if images.is_empty():
		explain_failed.emit("カメラの画像がないので、AI に見せられませんでした", fb)
		return
	_explain_rid = _rid("exp")
	var err := homework.link.send_aux({"type": "homework_explain", "request_id": _explain_rid, "data": {
		"images": images, "problem": problem, "grade_label": grade_label,
		"worksheet_id": str(worksheet.get("worksheet_id", ""))}})
	if err != OK:
		_explain_rid = ""
		explain_failed.emit("画像を送れませんでした（WebSocket error %d）" % err, fb)
		return
	var rid := _explain_rid
	var limit := float(GameConfig.get_value("homework", "explain_timeout_s", 150.0)) + 10.0
	_after(limit, func():
		if _explain_rid == rid:
			_explain_rid = ""
			explain_failed.emit("AI の解説が時間内に届きませんでした", fb))

## The worksheet's own hints as an explanation (no AI, or it failed). Never the answer.
static func fallback_explanation(p: Dictionary, problem: int) -> Dictionary:
	var hints: Array = p.get("hints", []) if p.get("hints") is Array else []
	var steps := ""
	for i in hints.size():
		steps += "%d. %s\n" % [i + 1, hints[i]]
	var lines: Array = []
	for h in hints:
		lines.append(str(h) + ("" if str(h).ends_with("。") or str(h).ends_with("？") else "。"))
	return {"problem_number": problem, "recognized_problem": str(p.get("prompt", "")), "confidence": 1.0,
		"hint": str(hints[0]) if not hints.is_empty() else "", "explanation": steps.strip_edges(),
		"speech_lines": lines, "needs_confirmation": false, "source": "worksheet"}

# ------------------------------------------------------------------ the tidy-up
func start_cleanup() -> void:
	if inject_fail == "cleanup":
		inject_fail = ""
		var tok := _token
		_after(1.5, func(): if tok == _token: motion_fault.emit("cleanup", "ジグの位置がわかりません（失敗の注入）"))
		return
	var why := motion_blocker()
	if why != "":
		motion_fault.emit("cleanup", why)
		return
	if motion_route() == "game_mock":
		var w := _cleanup_walk()
		if w.is_empty():
			motion_fault.emit("cleanup", "片付けの経路（study_mode.cleanup.dry_run）がありません")
			return
		_start_walk("cleanup", w)
		return
	_cleanup_active = true
	_cleanup_started = false
	_cleanup_rid = main.ws.send_command("study_cleanup_start")

func confirm_grip() -> void:
	if _walk_kind == "cleanup" and not _walk.is_empty():
		_walk_confirmed = true
	elif backend_robot():
		main.ws.send_command("study_cleanup_confirm")

func _cleanup_walk() -> Array:
	var c = GameConfig.get_value("study_mode", "cleanup", {})
	var d: Dictionary = c.get("dry_run", {}) if c is Dictionary and c.get("dry_run") is Dictionary else {}
	if not (d.get("jig_xy") is Array and d.get("collect_xy") is Array and d.get("park_xy") is Array):
		return []
	var jig := Vector2(float(d.jig_xy[0]), float(d.jig_xy[1]))
	var col := Vector2(float(d.collect_xy[0]), float(d.collect_xy[1]))
	var park := Vector2(float(d.park_xy[0]), float(d.park_xy[1]))
	var safe := float(d.get("safe_z", 95.0))
	var travel := float(d.get("travel_z", 55.0))
	var grip := float(d.get("jig_grip_z", 25.0))
	var cz := float(d.get("collect_z", 45.0))
	var here: Vector3 = main.mock.pos
	var out := [{"p": Vector3(here.x, here.y, safe), "phase": "RAISE"},
		{"p": Vector3(jig.x, jig.y, safe), "phase": "TO_JIG"},
		{"p": Vector3(jig.x, jig.y, safe), "phase": "OPEN_CLAW", "dwell": 0.4},
		{"p": Vector3(jig.x, jig.y, grip), "phase": "LOWER_TO_JIG"},
		{"p": Vector3(jig.x, jig.y, grip), "phase": "GRIP", "dwell": 0.5},
		{"p": Vector3(jig.x, jig.y, grip), "phase": "CONFIRM_GRIP", "confirm": true},
		{"p": Vector3(jig.x, jig.y, travel), "phase": "LIFT_JIG"}]
	var route: Array = d.get("route_xy", []) if d.get("route_xy") is Array else []
	for i in route.size():
		out.append({"p": Vector3(float(route[i][0]), float(route[i][1]), travel), "phase": "SWEEP", "stage": str(i + 1)})
	out += [{"p": Vector3(col.x, col.y, travel), "phase": "TO_COLLECT"},
		{"p": Vector3(col.x, col.y, cz), "phase": "LOWER_TO_COLLECT"},
		{"p": Vector3(col.x, col.y, cz), "phase": "COLLECT", "dwell": float(d.get("collect_dwell_s", 1.0))},
		{"p": Vector3(col.x, col.y, travel), "phase": "LIFT"},
		{"p": Vector3(jig.x, jig.y, travel), "phase": "BACK_TO_JIG"},
		{"p": Vector3(jig.x, jig.y, grip), "phase": "LOWER_JIG"},
		{"p": Vector3(jig.x, jig.y, grip), "phase": "RELEASE_JIG", "dwell": 0.4},
		{"p": Vector3(jig.x, jig.y, safe), "phase": "RAISE_EMPTY"},
		{"p": Vector3(park.x, park.y, safe), "phase": "PARK"}]
	return out

# ------------------------------------------------------------------ the game's mock walking
func _start_walk(kind: String, steps: Array) -> void:
	_walk = steps
	_walk_kind = kind
	_walk_wait = 0.0
	_walk_released = false
	_walk_confirmed = false
	_walk_enter()

func _walk_enter() -> void:
	var s: Dictionary = _walk[0]
	main.mock.set_target(s.p)
	_walk_wait = float(s.get("dwell", 0.0))
	_walk_released = false
	motion_update.emit(_walk_kind, str(s.phase), str(s.get("stage", "")), false,
		{"phase": s.phase, "stage": s.get("stage", ""), "confirming": bool(s.get("confirm", false)), "route": "game_mock"})

func _walk_tick(dt: float) -> void:
	var s: Dictionary = _walk[0]
	var m: MockRobot = main.mock
	var arrived := m.pos.distance_to(s.p) < 1.0 and m.vel.length() < 2.0
	if not arrived:
		return
	if _walk_wait > 0.0:
		_walk_wait -= dt
		return
	if bool(s.get("hold", false)):
		if not _walk_released:
			if not s.has("_held"):
				s["_held"] = true
				motion_update.emit(_walk_kind, "HOLD", str(s.get("stage", "")), true,
					{"phase": "HOLD", "stage": s.get("stage", ""), "holding": true, "route": "game_mock"})
			return
	if bool(s.get("confirm", false)) and not _walk_confirmed:
		return
	_walk.pop_front()
	if _walk.is_empty():
		var kind := _walk_kind
		_walk_kind = ""
		motion_done.emit(kind)
		return
	_walk_enter()

# ------------------------------------------------------------------ messages
func _rid(kind: String) -> String:
	_seq += 1
	return "sm-%s-%d-%d" % [kind, Time.get_ticks_msec(), _seq]

## The voice for a line: the request id ("" = no voice now).
func voice_request(text: String) -> String:
	if inject_fail == "voice":
		return ""
	if homework == null or not homework.speech_available or not homework.link.is_open():
		voice_status = "声なし（文字で表示）" if homework == null or not homework.speech_available else "声: バックエンドに接続中"
		return ""
	var rid := _rid("say")
	if homework.link.send_aux({"type": "homework_say", "request_id": rid, "data": {"text": text}}) != OK:
		return ""
	return rid

func _on_aux(msg: Dictionary) -> void:
	var t := str(msg.get("type", ""))
	var rid := str(msg.get("request_id", ""))
	var data: Dictionary = msg.get("data", {}) if msg.get("data") is Dictionary else {}
	if t == "homework_progress":
		_on_progress(data)
		return
	if not rid.begins_with("sm-"):
		return
	if t == "homework_speech":
		var stream := HomeworkClient.wav_stream(Marshalls.base64_to_raw(str(data.get("wav_base64", ""))))
		voice_credit = str(data.get("credit", ""))
		if on_voice.is_valid():
			on_voice.call(rid, stream, voice_credit)
	elif t == "homework_speech_error" or (t == "homework_error" and rid.begins_with("sm-say")):
		voice_status = "声が出せませんでした: " + str(data.get("message", ""))
		if on_voice_error.is_valid():
			on_voice_error.call(rid, str(data.get("message", "")))
	elif rid == _locate_rid and t in ["homework_locate_result", "homework_locate_error", "homework_error"]:
		_locate_rid = ""
		if t == "homework_locate_result" and bool(data.get("usable", false)):
			var at := located_point(Vector2(float(data.get("u", 0.5)), float(data.get("v", 0.5))))
			located.emit({"u": at.x, "v": at.y, "problem": _help_problem,
				"verified": bool(data.get("verified", false)), "page_check": data.get("page_check")})
		elif t == "homework_locate_result":
			locate_failed.emit("問題の位置がはっきりしないので動かしません: " + str(data.get("reason", "")))
		else:
			locate_failed.emit("問題を読み取れませんでした: " + str(data.get("message", "")))
	elif rid == _explain_rid and t in ["homework_explain_result", "homework_explain_error", "homework_error"]:
		_explain_rid = ""
		if t == "homework_explain_result":
			explained.emit(data)
		else:
			var fb: Dictionary = data.get("fallback", {}) if data.get("fallback") is Dictionary else \
				fallback_explanation(WorksheetCatalog.problem(worksheet, _help_problem), _help_problem)
			explain_failed.emit(str(data.get("message", "解説を作れませんでした")), fb)

func _on_robot_ack(rid: String, ok: bool, payload: Dictionary) -> void:
	if rid == "":
		return
	if rid == _sheet_rid:
		_sheet_rid = ""
		_on_sheet_found(ok, payload)
		return
	if rid == _grade_rid:
		# the link gives up on every command after a few seconds; the reading takes longer
		if not ok and str(payload.get("reason", "")) == "timeout" and not payload.has("command"):
			return
		_grade_rid = ""
		_on_graded_by_reader(ok, payload)
		return
	if rid == _help_rid:
		_help_rid = ""
		if not ok:
			_help_active = false
			motion_fault.emit("help", "アームを動かせませんでした: " + str(payload.get("reason", "")))
	elif rid == _nav_rid:
		_nav_rid = ""
		if not ok:
			navigate_failed.emit(str(payload.get("reason", "移動先を決められません")))
		elif payload.get("u") != null and payload.get("v") != null:
			navigated.emit({"u": float(payload.u), "v": float(payload.v), "problem": _help_problem, "source": "navigate"})
		elif payload.get("xy") is Array and payload.xy.size() == 2:
			navigated.emit({"xy": Vector2(float(payload.xy[0]), float(payload.xy[1])), "problem": _help_problem,
				"source": "navigate"})
		else:
			navigate_failed.emit("移動先が返ってきませんでした")
	elif rid == _cleanup_rid:
		_cleanup_rid = ""
		if not ok:
			_cleanup_active = false
			motion_fault.emit("cleanup", "片付けを始められませんでした: " + str(payload.get("reason", "")))

func _on_robot_message(msg: Dictionary) -> void:
	var t := str(msg.get("type", ""))
	var data: Dictionary = msg.get("data", {}) if msg.get("data") is Dictionary else {}
	if _help_active:
		if t == "homework_approach":
			_on_sequence("help", data)
		elif t == "robot_state" and data.get("homework_approach") is Dictionary:
			_on_sequence("help", data.homework_approach)
	if _cleanup_active:
		if t == "study_cleanup":
			_on_sequence("cleanup", data)
		elif t == "robot_state" and data.get("study_cleanup") is Dictionary:
			_on_sequence("cleanup", data.study_cleanup)

var _last_seq_key := {}

func _on_sequence(kind: String, st: Dictionary) -> void:
	var phase := str(st.get("phase", ""))
	var active := bool(st.get("active", false))
	var started := _help_started if kind == "help" else _cleanup_started
	# robot_state may still carry the previous run's IDLE / FAULT: wait for this run to move
	if not started:
		if active and phase not in ["", "IDLE", "FAULT"]:
			started = true
			if kind == "help":
				_help_started = true
			else:
				_cleanup_started = true
		else:
			return
	var key := "%s|%s|%s|%s|%s" % [phase, st.get("stage", ""), st.get("holding", false), st.get("confirming", false), st.get("waypoint", 0)]
	if _last_seq_key.get(kind, "") != key:
		_last_seq_key[kind] = key
		motion_update.emit(kind, phase, str(st.get("stage", "")), bool(st.get("holding", false)), st)
	if phase == "FAULT" or (not active and str(st.get("last_result", "")) == "fault"):
		_end_sequence(kind)
		motion_fault.emit(kind, str(st.get("error", "止まりました")))
	elif not active and str(st.get("last_result", "")) == "done":
		_end_sequence(kind)
		motion_done.emit(kind)

func _end_sequence(kind: String) -> void:
	_last_seq_key.erase(kind)
	if kind == "help":
		_help_active = false
		_help_started = false
	else:
		_cleanup_active = false
		_cleanup_started = false

func motion_active() -> bool:
	return _help_active or _cleanup_active or not _walk.is_empty()

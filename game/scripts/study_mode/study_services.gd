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
##   camera    : the overview camera + Jev (HomeworkClient's watch with the worksheet),
##               Claude / Codex (locate + explain).
##
## Which robot is not chosen here (#92): it is the one start.sh connected (--real /
## --mock). With the real crane the backend still refuses what is not calibrated.
##
## Robot motion is always one sequence run by the backend (homework_approach with
## stages, study_cleanup_*) under its motion lock, or the game's mock walking its
## own targets: never jogs. Results that come back after `abort()` are ignored.

signal worksheet_seen
signal reading(probs: Array, held: bool, reason: String)
signal located(target: Dictionary)
signal locate_failed(reason: String)
## kind: "help" | "cleanup"; data: the sequence's status
signal motion_update(kind: String, phase: String, stage: String, holding: bool, data: Dictionary)
signal motion_done(kind: String)
signal motion_fault(kind: String, reason: String)
signal explained(result: Dictionary)
signal explain_failed(reason: String, fallback: Dictionary)

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
var _explain_rid := ""
var _help_rid := ""
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
	status = "カメラでプリントを見ています（Jev）"

func watch_stop() -> void:
	var was := watching
	watching = false
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
		reading.emit([null, null, null], true, "occluded")
		return
	reading.emit(_mock_probs.duplicate(), false, "")

func _on_progress(data: Dictionary) -> void:
	if not watching:
		return
	var reason := str(data.get("held_reason", ""))
	var visible = data.get("visible_prob")
	if not seen and reason != "not_visible" and (visible == null or float(visible) >= 0.5):
		mark_seen()
	if not seen:
		return
	var probs: Array = []
	for q in data.get("questions", []) if data.get("questions") is Array else []:
		probs.append(q.get("filled_prob"))
	reading.emit(probs, bool(data.get("held", false)), reason)

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
	var jpeg := StudyClient.encode_jpeg(img, homework.max_image_edge, homework.max_image_bytes)
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

## The dry-run heights (study_mode.height.dry_run), as the backend computes them.
static func dry_run_stages() -> Array:
	var h = GameConfig.get_value("study_mode", "height", {})
	var d: Dictionary = h.get("dry_run", {}) if h is Dictionary and h.get("dry_run") is Dictionary else {}
	var heights: Array = h.get("capture_heights_cm", [10.0, 5.0]) if h is Dictionary else [10.0, 5.0]
	var up := 1.0 if GameConfig.robot().z_up_is_positive else -1.0
	var desk := float(d.get("z_desk_tip", 20.0))
	var per := float(d.get("z_per_cm", 4.0))
	var off := float(d.get("camera_offset_cm", 3.0))
	return [{"name": "10cm", "z": desk + up * (float(heights[0]) - off) * per},
		{"name": "5cm", "z": desk + up * (float(heights[1]) - off) * per},
		{"name": "landing", "z": desk + up * float(d.get("landing_tip_cm", 1.5)) * per}]

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
		_after(2.0, func(): if tok == _token: explained.emit(demo))
		return
	if homework == null or not homework.advice_available:
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
			located.emit({"u": float(data.get("u", 0.5)), "v": float(data.get("v", 0.5)), "problem": _help_problem,
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
	if rid == _help_rid:
		_help_rid = ""
		if not ok:
			_help_active = false
			motion_fault.emit("help", "アームを動かせませんでした: " + str(payload.get("reason", "")))
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

class_name GameModeHud
extends Control
## The game mode's HUD (#138): the score (top left), the clock (top right), what each
## Dial's port is doing (bottom corners), the countdown and the result. It only reads
## the controller.

const YELLOW := Color("ffe03c")
const CYAN := Color("7ae0ff")
const RED := Color("ff6b6b")

var ctl: GameModeController
var _score: Label
var _combo: Label
var _time: Label
var _centre: Label
var _message: Label
var _lane: Dictionary = {}  # side -> Label
var _result: PanelContainer
var _result_text: Label
var _hint: Label
var _shown_score := 0.0

func setup(c: GameModeController) -> void:
	ctl = c
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_score = _label("0", 44, YELLOW, Vector2(24, 8), Vector2(360, 56))
	_combo = _label("", 22, CYAN, Vector2(26, 60), Vector2(360, 30))
	_time = _label("2:30", 44, Color.WHITE, Vector2(896, 8), Vector2(360, 56))
	_time.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_centre = _label("", 120, YELLOW, Vector2(240, 230), Vector2(800, 150))
	_centre.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message = _label("", 22, Color("e8f0ff"), Vector2(140, 386), Vector2(1000, 70))
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for side in GameModeController.SIDES:
		var l := _label("", 15, Color.WHITE, Vector2(4 if side == "left" else 1138, 520), Vector2(138, 86))
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		l.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		_lane[side] = l
	_hint = _label("", 13, Color("8fa3c4"), Vector2(390, 2), Vector2(500, 20))  # above the UFO's rail
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result = StudyHud.panel(Color(0.05, 0.08, 0.22, 0.94), YELLOW, 22, 5)
	_result.position = Vector2(340, 150)
	_result.custom_minimum_size = Vector2(600, 330)
	_result.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_result_text = StudyHud.label("", 26, Color.WHITE, 4)
	_result_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result.add_child(_result_text)
	add_child(_result)
	_result.visible = false

func _label(text: String, size: int, color: Color, pos: Vector2, box: Vector2) -> Label:
	var l := StudyHud.label(text, size, color, maxi(size / 6, 3))
	l.add_theme_color_override("font_outline_color", Color("0a1030"))
	l.position = pos
	l.size = box
	add_child(l)
	return l

static func clock_text(seconds: float) -> String:
	var s := int(ceil(maxf(seconds, 0.0)))
	return "%d:%02d" % [s / 60, s % 60]

## The result screen's lines (also read by the tests).
func result_lines() -> String:
	var s := ctl.score
	var lines := ["RESULT", "", "スコア  %d" % s.score, "カプセル  %d こ    最大コンボ  %d    ジャックポット  %d" % [
		ctl.capsules.finished.size(), s.best_chain, s.jackpots]]
	for side in GameModeController.SIDES:
		var l: GameModeController.Lane = ctl.lanes[side]
		if l.state == "FAULT":
			lines.append("%s の Dial: %s" % ["左" if side == "left" else "右", l.fault])
	return "\n".join(lines)

func _process(dt: float) -> void:
	if ctl == null or not ctl.active():
		return
	_shown_score = move_toward(_shown_score, float(ctl.score.score), maxf(absf(ctl.score.score - _shown_score) * 8.0, 200.0) * dt)
	_score.text = "%d" % int(round(_shown_score))
	var chain := ctl.score.chain_now(ctl.clock)
	var mult := ctl.score.multiplier(ctl.clock)
	_combo.text = ("COMBO %d  x%s" % [chain, str(mult)]) if chain >= 2 else ("JACKPOT チャンス！" if ctl.score.jackpot_armed(ctl.clock) else "")
	_time.text = clock_text(ctl.time_left)
	var late: bool = ctl.phase == "PLAYING" and ctl.time_left <= ctl.warning_s
	_time.add_theme_color_override("font_color", RED if late and int(ctl.time_left * 4.0) % 2 == 0 else
		(YELLOW if ctl.phase == "PLAYING" and ctl.time_left <= ctl.hurry_s else Color.WHITE))
	var centre := ""
	match ctl.phase:
		"IDLE":
			centre = "SUMMON THE UFO"
		"COUNTDOWN":
			centre = str(int(ceil(ctl.countdown_left)))
		"PLAYING":
			if ctl.duration_s - ctl.time_left < 0.8:
				centre = "GO!"
			elif ctl.time_left <= ctl.hurry_s and ctl.time_left > ctl.hurry_s - 1.5:
				centre = "あと %d 秒！" % int(ctl.hurry_s)
		"SETTLING":
			centre = "TIME UP"
		"STOPPED":
			centre = "STOP"
	_centre.text = centre
	_centre.add_theme_font_size_override("font_size", 72 if centre.length() > 4 else 120)
	_message.text = ""
	if ctl.phase == "IDLE":
		_message.text = "クレーンでつかんだカプセルを 左か右の Dial に入れよう\n" + ctl.message
	elif ctl.phase == "STOPPED":
		_message.text = ctl.message
	_result.visible = ctl.phase == "RESULT"
	if _result.visible:
		_result_text.text = result_lines() + "\n\n" + ctl.message
	for side in GameModeController.SIDES:
		var l: GameModeController.Lane = ctl.lanes[side]
		_lane[side].text = ctl.lane_text(side)
		_lane[side].add_theme_color_override("font_color", RED if l.state == "FAULT" else l.color)
	var hint := "Space: 止める   Esc: タイトル"
	if ctl.devices != null and ctl.devices.can_mock_ball():
		hint += "   Mock: Z = 左 / M = 右に入れる"
	elif ctl.devices != null and not ctl.devices.available():
		hint = "周辺機器のハブにつながっていない（devicehub.enabled と ./start.sh）"
	_hint.text = hint

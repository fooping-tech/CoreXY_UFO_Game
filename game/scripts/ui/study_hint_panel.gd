class_name StudyHintPanel
extends PanelContainer
## #334: the finger hint's box after the answer check (HINT_ASK / HINT_THINKING / HINT_GIVING), at the
## top of the screen, under UFOくん's sky (the summary's own box is not up meanwhile):
##   "わからない もんだいの ばんごうを ゆびで おしえてね"
##   a card per problem read (1, 2, 3, ...): the count held now lights up and fills as it is held
##   the hint for the problem picked (UFOくん says the same words), "かんがえ中…" while asked
##   a fist in dots: "グーで おわり"
## Pure presentation: reads the controller only.

const CARD := Vector2(64, 72)
const GAP := 14.0
const YELLOW := Color("ffe03c")
const BLUE := Color("3b7dd8")
const INK := Color("1d2433")

var ctl: StudyModeController
var _title: Label
var _cards: Control
var _hint: Label
var _foot: Label
var _fist: Control
var _t := 0.0

func setup(controller: StudyModeController) -> void:
	ctl = controller
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("eaf6ff")
	sb.border_color = BLUE
	sb.set_border_width_all(5)
	sb.set_corner_radius_all(20)
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 6
	add_theme_stylebox_override("panel", sb)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(v)
	_title = StudyHud.label("", 26, INK)
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_title)
	_cards = Control.new()
	_cards.custom_minimum_size = Vector2(0, CARD.y + 8)
	_cards.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cards.draw.connect(_draw_cards)
	v.add_child(_cards)
	_hint = StudyHud.label("", 24, Color("6b3a00"))
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_hint)
	var foot := HBoxContainer.new()
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fist = Control.new()
	_fist.custom_minimum_size = Vector2(24, 34)
	_fist.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fist.draw.connect(func(): GestureTutorialHud.paint_hand(_fist, Vector2(1, 1), 1.0, "fist"))
	foot.add_child(_fist)
	_foot = StudyHud.label("", 18, Color("4a5a78"))
	foot.add_child(_foot)
	v.add_child(foot)
	visible = false

## What the box says now (also for the tests): [title, hint line, foot].
static func texts(state: String, problem: int, hint: String, picking: int) -> Array:
	var title := "わからない もんだいの ばんごうを ゆびで おしえてね"
	var line := ""
	match state:
		"HINT_THINKING":
			title = "%dばん だね！" % problem
			line = "ヒントを かんがえ中…"
		"HINT_GIVING":
			title = "%dばんの ヒント" % problem
			line = hint
		_:
			if hint != "":
				title = "もっと ヒント？ ばんごうを ゆびで おしえてね"
				line = "%dばんの ヒント: %s" % [problem, hint]
			if picking > 0:
				line = ("%dばん？ そのまま 1びょう…" % picking) + ("\n" + line if line != "" else "")
	return [title, line, "グーで おわり（Enter: つぎへ ／ R: もういちど よむ）"]

func refresh(vs: Vector2) -> void:
	visible = ctl != null and ctl.state in StudyModeController.HINT_STATES
	if not visible:
		return
	var picking := ctl.finger_hint.held if ctl.finger_hint.held > 0 and ctl.state == "HINT_ASK" else 0
	var t := texts(ctl.state, ctl.hint_problem, ctl.hint_text, picking)
	_title.text = t[0]
	_hint.text = t[1]
	_hint.visible = t[1] != ""
	_foot.text = t[2]
	_fist.visible = ctl.state == "HINT_ASK"
	position = Vector2(20, StudyHud.EXPLAIN_Y)
	custom_minimum_size = Vector2(vs.x - 40, 0)
	size = Vector2(vs.x - 40, 0)
	_cards.queue_redraw()

func _process(dt: float) -> void:
	if visible:
		_t += dt
		_cards.queue_redraw()

## A card per problem read; the count held lights up and fills from the bottom as it is held.
func _draw_cards() -> void:
	if ctl == null:
		return
	var nums: Array = ctl.grading.numbers
	var font := ThemeDB.fallback_font
	var held := ctl.finger_hint.held if ctl.state == "HINT_ASK" else -1
	for i in nums.size():
		var n := int(nums[i])
		var r := Rect2(Vector2(i * (CARD.x + GAP), 4), CARD)
		var picked := n == ctl.hint_problem and ctl.state != "HINT_ASK"
		var lit := n == held or picked
		_cards.draw_rect(r, Color("ffffff") if not lit else Color("fff7d6"))
		if n == held and ctl.finger_hint.progress > 0.0:
			var h := r.size.y * ctl.finger_hint.progress
			_cards.draw_rect(Rect2(r.position.x, r.end.y - h, r.size.x, h), YELLOW)
		_cards.draw_rect(r, YELLOW if lit else BLUE, false, 4.0)
		var s := str(n)
		var fs := 44
		var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		_cards.draw_string(font, Vector2(r.position.x + (r.size.x - w) * 0.5, r.position.y + 54), s,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, INK)
		var given := ctl.finger_hint.count_for(n)
		for k in mini(given, 3):  # a dot per hint already given
			_cards.draw_circle(r.position + Vector2(12 + 14 * k, r.size.y - 10), 4.0, Color("e07a00"))
	if ctl.state == "HINT_THINKING":  # three dots going round
		var x0 := nums.size() * (CARD.x + GAP) + 10.0
		for k in 3:
			var a := 0.4 + 0.6 * absf(sin(_t * 4.0 - k * 0.7))
			_cards.draw_circle(Vector2(x0 + k * 18.0, CARD.y * 0.5 + 4), 6.0, Color(BLUE, a))

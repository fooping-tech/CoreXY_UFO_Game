class_name PanelKit
extends RefCounted
## The small parts the settings screen's panels are built from (the calibration panel, the
## device test panel): their colours, a row, a wrapped line, a button that never takes the
## keyboard's focus, a labelled number box. Each panel keeps its own sizes and where the
## part goes; only what was written twice is here.

const YELLOW := Color("ffe03c")
const CYAN := Color("7ae0ff")
const MUTED := Color("8fa3c4")
const BAD := Color("ff8a8a")
const GOOD := Color("9ff0a8")

## A line that wraps at `width`, added to `parent`.
static func wrapped(parent: Node, text: String, size: int, color: Color, outline: int, width: float) -> Label:
	var l := StudyHud.label(text, size, color, outline)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(width, 0)
	parent.add_child(l)
	return l

static func row(parent: Node) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 10)
	parent.add_child(r)
	return r

## A button that is not added anywhere yet (the caller may style it first).
static func button(text: String, font_size: int, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	b.focus_mode = Control.FOCUS_NONE  # Space stays the stop key, never "press the button"
	b.pressed.connect(cb)
	return b

## A number box with its label in front, both added to `parent`.
static func spin(parent: Control, label: String, lo: float, hi: float, step: float, v: float) -> SpinBox:
	parent.add_child(StudyHud.label(label, 16, MUTED, 2))
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = v
	parent.add_child(s)
	return s

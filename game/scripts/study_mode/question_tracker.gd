class_name StudyQuestionTracker
extends RefCounted
## Per-problem state of the worksheet from repeated readings (Jev's per answer box
## probability, or the mock demo's). A reading only says whether something is
## WRITTEN in the box, never whether it is right.
##
##   EMPTY (未着手) -> WRITING (記入中) -> FILLED (記入済み);  HELD (判定保留) shown
##   while a hand / pen covers the sheet or it is not visible: nothing changes then.
##
## A problem becomes FILLED after confirm_readings filled readings in a row and drops
## back when an empty reading follows (erased). The homework is complete only after
## all problems stayed FILLED for complete_readings readings in a row, or when a
## grown-up confirms it (confirm_complete). `complete` turns true once and stays.

const EMPTY := "empty"
const WRITING := "writing"
const FILLED := "filled"
const HELD := "held"

var count := 3
var filled_prob := 0.6
var writing_prob := 0.3
var confirm_readings := 2
var complete_readings := 2
var states: Array[String] = []
var held := false
var held_reason := ""
var complete := false
var completed_by := ""  # "readings" | "manual"
var _streak: Array[int] = []
var _all_streak := 0

func configure(c: Dictionary) -> void:
	filled_prob = float(c.get("filled_prob", filled_prob))
	writing_prob = float(c.get("writing_prob", writing_prob))
	confirm_readings = maxi(int(c.get("confirm_readings", confirm_readings)), 1)
	complete_readings = maxi(int(c.get("complete_readings", complete_readings)), 1)

func reset(n := 3) -> void:
	count = n
	states.clear()
	_streak.clear()
	for i in n:
		states.append(EMPTY)
		_streak.append(0)
	held = false
	held_reason = ""
	complete = false
	completed_by = ""
	_all_streak = 0

## One reading: probs[i] = probability that problem i+1 has a written answer (null =
## no answer for it). Returns the problem numbers that became FILLED with it.
func add_reading(probs: Array, is_held := false, reason := "") -> Array[int]:
	var newly: Array[int] = []
	held = is_held
	held_reason = reason if is_held else ""
	if is_held:
		return newly  # a hand over the answers: keep everything as it was
	for i in mini(probs.size(), count):
		var p = probs[i]
		if p == null:
			continue
		var v := float(p)
		if v >= filled_prob:
			_streak[i] += 1
			if _streak[i] >= confirm_readings and states[i] != FILLED:
				states[i] = FILLED
				newly.append(i + 1)
			elif states[i] != FILLED:
				states[i] = WRITING
		else:
			_streak[i] = 0
			states[i] = WRITING if v >= writing_prob else EMPTY
	if filled_count() == count:
		_all_streak += 1
		if _all_streak >= complete_readings and not complete:
			complete = true
			completed_by = "readings"
	else:
		_all_streak = 0
	return newly

func filled_count() -> int:
	var n := 0
	for s in states:
		if s == FILLED:
			n += 1
	return n

func is_filled(number: int) -> bool:
	return number >= 1 and number <= states.size() and states[number - 1] == FILLED

## What the chip shows: the state, or HELD while the readings are held.
func shown_state(number: int) -> String:
	if number < 1 or number > states.size():
		return EMPTY
	if held and states[number - 1] != FILLED:
		return HELD
	return states[number - 1]

## A grown-up checked the sheet: complete now (the readings may lag behind).
func confirm_complete() -> void:
	for i in count:
		states[i] = FILLED
	if not complete:
		complete = true
		completed_by = "manual"

static func label(state: String) -> String:
	return {EMPTY: "まだ", WRITING: "かいてる", FILLED: "かけた！", HELD: "みえない"}.get(state, state)

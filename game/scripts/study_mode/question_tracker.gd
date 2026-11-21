class_name StudyQuestionTracker
extends RefCounted
## Per-problem state of the worksheet from repeated readings (the worksheet reader's, Jev's per
## answer box probability, or the mock demo's). A reading only says whether something is
## WRITTEN in the box, never whether it is right.
##
##   EMPTY (未着手) -> WRITING (記入中) -> FILLED (記入済み);  HELD (判定保留) shown
##   while a hand / pen covers the sheet or it is not visible: nothing changes then.
##
## The problems are kept by their printed number (#237): a sample sheet's 1..3, or, read from a
## real print (`grow`), every number the reader has seen so far, however many: a number seen
## once stays (a hand over it later does not take it away).
##
## A problem becomes FILLED after confirm_readings filled readings in a row and drops
## back when an empty reading follows (erased). The homework is complete only after
## all problems stayed FILLED for complete_readings readings in a row, or when a
## grown-up confirms it (confirm_complete). `complete` turns true once and stays.

const EMPTY := "empty"
const WRITING := "writing"
const FILLED := "filled"
const HELD := "held"

var numbers: Array[int] = []  # the printed numbers, in order
var count := 0
var filled_prob := 0.6
var writing_prob := 0.3
var confirm_readings := 2
var complete_readings := 2
var states: Array[String] = []  # aligned with numbers
var held := false
var held_reason := ""
var complete := false
var completed_by := ""  # "readings" | "manual"
var from_sheet := false  # the numbers come from the readings of a real print
var _streak: Array[int] = []
var _all_streak := 0

func configure(c: Dictionary) -> void:
	filled_prob = float(c.get("filled_prob", filled_prob))
	writing_prob = float(c.get("writing_prob", writing_prob))
	confirm_readings = maxi(int(c.get("confirm_readings", confirm_readings)), 1)
	complete_readings = maxi(int(c.get("complete_readings", complete_readings)), 1)

## Problems 1..n (a sample sheet).
func reset(n := 3) -> void:
	var nums: Array[int] = []
	for i in n:
		nums.append(i + 1)
	reset_numbers(nums)

func reset_numbers(nums: Array, sheet := false) -> void:
	numbers.clear()
	states.clear()
	_streak.clear()
	for n in nums:
		_add(int(n))
	from_sheet = sheet
	held = false
	held_reason = ""
	complete = false
	completed_by = ""
	_all_streak = 0

func _add(n: int) -> void:
	if n < 1 or n in numbers:
		return
	var at := numbers.size()
	for i in numbers.size():
		if numbers[i] > n:
			at = i
			break
	numbers.insert(at, n)
	states.insert(at, EMPTY)
	_streak.insert(at, 0)
	count = numbers.size()

func index_of(number: int) -> int:
	return numbers.find(number)

## One reading by position: probs[i] = probability that the i-th problem has a written answer
## (null = no answer for it). Returns the problem numbers that became FILLED with it.
func add_reading(probs: Array, is_held := false, reason := "") -> Array[int]:
	var qs: Array = []
	for i in mini(probs.size(), numbers.size()):
		qs.append({"number": numbers[i], "filled_prob": probs[i]})
	return add_numbered(qs, is_held, reason)

## One reading by number: [{number, filled_prob}]. `grow`: a number not known yet is added
## (a real print: its problems are what the reader sees).
func add_numbered(questions: Array, is_held := false, reason := "", grow := false) -> Array[int]:
	var newly: Array[int] = []
	held = is_held
	held_reason = reason if is_held else ""
	if is_held:
		return newly  # a hand over the answers: keep everything as it was
	for q in questions:
		if not q is Dictionary or q.get("number") == null:
			continue
		var n := int(q.number)
		if grow:
			_add(n)
		var i := index_of(n)
		var p = q.get("filled_prob")
		if i < 0 or p == null:
			continue
		var v := float(p)
		if v >= filled_prob:
			_streak[i] += 1
			if _streak[i] >= confirm_readings and states[i] != FILLED:
				states[i] = FILLED
				newly.append(n)
			elif states[i] != FILLED:
				states[i] = WRITING
		else:
			_streak[i] = 0
			states[i] = WRITING if v >= writing_prob else EMPTY
	if count > 0 and filled_count() == count:
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
	var i := index_of(number)
	return i >= 0 and states[i] == FILLED

func has(number: int) -> bool:
	return index_of(number) >= 0

## What the chip shows: the state, or HELD while the readings are held.
func shown_state(number: int) -> String:
	var i := index_of(number)
	if i < 0:
		return EMPTY
	if held and states[i] != FILLED:
		return HELD
	return states[i]

## A grown-up checked the sheet: complete now (the readings may lag behind).
func confirm_complete() -> void:
	for i in count:
		states[i] = FILLED
	if not complete:
		complete = true
		completed_by = "manual"

static func label(state: String) -> String:
	return {EMPTY: "まだ", WRITING: "かいてる", FILLED: "かけた！", HELD: "みえない"}.get(state, state)

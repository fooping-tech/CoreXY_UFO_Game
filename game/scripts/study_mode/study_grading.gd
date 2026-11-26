class_name StudyGrading
extends RefCounted
## The answer check of the study mode (#236, #237): what the worksheet reader said about each
## problem, as the child is told it, and the game reward that follows. Only data: no node, no
## camera, no robot. The controller shows it one problem at a time.
##
## The reader is a model and may be wrong (it has called right answers wrong), so nothing here
## says "wrong":
##   correct  - the server checked the sum and found it right      -> ○ せいかい！
##   review   - incorrect or half written                          -> ？ いっしょに見よう（a hint）
##   unclear  - unreadable, cut off, not read, the reading failed  -> 見えにくかった（no verdict）
## A problem once correct stays correct (a later misreading never takes a reward away), and the
## reward is always worked out again from the verdicts, so a rescan never gives it twice.

const CORRECT := "correct"
const REVIEW := "review"
const UNCLEAR := "unclear"
const PENDING := "pending"  # not shown yet

var numbers: Array[int] = []
var verdicts := {}  # number -> CORRECT / REVIEW / UNCLEAR / PENDING
var answers := {}  # number -> what the child wrote, as read ("" when not read)
## number -> where its answer box is in the picture read ([x1, y1, x2, y2], 0..1000; the problem's
## box when there is no answer box): the ○ is drawn there (#237). Positions only, no answers.
var boxes := {}
var used_help := false
var checked := false  # every problem has been through the check (its summary was reached)
var time_per_correct_s := 10
var time_max_s := 30
## #338: every problem right gets this much more TIME on top (after time_max_s): the "ごほうび
## たくさん おまけ" UFOくん promises. answer_check.perfect_bonus_s (0 = none)
var perfect_bonus_s := 10

func configure(cfg: Dictionary) -> void:
	time_per_correct_s = maxi(int(cfg.get("time_per_correct_s", time_per_correct_s)), 0)
	time_max_s = maxi(int(cfg.get("time_max_s", time_max_s)), 0)
	perfect_bonus_s = maxi(int(cfg.get("perfect_bonus_s", perfect_bonus_s)), 0)

func reset(problem_numbers: Array) -> void:
	numbers.clear()
	verdicts.clear()
	answers.clear()
	boxes.clear()
	for n in problem_numbers:
		numbers.append(int(n))
		verdicts[int(n)] = PENDING
		answers[int(n)] = ""
	used_help = false
	checked = false

## The reader's answer state -> what the child is told.
static func classify(answer_status: String, visible := "full") -> String:
	if visible == "partial":
		return UNCLEAR
	match answer_status:
		"correct":
			return CORRECT
		"incorrect", "partial":
			return REVIEW
	return UNCLEAR  # unreadable, blank (all were written: the reader missed it), unknown

## One reading of the sheet ([{number, answer_status, student_answer?, visible?}]); a problem
## it does not show is unclear. `grow`: a problem not known yet is added (a real print: its
## problems are the ones read). -> the problems whose verdict changed, in order (to be shown).
func apply(problems: Array, grow := false) -> Array[int]:
	var seen := {}
	for p in problems:
		if p is Dictionary and p.get("number") != null and int(p.number) > 0:
			seen[int(p.number)] = p
			if grow and not int(p.number) in numbers:
				numbers.append(int(p.number))
				verdicts[int(p.number)] = PENDING
				answers[int(p.number)] = ""
	numbers.sort()
	var changed: Array[int] = []
	for n in numbers:
		if verdicts.get(n) == CORRECT:
			continue  # never taken back
		var p: Dictionary = seen.get(n, {})
		var v := classify(str(p.get("answer_status", "")), str(p.get("visible", "full"))) if not p.is_empty() else UNCLEAR
		if p.has("student_answer"):
			answers[n] = str(p.student_answer)
		for key in ["answer_box", "box"]:
			if p.get(key) is Array and (p[key] as Array).size() == 4:
				boxes[n] = (p[key] as Array).duplicate()
				break
		if v != verdicts.get(n):
			verdicts[n] = v
			changed.append(n)
		elif verdicts.get(n) == PENDING:
			changed.append(n)
	return changed

## The reading failed altogether: every problem not yet correct is unclear (never wrong).
func fail_all() -> Array[int]:
	var changed: Array[int] = []
	for n in numbers:
		if verdicts.get(n) != CORRECT:
			verdicts[n] = UNCLEAR
			changed.append(n)
	return changed

func count(v: String) -> int:
	var c := 0
	for n in numbers:
		if verdicts.get(n) == v:
			c += 1
	return c

func with_verdict(v: String) -> Array[int]:
	var out: Array[int] = []
	for n in numbers:
		if verdicts.get(n) == v:
			out.append(n)
	return out

## Problems to look at again (a hint) or to read again (unclear).
func to_look_again() -> Array[int]:
	var out: Array[int] = []
	for n in numbers:
		if verdicts.get(n) in [REVIEW, UNCLEAR]:
			out.append(n)
	return out

func all_correct() -> bool:
	return not numbers.is_empty() and count(CORRECT) == numbers.size()

func time_bonus_s() -> int:
	return mini(count(CORRECT) * time_per_correct_s, time_max_s) + perfect_bonus()

## #338: the extra TIME for every problem right (0 otherwise).
func perfect_bonus() -> int:
	return perfect_bonus_s if all_correct() else 0

## #338: which line UFOくん says before the reward. "Wrong" is only REVIEW (the reader said
## incorrect / half written); UNCLEAR (unreadable, cut off, not read) is never counted as wrong:
##   perfect     - every problem right
##   all_review  - none right, at least one to look at again (unclear ones may be among them)
##   some_review - some right and at least one to look at again
##   unclear     - none to look at again, but not all right (some could not be read)
## "" when nothing was checked (no problem read).
func result_kind() -> String:
	if numbers.is_empty():
		return ""
	if all_correct():
		return "perfect"
	if count(REVIEW) == 0:
		return "unclear"
	return "all_review" if count(CORRECT) == 0 else "some_review"

## Every problem checked: one power ticket (HELP and looking again never take it away). #338: so
## even all to look at again gets an item ("ごほうびに アイテムを あげよう").
func power_tickets() -> int:
	return 1 if checked else 0

## What the game takes over (#239 reads only this): the counts and the reward, no answers.
func reward(worksheet_id: String, selected: Array = []) -> Dictionary:
	return {"worksheet_id": worksheet_id, "question_count": numbers.size(), "confirmed_correct": count(CORRECT),
		"needs_review": with_verdict(REVIEW), "unclear": with_verdict(UNCLEAR), "time_bonus_s": time_bonus_s(),
		"perfect_bonus_s": perfect_bonus(), "power_tickets": power_tickets(), "selected_powerups": selected.duplicate(), "used_help": used_help,
		"perfect": all_correct(), "completed_at": int(Time.get_unix_time_from_system())}

## What a verdict looks like: [mark, words].
static func shown(v: String) -> Array:
	match v:
		CORRECT:
			return ["○", "せいかい！"]
		REVIEW:
			return ["？", "いっしょに見よう"]
		UNCLEAR:
			return ["－", "見えにくかった"]
	return ["…", "かくにん中"]

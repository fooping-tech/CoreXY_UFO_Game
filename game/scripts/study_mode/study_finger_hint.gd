class_name StudyFingerHint
extends RefCounted
## #334: the problem's number shown with the fingers after the answer check, and the hints
## already given per problem. Only data: no node, no camera, no robot.
##
## The backend counts the fingers out (hand_control `fingers`: 0..5, -1 = unclear; one hand only).
## A count held hold_ms picks: 1..5 is a problem's number, 0 (a fist, グー) is "no more questions".
## A thumbs-up (pose "thumb") is never a number: it is the answer check's other gesture (#333:
## いいね = read again) and Japanese children show 1 with the index finger. Once picked, the same
## count does nothing more until the hand changes (goes away, or shows another count); a count
## already shown when the step begins (block_current) is not taken either.

const FIST := 0
const NONE := -1
const HISTORY_MAX := 6  # docs/ufo_api_spec.md §5.2

var hold_ms := 1000.0
var held := NONE  # the count being held now (NONE: none / unclear)
var progress := 0.0  # 0..1 of the hold (the HUD's gauge)
var _since_ms := -1.0
var _used := NONE  # a count already acted on (or shown when the step began)
var _block_next := false
## number -> [{hint_level, message, source}]: the hints given for that problem (this story)
var history := {}

func configure(cfg: Dictionary) -> void:
	hold_ms = clampf(float(cfg.get("hold_ms", hold_ms)), 200.0, 5000.0)

func reset() -> void:
	history.clear()
	restart()

## The step begins (again): the hold starts over and whatever is shown now does not count.
func restart() -> void:
	held = NONE
	progress = 0.0
	_since_ms = -1.0
	_used = NONE
	_block_next = true

## One frame: `fingers` from the hand event (NONE without a fresh hand), its `pose`.
## -> the count picked this frame (FIST or 1..5), or NONE.
func tick(fingers: int, pose: String, now_ms: float) -> int:
	var c := fingers if fingers >= 0 and fingers <= 5 and pose != "thumb" else NONE
	if _block_next:
		_block_next = false
		_used = c  # shown when the step began: not taken until the hand changes
	if c != held:
		held = c
		_since_ms = now_ms
		progress = 0.0
		if c != _used:
			_used = NONE
		return NONE
	if c == NONE or c == _used:
		progress = 0.0
		return NONE
	progress = clampf((now_ms - _since_ms) / hold_ms, 0.0, 1.0)
	if progress < 1.0:
		return NONE
	_used = c
	progress = 0.0
	return c

## The hints given for problem n (oldest first), as the tutor's history wants them.
func given(n: int) -> Array:
	var out: Array = []
	for h in history.get(n, []):
		out.append({"hint_level": int(h.get("hint_level", 0)), "message": str(h.get("message", ""))})
	return out.slice(maxi(out.size() - HISTORY_MAX, 0))

func add(n: int, hint_level: int, message: String, source: String) -> void:
	if not history.has(n):
		history[n] = []
	(history[n] as Array).append({"hint_level": clampi(hint_level, 0, 3), "message": message, "source": source})

func count_for(n: int) -> int:
	return (history.get(n, []) as Array).size()

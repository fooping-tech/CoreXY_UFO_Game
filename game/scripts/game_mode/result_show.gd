class_name ResultShow
extends RefCounted
## The result's show (#153, docs/game_mode_spec.md §3.2): one timeline for the whole
## reveal. It is given the breakdown (the truth, fixed once) and only decides what is on
## the screen at each moment: the number shown, which title, which bonus, and the cues.
##
## Everything that has to happen together (a sound, the shake, the flash, the sparks) is
## one cue, emitted at one moment of this timeline: that is what keeps them in step. The
## controller answers a cue by playing all of its parts in the same tick. Nothing here
## waits for a sound, a sprite or a device, and there is no tween or timer of its own:
## reset() is the whole clean-up, so nothing is carried into the next round.
##
## Stages: off -> intro -> count -> hold -> (announce -> absorb -> bonus_count -> bonus_hold)
## per bonus -> wind_up -> final -> settled.
##
## #323: a bonus with capsules on its line (the capsules got, kind by kind; a colour set)
## brings them out one by one while it is announced: a "pop" cue each, in this timeline.
##
## Pure (no nodes): the tests drive advance() directly.

signal cue(name: String, data: Dictionary)

const STAGES := ["off", "intro", "count", "hold", "announce", "absorb", "bonus_count", "bonus_hold", "wind_up", "final", "settled"]

# ---- tuning (config game_mode.result_show) ----
var intro_s := 0.5
var count_s := 1.6
var hold_s := 0.8
var announce_s := 0.9
var absorb_s := 0.45
var bonus_count_s := 0.7
var bonus_hold_s := 0.5
var wind_up_s := 0.35
var final_s := 3.2
## one counting blip per this long while a number runs
var tick_s := 0.055
## a bonus of this many points (or more) gets the strongest effects
var strong_at := 3000

## the truth (ResultBonus.compute); never changed here
var data: Dictionary = {}
var stage := "off"
var t := 0.0
## the number on the screen now (it runs after `banked`)
var shown := 0.0
## what the number is running to: the base score, then plus each bonus as it lands
var banked := 0
var item_index := -1
## 1 -> 0 after a hit: the number's punch (the screen reads it)
var punch := 0.0
## 1 -> 0: the white flash over everything
var flash := 0.0
## seconds since the stage's title came up (the letters arrive one after another)
var title_t := 0.0
## the capsules of the bonus being announced that have popped out so far (#323)
var popped := 0
## every cue emitted, newest last (tests)
var log: Array[String] = []
var _from := 0.0
var _tick_left := 0.0
var _confetti_left := 0.0
var _animated := true

func configure(cfg: Dictionary) -> void:
	for k in ["intro_s", "count_s", "hold_s", "announce_s", "absorb_s", "bonus_count_s", "bonus_hold_s", "wind_up_s", "final_s", "tick_s"]:
		if cfg.get(k) is float or cfg.get(k) is int:
			set(k, clampf(float(cfg[k]), 0.02, 20.0))
	if cfg.get("strong_at") is float or cfg.get("strong_at") is int:
		strong_at = maxi(int(cfg.strong_at), 1)

func reset() -> void:
	data = {}
	stage = "off"
	t = 0.0
	shown = 0.0
	banked = 0
	item_index = -1
	popped = 0
	punch = 0.0
	flash = 0.0
	title_t = 0.0
	log.clear()
	_tick_left = 0.0
	_confetti_left = 0.0

func active() -> bool:
	return stage != "off"

## The show is over: the final score stands still (Enter now starts the next round).
func settled() -> bool:
	return stage == "settled"

func final_score() -> int:
	return int(data.get("final_score", 0))

func items() -> Array:
	return data.get("items", []) if data.get("items") is Array else []

## The bonus being announced / added now ({} = none).
func item() -> Dictionary:
	var list := items()
	return list[item_index] if item_index >= 0 and item_index < list.size() else {}

## 0.3 .. 1: how strong a bonus's effects are (more points, more of everything).
func strength(points: int) -> float:
	return clampf(float(points) / float(strong_at), 0.3, 1.0)

## "TIME UP!" (the round's end, before the result is known). A cue only: SETTLING is the
## controller's and nothing of it waits for this.
func time_up() -> void:
	flash = 1.0
	title_t = 0.0
	_emit("time_up", {})

## The result is known. `animated` false (config effects: false): the final score stands
## at once, with no show.
func begin(breakdown: Dictionary, animated := true) -> void:
	reset()
	data = breakdown
	_animated = animated
	banked = int(data.get("base_score", 0))
	if not animated:
		_settle("plain")
		return
	_enter("intro")
	_emit("reveal", {})

## Enter while it runs: straight to the end (the last picture, no more cues after this one).
func skip(how := "skipped") -> void:
	if active() and not settled():
		_settle(how)

func _settle(how: String) -> void:
	item_index = items().size()
	banked = final_score()
	shown = float(banked)
	punch = 0.0
	flash = 0.0
	_enter("settled")
	_emit("settled", {"how": how})

## Which title is over the number now: "TIME UP!" is the controller's (SETTLING).
func title() -> String:
	match stage:
		"off":
			return ""
		"announce", "absorb", "bonus_count", "bonus_hold":
			return str(item().get("title", "BONUS!"))  # #323: GET! for the capsules, COLOR BONUS! for a set
		"wind_up", "final", "settled":
			return "FINAL SCORE!"
	return "YOUR SCORE"

## The capsules drawn on the line of the bonus being announced (#323; [] = none).
func item_kinds() -> Array:
	return item().get("kinds", []) if item().get("kinds") is Array else []

## When (seconds into the announcement) the `i`th of `n` capsules pops out: one after
## another, all of them out a little before the stage ends.
func pop_at(i: int, n: int) -> float:
	var lead := minf(0.15, announce_s * 0.2)
	var step := minf(0.16, maxf(announce_s - lead - 0.1, 0.0) / float(maxi(n, 1)))
	return lead + step * float(i)

## 0 -> 1: how far the bonus's points have flown into the number (absorb).
func fly_k() -> float:
	if stage == "absorb":
		return clampf(t / absorb_s, 0.0, 1.0)
	return 1.0 if stage in ["bonus_count", "bonus_hold"] else 0.0

## The bonus line is on the screen (announced, not yet swallowed by the number).
func item_showing() -> bool:
	return stage in ["announce", "absorb"]

## The size of the number, as a factor: it shrinks before the final hit, overshoots on
## it and comes to rest a little bigger than before.
func number_k() -> float:
	match stage:
		"wind_up":
			return lerpf(1.0, 0.6, clampf(t / wind_up_s, 0.0, 1.0))
		"final":
			var k := clampf(t / 0.45, 0.0, 1.0)
			return 1.15 + 0.35 * exp(-6.0 * k) * cos(k * 9.0)
		"settled":
			return 1.15
	return 1.0

## The show is at its loudest (the rays spin faster, the lights are full).
func finale() -> bool:
	return stage in ["final", "settled"]

func advance(dt: float) -> void:
	if stage == "off":
		flash = maxf(flash - dt * 3.0, 0.0)
		title_t += dt
		return
	t += dt
	title_t += dt
	punch = maxf(punch - dt * 3.5, 0.0)
	flash = maxf(flash - dt * 3.0, 0.0)
	match stage:
		"intro":
			if t >= intro_s:
				_from = 0.0
				_enter("count", false)
		"count":
			# nothing to count: no long wait over a 0
			var secs := count_s if banked > 0 else minf(count_s, 0.3)
			_run_number(dt, secs)
			if t >= secs:
				shown = float(banked)
				punch = 1.0
				_emit("score_lock", {"points": banked})
				_enter("hold", false)
		"hold":
			if t >= hold_s:
				_next_item()
		"announce":
			# #323: the capsules on the bonus's line pop out one after another; any left
			# when the stage ends come out with its end (the timeline never waits for them)
			var ks := item_kinds()
			while popped < ks.size() and (t >= pop_at(popped, ks.size()) or t >= announce_s):
				_emit("pop", {"i": popped, "n": ks.size(), "kind": str(ks[popped])})
				popped += 1
			if t >= announce_s:
				_enter("absorb", false)
		"absorb":
			if t >= absorb_s:
				var it := item()
				_from = float(banked)
				banked += int(it.get("points", 0))
				punch = 1.0
				flash = 0.55 * strength(int(it.get("points", 0)))
				_emit("bonus_hit", {"id": it.get("id", ""), "points": int(it.get("points", 0)), "strength": strength(int(it.get("points", 0))),
					"group": str(it.get("group", "play")), "kinds": item_kinds()})
				_enter("bonus_count", false)
		"bonus_count":
			_run_number(dt, bonus_count_s)
			if t >= bonus_count_s:
				shown = float(banked)
				_emit("bonus_lock", {"id": item().get("id", ""), "points": banked})
				_enter("bonus_hold", false)
		"bonus_hold":
			if t >= bonus_hold_s:
				_next_item()
		"wind_up":
			if t >= wind_up_s:
				shown = float(banked)
				punch = 1.0
				flash = 1.0 if banked > 0 else 0.0
				_confetti_left = 0.35
				_emit("final", {"points": banked, "strength": 1.0 if banked > 0 else 0.3})
				_enter("final", false)
		"final":
			_confetti_left -= dt
			if _confetti_left <= 0.0 and banked > 0 and t < final_s - 0.6:
				_confetti_left = 0.45
				_emit("confetti", {})
			if t >= final_s:
				_enter("settled", false)
				_emit("settled", {"how": "done"})

## The number runs from `_from` to `banked`: fast at first, slowing into the stop. The
## counting blips are cues, their pitch following how far it has run.
func _run_number(dt: float, secs: float) -> void:
	var k := clampf(t / maxf(secs, 0.01), 0.0, 1.0)
	var e := 1.0 - pow(1.0 - k, 3.0)
	shown = lerpf(_from, float(banked), e)
	if float(banked) - _from < 0.5:
		return
	_tick_left -= dt
	if _tick_left <= 0.0 and k < 1.0:
		_tick_left = tick_s
		_emit("count", {"k": e})

func _next_item() -> void:
	item_index += 1
	if item_index < items().size():
		var it := item()
		popped = 0
		_enter("announce")
		title_t = 0.0  # "BONUS!" jumps out again for each one
		_emit("bonus_show", {"id": it.get("id", ""), "points": int(it.get("points", 0)), "strength": strength(int(it.get("points", 0))),
			"group": str(it.get("group", "play")), "kinds": item_kinds()})
	else:
		_enter("wind_up")
		_emit("wind_up", {})

func _enter(s: String, new_title := true) -> void:
	var before := title()
	stage = s
	t = 0.0
	_tick_left = 0.0
	if new_title and title() != before:
		title_t = 0.0

func _emit(name: String, more: Dictionary) -> void:
	log.append(name)
	if log.size() > 256:
		log.remove_at(0)
	cue.emit(name, more)

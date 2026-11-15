class_name ScoreManager
extends RefCounted
## The score of the 150 s game mode (#138, docs/game_mode_spec.md §6). Pure: no nodes, no
## clock of its own (every call says when), so the tests drive it directly.
##
## A hit scores `table[kind]` times the combo multiplier. The same capsule on the same
## target scores once per `cooldown_s` (a capsule resting on a pin is not a jackpot), and
## a capsule's goal scores once (a late / repeated exit never scores twice). The three
## switches are shared by every capsule: all three lit pays `switch_bonus` and arms the
## jackpot (the centre goal pays `jackpot` instead of `goal_center` for `jackpot_s`).
## The numbers are tuning values (config game_mode.score), not final.

const DEFAULT_TABLE := {"pin": 10, "bumper": 100, "spinner": 200, "star": 500, "switch": 50, "switch_bonus": 1500,
	"goal_left": 100, "goal_right": 100, "goal_center": 1000, "jackpot": 3000}
## chain length -> multiplier (the highest step reached counts)
const DEFAULT_COMBO := [[2, 1.5], [4, 2.0], [6, 3.0]]
## Kinds that build the chain (a pin is multiplied but never builds it: there are too many).
const CHAIN_KINDS := ["bumper", "spinner", "star", "switch"]
const SWITCHES := 3

var table: Dictionary = DEFAULT_TABLE.duplicate()
var combo_steps: Array = DEFAULT_COMBO.duplicate(true)
var combo_window_s := 2.5
var cooldown_s := 0.4
var jackpot_s := 20.0

var score := 0
var chain := 0
var best_chain := 0
var jackpots := 0
var switch_lit: Array[bool] = [false, false, false]
var jackpot_until := -1.0
## kind -> how many times it scored (the result screen)
var counts: Dictionary = {}
var _last_chain_t := -1.0e9
var _cool: Dictionary = {}  # "capsule|target" -> time it last scored
var _goal_done: Dictionary = {}  # capsule id -> true

func configure(cfg: Dictionary) -> void:
	var t = cfg.get("table", {})
	if t is Dictionary:
		for k in t.keys():
			if table.has(k) and (t[k] is float or t[k] is int):
				table[k] = int(t[k])
	if cfg.get("combo") is Array and not (cfg.combo as Array).is_empty():
		combo_steps = (cfg.combo as Array).duplicate(true)
	combo_window_s = float(cfg.get("combo_window_s", combo_window_s))
	cooldown_s = float(cfg.get("cooldown_s", cooldown_s))
	jackpot_s = float(cfg.get("jackpot_s", jackpot_s))

func reset() -> void:
	score = 0
	chain = 0
	best_chain = 0
	jackpots = 0
	switch_lit = [false, false, false]
	jackpot_until = -1.0
	counts = {}
	_last_chain_t = -1.0e9
	_cool = {}
	_goal_done = {}

func multiplier(now: float) -> float:
	if now - _last_chain_t > combo_window_s:
		return 1.0
	var m := 1.0
	for s in combo_steps:
		if chain >= int(s[0]):
			m = maxf(m, float(s[1]))
	return m

func jackpot_armed(now: float) -> bool:
	return now <= jackpot_until

## The chain as shown (0 once the window ran out).
func chain_now(now: float) -> int:
	return chain if now - _last_chain_t <= combo_window_s else 0

## A capsule touched a target. `target` names the one thing hit ("pin_12", "bumper_1",
## "switch_0"...). Returns {points, base, mult, chain, kind, bonus: "" / "switch_bonus"};
## points 0 = not scored (cooldown, unknown kind).
func hit(capsule_id: String, kind: String, target: String, now: float) -> Dictionary:
	var out := {"points": 0, "base": 0, "mult": 1.0, "chain": chain_now(now), "kind": kind, "bonus": ""}
	if not table.has(kind) or kind.begins_with("goal") or kind == "jackpot" or kind == "switch_bonus":
		return out
	var key := capsule_id + "|" + target
	if _cool.has(key) and now - float(_cool[key]) < cooldown_s:
		return out
	_cool[key] = now
	if kind in CHAIN_KINDS:
		chain = chain_now(now) + 1
		_last_chain_t = now
		best_chain = maxi(best_chain, chain)
	var base := int(table[kind])
	if kind == "switch":
		var i := clampi(int(target.get_slice("_", 1)), 0, SWITCHES - 1)
		switch_lit[i] = true
		if not switch_lit.has(false):
			switch_lit = [false, false, false]
			base += int(table["switch_bonus"])
			jackpot_until = now + jackpot_s
			out.bonus = "switch_bonus"
			counts["switch_bonus"] = int(counts.get("switch_bonus", 0)) + 1
	return _add(out, kind, base, now)

## A capsule left through a goal ("left" / "center" / "right"); anything else (the 15 s
## limit, a stop) ends the capsule without a goal score. Once per capsule.
func goal(capsule_id: String, which: String, now: float) -> Dictionary:
	var out := {"points": 0, "base": 0, "mult": 1.0, "chain": chain_now(now), "kind": "goal_" + which, "bonus": ""}
	if _goal_done.has(capsule_id):
		return out
	_goal_done[capsule_id] = true
	var kind := "goal_" + which
	if not table.has(kind):
		return out
	if which == "center" and jackpot_armed(now):
		kind = "jackpot"
		jackpot_until = -1.0
		jackpots += 1
		out.bonus = "jackpot"
	out.kind = kind
	return _add(out, kind, int(table[kind]), now)

func capsule_finished(capsule_id: String) -> bool:
	return _goal_done.has(capsule_id)

## A capsule is gone: its cooldowns are dropped (ids are never reused).
func forget(capsule_id: String) -> void:
	for k in _cool.keys():
		if str(k).begins_with(capsule_id + "|"):
			_cool.erase(k)

func _add(out: Dictionary, kind: String, base: int, now: float) -> Dictionary:
	var m := multiplier(now)
	var pts := int(round(base * m))
	score += pts
	counts[kind] = int(counts.get(kind, 0)) + 1
	out.points = pts
	out.base = base
	out.mult = m
	out.chain = chain_now(now)
	return out

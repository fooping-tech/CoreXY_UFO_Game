class_name ResultBonus
extends RefCounted
## The round's end bonuses (#153, docs/game_mode_spec.md §3.2). Pure: it reads what the
## round left (the score, the capsules) and returns the breakdown the result screen shows.
## It never changes ScoreManager.score: that stays "what was scored while playing".
##
##   final_score = base_score + total_bonus
##   capsule_bonus = capsules taken before the time ran out x capsule_each
##   combo_bonus   = the longest chain x combo_each
##   jackpot_bonus = jackpots won x jackpot_each
##
## These are bonuses of the round's end only. The switch bonus and the jackpot's own points
## were already added by ScoreManager while playing and are part of base_score: nothing
## here adds them again. The numbers are tuning values (config game_mode.result_bonus).

const DEFAULTS := {"capsule_each": 100, "combo_each": 50, "jackpot_each": 500}
## the order they are announced in, with the words shown for each
const ORDER := [["capsule", "カプセルボーナス", "こ"], ["combo", "コンボボーナス", "れんさ"], ["jackpot", "ジャックポットボーナス", "かい"]]

## A capsule counts when a Dial took it before the time ran out. One that landed after
## (taken only to be sent straight back, `late`) does not. The practice capsule is never
## in a round's list (the round starts from a full reset).
static func valid_capsules(finished: Array) -> int:
	var n := 0
	for c in finished:
		if c is Dictionary and not bool(c.get("late", false)):
			n += 1
	return n

static func rates(cfg: Dictionary) -> Dictionary:
	var out := DEFAULTS.duplicate()
	for k in out.keys():
		if cfg.get(k) is float or cfg.get(k) is int:
			out[k] = maxi(int(cfg[k]), 0)
	return out

## The breakdown, fixed once when the round's result is reached.
## `items`: the bonuses that pay something, in the order they are announced.
static func compute(base_score: int, capsules: int, best_chain: int, jackpots: int, cfg: Dictionary = {}) -> Dictionary:
	var r := rates(cfg)
	var counts := {"capsule": maxi(capsules, 0), "combo": maxi(best_chain, 0), "jackpot": maxi(jackpots, 0)}
	var out := {"base_score": maxi(base_score, 0), "capsules": counts.capsule, "best_chain": counts.combo, "jackpots": counts.jackpot,
		"items": []}
	var total := 0
	for o in ORDER:
		var id: String = o[0]
		var each := int(r[id + "_each"])
		var points := int(counts[id]) * each
		out[id + "_bonus"] = points
		total += points
		if points > 0:
			out.items.append({"id": id, "label": o[1], "unit": o[2], "count": int(counts[id]), "each": each, "points": points})
	out["total_bonus"] = total
	out["final_score"] = int(out.base_score) + total
	return out

static func of_round(score: ScoreManager, capsules: CapsuleManager, cfg: Dictionary = {}) -> Dictionary:
	return compute(score.score, valid_capsules(capsules.finished), score.best_chain, score.jackpots, cfg)

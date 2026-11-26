class_name ResultBonus
extends RefCounted
## The round's end bonuses (#153, docs/game_mode_spec.md §3.2). Pure: it reads what the
## round left (the score, the capsules) and returns the breakdown the result screen shows.
## It never changes ScoreManager.score: that stays "what was scored while playing".
##
##   final_score   = base_score + total_bonus
##   capsule_bonus = the capsules taken before the time ran out, kind by kind (#323):
##                   a normal one x capsule_each, a coloured one x colour_each
##   colour_bonus  = the colour sets the capsules made (#323): the same colour, all
##                   different, every colour, and the named sets (SETS)
##   combo_bonus   = the longest chain x combo_each
##   jackpot_bonus = jackpots won x jackpot_each
##
## These are bonuses of the round's end only. The switch bonus and the jackpot's own points
## were already added by ScoreManager while playing and are part of base_score: nothing
## here adds them again. The numbers are tuning values (config game_mode.result_bonus).
##
## The colours are CapsuleKinds.KINDS without "normal": a kind added there is counted, and
## makes sets, with nothing changed here. A named set that needs a kind the game does not
## have (yet) is never made.

const DEFAULTS := {"capsule_each": 100, "colour_each": 200, "combo_each": 50, "jackpot_each": 500}
## the points of each colour set (config game_mode.result_bonus.colour_sets; 0 = left out)
const SET_DEFAULTS := {"pair": 300, "triple": 1000, "watermelon": 500, "steam": 500, "forest": 500, "storm": 500,
	"fireworks": 500, "signal": 1500, "colourful": 1000, "complete": 2000}
## the end bonuses of the play, in the order they are announced, with the words shown for each
const ORDER := [["combo", "コンボボーナス", "れんさ"], ["jackpot", "ジャックポットボーナス", "かい"]]
## the named sets: these kinds, at least one capsule of each. Announced in this order.
## A set whose kinds are not all in CapsuleKinds.KINDS is never made.
const SETS := [
	{"id": "watermelon", "label": "スイカボーナス", "kinds": ["fire", "green"], "say": "あか と みどり で スイカ！"},
	{"id": "steam", "label": "スチームボーナス", "kinds": ["fire", "water"], "say": "ひ と みず で ゆげ もくもく！"},
	{"id": "forest", "label": "もりボーナス", "kinds": ["water", "green"], "say": "みず と みどり で もりが そだつ！"},
	{"id": "storm", "label": "あらしボーナス", "kinds": ["water", "thunder"], "say": "あめ と かみなり で ゴロゴロ あらし！"},
	{"id": "fireworks", "label": "はなびボーナス", "kinds": ["dark", "fire"], "say": "よぞら に ひ で はなび ドーン！"},
	{"id": "signal", "label": "しんごうボーナス", "kinds": ["fire", "thunder", "green"], "say": "あか きいろ みどり で しんごう！"},
]
## all different: at least this many coloured capsules, no colour twice
const COLOURFUL_MIN := 3
## at most this many capsules are drawn on one line of the show
const MAX_SHOWN := 12

## A capsule counts when a Dial took it before the time ran out. One that landed after
## (taken only to be sent straight back, `late`) does not. The practice capsule is never
## in a round's list (the round starts from a full reset).
static func valid_capsules(finished: Array) -> int:
	var n := 0
	for c in finished:
		if c is Dictionary and not bool(c.get("late", false)):
			n += 1
	return n

## The capsules that count (valid_capsules), kind by kind: {"normal": 2, "fire": 1, ...}.
## Only kinds with a capsule are in it; an unknown kind counts as normal.
static func kind_counts(finished: Array) -> Dictionary:
	var out := {}
	for c in finished:
		if c is Dictionary and not bool(c.get("late", false)):
			var k := str(c.get("kind", "normal"))
			if not CapsuleKinds.known(k):
				k = "normal"
			out[k] = int(out.get(k, 0)) + 1
	return out

## The kinds that are a colour (all but normal), in the order of CapsuleKinds.KINDS.
static func colours() -> Array:
	return CapsuleKinds.KINDS.filter(func(k): return k != "normal")

static func rates(cfg: Dictionary) -> Dictionary:
	var out := DEFAULTS.duplicate()
	for k in out.keys():
		if cfg.get(k) is float or cfg.get(k) is int:
			out[k] = maxi(int(cfg[k]), 0)
	var sets := SET_DEFAULTS.duplicate()
	var sc: Dictionary = cfg.get("colour_sets", {}) if cfg.get("colour_sets") is Dictionary else {}
	for k in sets.keys():
		if sc.get(k) is float or sc.get(k) is int:
			sets[k] = maxi(int(sc[k]), 0)
	out["colour_sets"] = sets
	return out

## The breakdown, fixed once when the round's result is reached.
## `kinds`: the capsules kind by kind (kind_counts); the capsules it leaves out are normal.
## `items`: the bonuses that pay something, in the order they are announced. Each:
##   id, label, unit, count, each, points, group ("capsule" / "colour" / "play"),
##   kinds (the capsules drawn on its line), say (a line for the children, may be ""),
##   title (the word over the number while it is announced).
static func compute(base_score: int, capsules: int, best_chain: int, jackpots: int, cfg: Dictionary = {}, kinds: Dictionary = {}) -> Dictionary:
	var r := rates(cfg)
	var counts := {"combo": maxi(best_chain, 0), "jackpot": maxi(jackpots, 0)}
	var by_kind := _by_kind(maxi(capsules, 0), kinds)
	var all := 0
	for k in by_kind.keys():
		all += int(by_kind[k])
	var out := {"base_score": maxi(base_score, 0), "capsules": all, "best_chain": counts.combo, "jackpots": counts.jackpot,
		"kinds": by_kind, "items": []}
	# the capsules, kind by kind: the plain ones first, then each colour
	var capsule_points := 0
	for k in CapsuleKinds.KINDS:
		var n := int(by_kind.get(k, 0))
		var each := int(r.capsule_each) if k == "normal" else int(r.colour_each)
		if n <= 0 or each <= 0:
			continue
		capsule_points += n * each
		out.items.append({"id": "capsule" if k == "normal" else "capsule_" + k, "label": CapsuleKinds.display_name(k), "unit": "こ",
			"count": n, "each": each, "points": n * each, "group": "capsule", "kinds": _repeat(k, n), "say": "", "title": "GET!"})
	out["capsule_bonus"] = capsule_points
	# the colour sets
	var colour_points := 0
	for it in colour_sets(by_kind, r.colour_sets):
		colour_points += int(it.points)
		out.items.append(it)
	out["colour_bonus"] = colour_points
	# the play: the longest chain, the jackpots
	var total := capsule_points + colour_points
	for o in ORDER:
		var id: String = o[0]
		var each := int(r[id + "_each"])
		var points := int(counts[id]) * each
		out[id + "_bonus"] = points
		total += points
		if points > 0:
			out.items.append({"id": id, "label": o[1], "unit": o[2], "count": int(counts[id]), "each": each, "points": points,
				"group": "play", "kinds": [], "say": "", "title": "BONUS!"})
	out["total_bonus"] = total
	out["final_score"] = int(out.base_score) + total
	return out

## The colour sets `by_kind` (kind -> capsules) makes, as items, in the order they are
## announced: the pairs, the threes, the named sets, all different, every colour.
static func colour_sets(by_kind: Dictionary, points: Dictionary = SET_DEFAULTS) -> Array:
	var cols := colours()
	var have: Array = cols.filter(func(k): return int(by_kind.get(k, 0)) > 0)
	var coloured := 0
	for k in have:
		coloured += int(by_kind[k])
	var out: Array = []
	# the same colour: 2 of it (a pair), 3 or more of it (three of a kind)
	var pairs: Array = have.filter(func(k): return int(by_kind[k]) == 2)
	var threes: Array = have.filter(func(k): return int(by_kind[k]) >= 3)
	_add(out, points, "pair", "ペアボーナス", "くみ", pairs.size(), _each_of(pairs, 2), "おなじ いろが 2こ そろった！")
	_add(out, points, "triple", "トリプルボーナス", "くみ", threes.size(), _each_of(threes, 3), "おなじ いろが 3こ そろった！！")
	for s in SETS:
		var needs: Array = s.kinds
		if needs.all(func(k): return k in cols and int(by_kind.get(k, 0)) > 0):
			_add(out, points, str(s.id), str(s.label), "かい", 1, needs.duplicate(), str(s.say))
	# all different: several colours, none of them twice
	if coloured >= COLOURFUL_MIN and have.size() == coloured:
		_add(out, points, "colourful", "カラフルボーナス", "かい", 1, have.duplicate(), "ぜんぶ ちがう いろ！ カラフル！")
	# every colour the game has
	if cols.size() >= 2 and have.size() == cols.size():
		_add(out, points, "complete", "コンプリートボーナス", "かい", 1, cols.duplicate(), "ぜんぶの いろを あつめた！ コンプリート！")
	return out

static func _add(out: Array, points: Dictionary, id: String, label: String, unit: String, count: int, kinds: Array, say: String) -> void:
	var each := int(points.get(id, 0))
	if count <= 0 or each <= 0:
		return
	out.append({"id": id, "label": label, "unit": unit, "count": count, "each": each, "points": count * each, "group": "colour",
		"kinds": kinds.slice(0, MAX_SHOWN), "say": say, "title": "COLOR BONUS!"})

## each of `kinds`, `n` times ([fire, water], 2 -> [fire, fire, water, water])
static func _each_of(kinds: Array, n: int) -> Array:
	var out: Array = []
	for k in kinds:
		out.append_array(_repeat(k, n))
	return out

static func _repeat(kind: String, n: int) -> Array:
	var out: Array = []
	for i in mini(n, MAX_SHOWN):
		out.append(kind)
	return out

## The capsules kind by kind; the ones `kinds` does not account for are normal.
static func _by_kind(capsules: int, kinds: Dictionary) -> Dictionary:
	var out := {}
	var known := 0
	for k in kinds.keys():
		var n := maxi(int(kinds[k]), 0)
		var kk := str(k) if CapsuleKinds.known(str(k)) else "normal"
		if n > 0:
			out[kk] = int(out.get(kk, 0)) + n
			known += n
	if capsules > known:
		out["normal"] = int(out.get("normal", 0)) + capsules - known
	return out

static func of_round(score: ScoreManager, capsules: CapsuleManager, cfg: Dictionary = {}) -> Dictionary:
	return compute(score.score, valid_capsules(capsules.finished), score.best_chain, score.jackpots, cfg, kind_counts(capsules.finished))

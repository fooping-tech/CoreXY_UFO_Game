class_name GestureTutorialSteps
extends RefCounted
## The practice before the score game (#149), as data: what each step shows, says and
## waits for. The logic (GestureTutorialController) and the screen (GestureTutorialHud)
## read these; nothing about how the hand is read is written into them.
##
## A step: {id, kind, title, sub, say, art, ...}
##   kind  summon    UFOくん's spell and greeting; goes on by itself
##         pose      a hand shape (`poses`) held for hold_s
##         pinch     thumb and `finger` together, held for hold_s
##         move      really steering: the hand stick ACTIVE and asking for speed for move_s.
##                   When the robot may not be moved (`gate`), the hand alone: `by` = "hand"
##                   (the pinch carried move_dist across the picture) or "pose" (the shape held)
##         grab      the claw's "close" shape of the hand scheme: the claw request itself
##                   when the robot may be moved, else the shape held
##         info      a picture and spoken lines; goes on by itself (said to be an explanation)
##         practice  one real capsule through a Dial and back (the game's own lane machine)
##   future  true = the step shows a way to play that is not built yet: the hand shape is
##           judged, nothing new moves, and the screen says so (none now; a config may set it)
## The easy mode's steps (#169: easy_grab, easy_one, easy_two) teach the shapes the round
## reads, with the same hold: in these steps only the hand is judged and nothing moves by
## itself; the practice capsule that follows is played with the real easy controls.
##
## Which steps, in which order: MODES[mode][hand scheme]. Config `game_mode.tutorial`:
## `mode` picks the mode, `steps` overrides a step's values by id, `modes` the orders.

const DEFAULT_MODE := "hard"
const MODE_NAMES := {"hard": "むずかしい モード", "easy": "かんたん モード"}
## what the hand shapes are called on the screen
const POSE_NAMES := {"open": "パー", "fist": "グー", "peace": "チョキ", "point": "ゆびさし", "thumb": "グー"}

const STEPS := {
	"summon": {"kind": "summon", "art": "summon", "min_s": 3.0,
		"title": "ベントラベントラスペースピープル！",
		"sub": "昭和のオカルトを 令和の技術で 完全再現！",
		"say": ["ベントラベントラスペースピープル！", "さあ、ぼくと ゲームを はじめよう！"]},
	"open": {"kind": "pose", "art": "open", "poses": ["open"], "hold_s": 0.6,
		"title": "てを ひらいて パー！",
		"sub": "カメラに てを みせてね（どちらの てでも いいよ）",
		"say": ["てを ひらいて、パー！"]},
	"pinch": {"kind": "pinch", "art": "pinch", "finger": "index", "hold_s": 0.5,
		"title": "おやゆびと ひとさしゆびを くっつけよう！",
		"sub": "UFOくんと シンクロ！",
		"say": ["おやゆびと、ひとさしゆびを、くっつけよう！"]},
	"move": {"kind": "move", "art": "move", "by": "hand", "move_s": 0.5, "move_dist": 0.12,
		"title": "そのまま てを うごかそう！",
		"sub": "つまんだまま うごかすと UFOくんも うごくよ。はなすと とまるよ",
		"say": ["そのまま、てを、うごかそう！"]},
	"point": {"kind": "pose", "art": "point", "poses": ["point"], "hold_s": 0.5,
		"title": "ひとさしゆびで ゆびさそう！",
		"sub": "UFOくんと シンクロ！",
		"say": ["ひとさしゆびで、ゆびさそう！"]},
	"point_move": {"kind": "move", "art": "point_move", "by": "pose", "poses": ["point"], "move_s": 0.8,
		"title": "ゆびを さした ほうへ うごかそう！",
		"sub": "ゆびの むきに UFOくんが うごくよ。ゆびを まげると とまるよ",
		"say": ["ゆびを さした ほうへ、うごかそう！"]},
	"grab": {"kind": "grab", "art": "grab", "hold_s": 0.5,
		"title": "{pose}で キャッチ！",
		"sub": "アームの つめが とじるよ",
		"say": ["{pose}で、キャッチ！"]},
	"easy_grab": {"kind": "pose", "art": "easy_grab", "poses": ["fist", "thumb"], "hold_s": 0.6,
		"title": "グーで キャッチ！",
		"sub": "ゲームでは UFOくんが じどうで おりて つかんで あがるよ（いまは ての れんしゅうだけ）",
		"say": ["グーで、キャッチ！"]},
	"easy_one": {"kind": "pose", "art": "easy_one", "poses": ["point"], "hold_s": 0.6,
		"title": "ゆび 1ぽんで ひだりの 1ごうきへ！",
		"sub": "つかんだ あと、いちど パーに してから ゆびを 1ぽん。じどうで はこんで いれるよ",
		"say": ["ゆび、いっぽんで、ひだりへ！"]},
	"easy_two": {"kind": "pose", "art": "easy_two", "poses": ["peace"], "hold_s": 0.6,
		"title": "ゆび 2ほんで みぎの 2ごうきへ！",
		"sub": "つかんだ あと、いちど パーに してから ゆびを 2ほん。じどうで はこんで いれるよ",
		"say": ["ゆび、にほんで、みぎへ！"]},
	"rules": {"kind": "info", "art": "rules", "min_s": 6.0,
		"title": "カプセルを ポータルに いれると とくてん！",
		"sub": "いれた カプセルは おなじ ポータルから かえってくるよ",
		"say": ["カプセルを、ポータルに いれると、とくてん！", "やってみよう！"]},
	"practice": {"kind": "practice", "art": "practice",
		"title": "カプセルを ひとつ いれてみよう！",
		"sub": "ひだりの 1ごうき か みぎの 2ごうき、すきな ほうに いれてね",
		"sub_easy": "グーで キャッチ → パー → ゆび 1ぽん（ひだり）か 2ほん（みぎ）で いれてね",
		"say": ["カプセルを、ひとつ、いれてみよう！"]},
}

## the extra shapes shown small beside the grab step: [art, words], by hand scheme
const GRAB_HINTS := {
	"pinch_joystick": [["peace", "ピースで ひらく"], ["pinch_down", "てのこうを うえに して つまむと じょうげ"]],
	"pose_direction": [["open", "パーで ひらく"], ["thumb", "おやゆびを うえ・したで じょうげ"]],
}

const MODES := {
	"hard": {
		"pinch_joystick": ["summon", "open", "pinch", "move", "grab", "rules", "practice"],
		"pose_direction": ["summon", "open", "point", "point_move", "grab", "rules", "practice"],
	},
	"easy": {
		# the easy mode is the pinch joystick's only (another hand scheme plays the hard mode)
		"pinch_joystick": ["summon", "open", "pinch", "move", "easy_grab", "easy_one", "easy_two", "rules", "practice"],
	},
}

## The steps of `mode` for the hand scheme `scheme_id`, each a full Dictionary. `claw_poses`
## is the scheme's own table (hand shape -> "closed" / "open"): the grab step asks for the
## shape that closes the claw, whatever the scheme calls it. cfg = config game_mode.tutorial.
static func resolve(cfg: Dictionary, mode: String, scheme_id: String, claw_poses: Dictionary) -> Array:
	var modes: Dictionary = MODES.duplicate(true)
	if cfg.get("modes") is Dictionary:
		for m in cfg.modes.keys():
			if cfg.modes[m] is Dictionary:
				var merged: Dictionary = modes.get(m, {})
				merged.merge(cfg.modes[m], true)
				modes[m] = merged
	var by_scheme: Dictionary = modes.get(mode, modes[DEFAULT_MODE])
	var ids: Array = by_scheme.get(scheme_id, by_scheme.get("pinch_joystick", []))
	var over: Dictionary = cfg.get("steps", {}) if cfg.get("steps") is Dictionary else {}
	var out: Array = []
	for id in ids:
		if not STEPS.has(id) and not over.has(id):
			continue
		var s: Dictionary = (STEPS.get(id, {}) as Dictionary).duplicate(true)
		if over.get(id) is Dictionary:
			s.merge(over[id], true)
		s["id"] = str(id)
		if str(s.get("kind", "")) == "grab":
			var poses: Array = []
			for p in claw_poses.keys():
				if str(claw_poses[p]) == "closed":
					poses.append(str(p))
			if not s.has("poses"):
				s["poses"] = poses
			var shown: String = str(POSE_NAMES.get(str(s.poses[0]) if not s.poses.is_empty() else "fist", "グー"))
			s["pose_name"] = shown
			s["title"] = str(s.get("title", "")).replace("{pose}", shown)
			var said: Array = []
			for line in s.get("say", []):
				said.append(str(line).replace("{pose}", shown))
			s["say"] = said
			s["hints"] = GRAB_HINTS.get(scheme_id, [])
			if not s.has("art_pose"):
				s["art_pose"] = str(s.poses[0]) if not s.poses.is_empty() else "fist"
		out.append(s)
	return out

## How many of the steps are counted in "れんしゅう n / N" (the spell is not one).
static func counted(steps: Array) -> int:
	var n := 0
	for s in steps:
		if str(s.get("kind", "")) != "summon":
			n += 1
	return n

## The number shown for step `index` (0 = not counted).
static func number_of(steps: Array, index: int) -> int:
	if index < 0 or index >= steps.size() or str(steps[index].get("kind", "")) == "summon":
		return 0
	var n := 0
	for i in index + 1:
		if str(steps[i].get("kind", "")) != "summon":
			n += 1
	return n

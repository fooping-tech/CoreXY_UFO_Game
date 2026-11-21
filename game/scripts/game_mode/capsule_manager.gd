class_name CapsuleManager
extends RefCounted
## The capsules of the game mode (#138): each real capsule a Dial holds is one record,
## tied to where it came from (source_dial, the hub session, the Dial's cycle), so its
## score counts once and it goes back out of the same Dial. One per Dial, two at most.

const MAX_ACTIVE := 2

## capsule_id -> record
var active: Dictionary = {}
var finished: Array[Dictionary] = []
var _n := 0

## null when that Dial already has one (or two are in play): the caller ignores the event.
func create(source_dial: int, session: int, cycle: int, drop_x: float, late := false):
	if active.size() >= MAX_ACTIVE or of_dial(source_dial) != null:
		return null
	_n += 1
	var c := {"capsule_id": "c%d-%02x-%d-%d" % [session, source_dial, cycle, _n], "source_dial": source_dial,
		"session": session, "cycle": cycle, "drop_x": drop_x, "late": late, "orphaned": false, "score": 0,
		"goal": "", "release": ""}
	active[c.capsule_id] = c
	return c

func of_dial(source_dial: int):
	for c in active.values():
		if c.source_dial == source_dial:
			return c
	return null

func get_capsule(id: String):
	return active.get(id)

## release: "done" / "failed" / "none" (never asked) / "stopped"
func finish(id: String, release: String) -> void:
	if not active.has(id):
		return
	var c: Dictionary = active[id]
	c.release = release
	active.erase(id)
	finished.append(c)

func reset() -> void:
	active = {}
	finished = []

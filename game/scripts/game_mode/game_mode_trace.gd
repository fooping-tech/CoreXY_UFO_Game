class_name GameModeTrace
extends RefCounted
## The event trace of the game mode (#138, docs/game_mode_spec.md §9): one row per thing
## that happened (a device event, a command and its answer, a state change, a score), so a
## run can be checked against UFO-DeviceHub's own trace by session / dial / cycle. Kept in
## memory (the last ROWS_MAX) and, when a path is given, appended to a JSON Lines file.
## No personal data: ids, states, numbers.

const ROWS_MAX := 4000
const FIELDS := ["t_ms", "game_t", "session_id", "source_dial", "cycle", "capsule_id", "event", "command_id", "result",
	"game_state", "lane_state", "physics_position", "score_delta", "effect_id", "led_command", "release_status", "breakdown"]

var rows: Array[Dictionary] = []
var path := ""
var _file: FileAccess

func open(p: String) -> void:
	close()
	path = p
	if p == "":
		return
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	_file = FileAccess.open(p, FileAccess.WRITE)
	if _file == null:
		push_warning("game mode: cannot write the trace to %s" % p)
		path = ""

func close() -> void:
	if _file != null:
		_file.close()
		_file = null

func add(row: Dictionary) -> void:
	var r := {}
	for k in FIELDS:
		r[k] = row.get(k)
	r["t_ms"] = Time.get_ticks_msec()
	rows.append(r)
	if rows.size() > ROWS_MAX:
		rows.remove_at(0)
	if _file != null:
		_file.store_line(JSON.stringify(r))
		_file.flush()

## The rows of one event name (tests).
func named(event: String) -> Array:
	return rows.filter(func(r): return r.event == event)

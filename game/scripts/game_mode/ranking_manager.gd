class_name RankingManager
extends RefCounted
## The score game's high scores (#155, docs/game_mode_spec.md §3.3): the ten best final
## scores, kept in a text file so they are still there after a restart. No name, no
## nickname, nothing a player types: a record is a score, when it was made and an id.
##
##   - higher score first; with the same score the one made first stays above
##   - a score of 0 is not a record; one that would be 11th or lower is not kept
##   - one round, one record: the round's id is remembered, so asking twice changes nothing
##
## The file (tab separated, UTF-8, a header line):  rank  score  timestamp  id
## `rank` is written for a person reading the file; it is worked out again on reading, never
## trusted. A missing file is an empty ranking. A line that cannot be read is skipped (the
## file as it was is kept beside it as <file>.bad) and nothing here ever stops the game: a
## file that cannot be written leaves the ranking in memory, with `save_error` saying why.

const MAX := 10
const DEFAULT_PATH := "user://game_mode/rankings.tsv"
const HEADER := "rank\tscore\ttimestamp\tid"
## a score beyond this is not a score (a damaged line)
const SCORE_LIMIT := 999999999999

## "" = kept in memory only (tests, a ranking that must not touch the disk)
var path := DEFAULT_PATH
## the records, best first: {score: int, timestamp: String, id: String}
var entries: Array[Dictionary] = []
## why the last load_file skipped something ("" = it read cleanly, or there was no file)
var load_error := ""
## why the last save_file failed ("" = it was written)
var save_error := ""
## ids already asked about in this run (in the ranking or not): never counted twice
var _asked: Dictionary = {}

func clear() -> void:
	entries = []
	load_error = ""
	save_error = ""
	_asked = {}

## Reads the file. Always leaves a valid ranking (empty when there is nothing to read).
## Records the file does not have yet (the last save failed) are never thrown away by a
## reload: the save is tried again, and while it still fails what is in memory stays.
func load_file() -> void:
	if path == "":
		return  # kept in memory only: there is nothing to read, and what is here stays
	if save_error != "" and not save_file():
		return
	entries = []
	load_error = ""
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		load_error = "読めない（%s）" % error_string(FileAccess.get_open_error())
		return
	var text := f.get_as_text()
	f.close()
	var skipped := parse(text)
	if skipped > 0:
		load_error = "%d 行を読み飛ばした" % skipped
		DirAccess.copy_absolute(path, path + ".bad")  # what was there is not lost by the next save

## The ranking from the file's text. Returns how many lines could not be used.
func parse(text: String) -> int:
	entries = []
	var skipped := 0
	var seen := {}
	var rows: Array[Dictionary] = []
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line == "" or line == HEADER:
			continue
		var cols := line.split("\t")
		# rank, score, timestamp, id; the rank is not read
		if cols.size() != 4 or not cols[1].is_valid_int() or cols[3].strip_edges() == "":
			skipped += 1
			continue
		var score := int(cols[1])
		var id := cols[3].strip_edges()
		if score <= 0 or score > SCORE_LIMIT or seen.has(id):
			skipped += 1
			continue
		seen[id] = true
		rows.append({"score": score, "timestamp": cols[2].strip_edges(), "id": id, "order": rows.size()})
	# the file's own order breaks a tie (it was written best first, the earlier of two equal scores above)
	rows.sort_custom(func(a, b): return a.score > b.score or (a.score == b.score and a.order < b.order))
	for r in rows.slice(0, MAX):
		entries.append({"score": r.score, "timestamp": r.timestamp, "id": r.id})
	return skipped

func to_text() -> String:
	var lines: Array[String] = [HEADER]
	for i in entries.size():
		var e: Dictionary = entries[i]
		lines.append("%d\t%d\t%s\t%s" % [i + 1, int(e.score), str(e.timestamp), str(e.id)])
	return "\n".join(lines) + "\n"

## Writes the file (to a temporary one first, then over the old one). false = not written.
func save_file() -> bool:
	save_error = ""
	if path == "":
		return true
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := path + ".tmp"
	var text := to_text()
	var why := _write(tmp, text)
	# the old file is replaced only by a temporary file that reads back whole (a full disk,
	# a write cut short: the records already saved stay as they are)
	if why == "" and FileAccess.get_file_as_string(tmp) != text:
		why = "書いた内容を確かめられない"
	if why != "":
		save_error = "書けない（%s）" % why
		if FileAccess.file_exists(tmp):
			DirAccess.remove_absolute(tmp)
		return false
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		save_error = "書けない（%s）" % error_string(err)
		return false
	return true

## Writes `text` to `tmp`. Returns why it could not ("" = written, as far as the file says).
func _write(tmp: String, text: String) -> String:
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return error_string(FileAccess.get_open_error())
	var ok := f.store_string(text)
	f.flush()
	var err := f.get_error()
	f.close()
	return "" if ok and err == OK else error_string(err if err != OK else ERR_FILE_CANT_WRITE)

## Where a score would stand now (1 .. 10), 0 = not in the ranking. A tie goes below the
## records already there.
func rank_for(score: int) -> int:
	if score <= 0:
		return 0
	var at := 0
	while at < entries.size() and int(entries[at].score) >= score:
		at += 1
	return at + 1 if at < MAX else 0

## The rank a record of this id holds now (0 = it is not in the ranking).
func rank_of(id: String) -> int:
	for i in entries.size():
		if str(entries[i].id) == id:
			return i + 1
	return 0

## A finished round's final score. Returns its rank (1 .. 10), or 0 when it is not a record
## (0 points, 11th or lower) or this id was already asked about. The file is written only
## when the ranking changed.
func submit(score: int, id: String, timestamp := "") -> int:
	if id == "" or _asked.has(id) or rank_of(id) > 0:
		return 0
	_asked[id] = true
	var rank := rank_for(score)
	if rank == 0:
		return 0
	entries.insert(rank - 1, {"score": score, "timestamp": timestamp if timestamp != "" else now_text(), "id": id})
	if entries.size() > MAX:
		entries.resize(MAX)
	save_file()
	return rank

## The ten places as shown: {rank, score (0 = no record yet), id}.
func rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in MAX:
		var e: Dictionary = entries[i] if i < entries.size() else {}
		out.append({"rank": i + 1, "score": int(e.get("score", 0)), "id": str(e.get("id", ""))})
	return out

static func now_text() -> String:
	return Time.get_datetime_string_from_system(false, false)

## An id for one round: when it started and a random part (no two rounds share one).
static func new_id() -> String:
	return "%d-%d-%08x" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec() % 1000000, randi()]

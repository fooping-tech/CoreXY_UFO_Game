class_name Sfx
extends Node
## Motion sound effects: one looping voice each for sideways movement, the UFO
## rising and the UFO sinking. A voice fades in while its intensity (0..1, from
## the physics) is up and fades out when the motion stops; moving faster raises
## the pitch a little.
##
## The MP3s come from 効果音ラボ (soundeffect-lab.info). Its terms forbid
## redistributing the files, so they are NOT in the repository: put them in
## game/assets/audio/ yourself (see game/assets/audio/SOURCES.md). They are read
## as raw bytes (no import step); a missing file just means silence.

const VOICES := ["move", "up", "down"]
const FADE_IN_S := 0.08
const FADE_OUT_S := 0.35
const SILENT_DB := -60.0

var enabled := true
## Overall level in dB (config audio.volume_db).
var volume_db := -8.0

var _players: Dictionary = {}  # voice -> AudioStreamPlayer
var _level: Dictionary = {}    # voice -> current linear gain 0..1
var _files: Dictionary = {}    # voice -> path it was loaded from ("" = missing)

func _ready() -> void:
	var dir := str(GameConfig.get_value("audio", "dir", "res://assets/audio"))
	enabled = bool(GameConfig.get_value("audio", "enabled", true))
	volume_db = float(GameConfig.get_value("audio", "volume_db", -8.0))
	for v in VOICES:
		var player := AudioStreamPlayer.new()
		player.name = "Sfx_" + v
		player.volume_db = SILENT_DB
		add_child(player)
		_players[v] = player
		_level[v] = 0.0
		var file := str(GameConfig.get_value("audio", v, ""))
		var path := dir.path_join(file) if file != "" else ""
		player.stream = load_mp3(path)
		_files[v] = path if player.stream != null else ""

## An AudioStreamMP3 from a raw .mp3 file (looping), or null if it is missing.
static func load_mp3(path: String) -> AudioStreamMP3:
	if path == "" or not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var s := AudioStreamMP3.new()
	s.data = bytes
	s.loop = true
	return s

func loaded_count() -> int:
	var n := 0
	for v in VOICES:
		if _players[v].stream != null:
			n += 1
	return n

func level(voice: String) -> float:
	return float(_level.get(voice, 0.0))

## Called every render frame with the motion intensities (0..1).
func update_sfx(move_i: float, up_i: float, down_i: float, dt: float) -> void:
	var want := {"move": move_i, "up": up_i, "down": down_i}
	for v in VOICES:
		var target: float = clampf(want[v], 0.0, 1.0) if enabled else 0.0
		var cur: float = _level[v]
		var rate := (1.0 / FADE_IN_S) if target > cur else (1.0 / FADE_OUT_S)
		cur = move_toward(cur, target, rate * dt)
		_level[v] = cur
		var p: AudioStreamPlayer = _players[v]
		if p.stream == null:
			continue
		if cur > 0.001:
			p.volume_db = volume_db + linear_to_db(cur)
			p.pitch_scale = 1.0 + 0.2 * cur if v == "move" else 1.0
			if not p.playing:
				p.play()
		elif p.playing:
			p.stop()

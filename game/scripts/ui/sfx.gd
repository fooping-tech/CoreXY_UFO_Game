class_name Sfx
extends Node
## Motion sound effects: one looping voice each for sideways movement, the UFO
## rising and the UFO sinking. A voice fades in while its intensity (0..1, from
## the physics) is up and fades out when the motion stops; moving faster raises
## the pitch a little.
##
## The MP3s in game/assets/audio/ come from 効果音ラボ (soundeffect-lab.info):
## built into the game as its sounds, which its terms allow (GitHub included);
## they must not be handed out on their own (see game/assets/audio/SOURCES.md).
## They are read as raw bytes (no import step); a missing file just means silence.

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

# ------------------------------------------------------------ one-shot cues
## Hand joystick cues: "hand" (an open hand is seen), "pinch" (the pinch is
## caught), "release" (the fingers opened: a normal end of steering) and
## "lost" (control was cut: hand lost, two hands, stale events...). Synthesised 8-bit blips (a
## square wave with a short envelope), so they need no file; a file named in
## audio.cue_<name> (in audio.dir, mp3) replaces one.
const CUE_RATE := 22050
const CUE_NOTES := {
	"hand": [[784.0, 0.06]],                           # "pon" (quiet)
	"pinch": [[988.0, 0.05], [1480.0, 0.11]],          # "pi-pon!" up
	"release": [[1480.0, 0.05], [988.0, 0.11]],        # "pon-pi" down: the pinch reversed
	"lost": [[523.0, 0.08], [392.0, 0.08], [262.0, 0.16]],  # "bu-bu-buu" down
}
## Level of each cue relative to audio.volume_db.
const CUE_GAIN_DB := {"hand": -8.0, "pinch": 0.0, "release": -3.0, "lost": 0.0}
## Every cue played, newest last (tests / debug; capped).
var cue_log: Array[String] = []
var _cue_player: AudioStreamPlayer
var _cues: Dictionary = {}
## Name of the cue played last (tests / debug).
var last_cue := ""

func _enter_tree() -> void:
	_cue_player = AudioStreamPlayer.new()
	_cue_player.name = "Sfx_cue"
	add_child(_cue_player)
	var dir := str(GameConfig.get_value("audio", "dir", "res://assets/audio"))
	for cue in CUE_NOTES.keys():
		var file := str(GameConfig.get_value("audio", "cue_" + cue, ""))
		var s: AudioStream = load_mp3(dir.path_join(file)) if file != "" else null
		if s is AudioStreamMP3:
			s.loop = false
		_cues[cue] = s if s != null else synth_blips(CUE_NOTES[cue])

func play_cue(cue: String) -> void:
	last_cue = cue
	cue_log.append(cue)
	if cue_log.size() > 32:
		cue_log.remove_at(0)
	if not enabled or not _cues.has(cue):
		return
	_cue_player.stream = _cues[cue]
	_cue_player.volume_db = volume_db + float(CUE_GAIN_DB.get(cue, 0.0))
	_cue_player.play()

func cue_stream(cue: String) -> AudioStream:
	return _cues.get(cue)

## [[frequency Hz, seconds], ...] -> a 16-bit mono square-wave AudioStreamWAV.
static func synth_blips(notes: Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	for n in notes:
		var freq: float = n[0]
		var count := int(float(n[1]) * CUE_RATE)
		for i in range(count):
			var t := float(i) / CUE_RATE
			var env := minf(t / 0.004, 1.0) * (1.0 - float(i) / count) ** 0.6  # click-free attack, fading tail
			var sq := 1.0 if fmod(t * freq, 1.0) < 0.5 else -1.0
			var v := int(clampf(sq * env * 0.45, -1.0, 1.0) * 32767.0)
			data.append(v & 0xFF)
			data.append((v >> 8) & 0xFF)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = CUE_RATE
	w.stereo = false
	w.data = data
	return w

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

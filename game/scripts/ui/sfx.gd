class_name Sfx
extends Node
## Motion sound effects (#327): while the crane moves, one short sound every
## second. The arm going up or down (Z) plays audio.motion_z, the XY travel
## audio.motion_xy. All the timing is in tick_motion(), called once per physics
## tick (60 Hz) with the motion intensities (0..1) from main.gd::motion_intensities:
##
## - an axis counts as moving after its intensity has stayed above MOVE_ON for
##   START_CONFIRM_S (a one-tick spike, e.g. a reconnect, plays nothing), and as
##   stopped after it has stayed below MOVE_OFF for STOP_DEBOUNCE_S (a short dip
##   does not restart anything);
## - one shared clock: the first sound plays as soon as something moves, then
##   one every INTERVAL_S while anything moves, never two closer than INTERVAL_S
##   (a stop and a quick restart wait for the rest of the second);
## - Z and XY together: one sound per beat, the Z one (the arm's motion is the
##   one that matters at the claw); the XY sound still ringing is faded out;
## - when the axis of a sound still playing stops, that sound fades to silence
##   over FADE_OUT_S and then stops.
##
## The MP3s in game/assets/audio/ come from 効果音ラボ (soundeffect-lab.info):
## built into the game as its sounds, which its terms allow (GitHub included);
## they must not be handed out on their own (see game/assets/audio/SOURCES.md).
## They are read as raw bytes (no import step); a missing file just means silence.

const VOICES := ["z", "xy"]
const INTERVAL_S := 1.0
const START_CONFIRM_S := 0.05
const STOP_DEBOUNCE_S := 0.2
const FADE_OUT_S := 0.3
## Intensity hysteresis (0..1 of main.gd's FX_MOVE_FULL_CM_S / FX_ROPE_FULL_CM_S).
const MOVE_ON := 0.04
const MOVE_OFF := 0.015
const SILENT_DB := -60.0
## Each motion sound's own level on volume_db (tools/audio_levels.py: menu2 -14.0,
## menu3 -15.3 LUFS momentary; both to about -27 at volume_db -8, under the ordinary
## effects' -24 because they repeat every second).
const VOICE_GAIN_DB := {"z": -5.0, "xy": -3.5}
## Which file each voice plays (config keys audio.motion_z / audio.motion_xy).
const VOICE_KEYS := {"z": "motion_z", "xy": "motion_xy"}

var enabled := true
## Overall level in dB (config audio.volume_db).
var volume_db := -8.0
## Every motion sound started, newest last: "z" / "xy" (tests / debug; capped).
var beat_log: Array[String] = []
## Time of each of those starts on the motion clock (s, same order).
var beat_times: Array[float] = []

var _players: Dictionary = {}  # voice -> AudioStreamPlayer
var _level: Dictionary = {}    # voice -> current linear gain 0..1 (1 while it plays, falls in a fade)
var _fading: Dictionary = {}   # voice -> true while fading out
var _files: Dictionary = {}    # voice -> path it was loaded from ("" = missing)
var _active: Dictionary = {}   # axis -> moving (debounced)
var _above: Dictionary = {}    # axis -> time above MOVE_ON while not moving
var _below: Dictionary = {}    # axis -> time below MOVE_OFF while moving
var _clock := 0.0
var _last_beat := -INF

func _ready() -> void:
	var dir := str(GameConfig.get_value("audio", "dir", "res://assets/audio"))
	enabled = bool(GameConfig.get_value("audio", "enabled", true))
	volume_db = float(GameConfig.get_value("audio", "volume_db", -8.0))
	for v in VOICES:
		var player := AudioStreamPlayer.new()
		player.name = "Sfx_" + v
		player.volume_db = SILENT_DB
		player.bus = AudioBuses.SFX
		player.max_polyphony = 2  # menu3 is 1.35 s: the next beat starts over its tail
		add_child(player)
		_players[v] = player
		_level[v] = 0.0
		_fading[v] = false
		_active[v] = false
		_above[v] = 0.0
		_below[v] = 0.0
		var file := str(GameConfig.get_value("audio", VOICE_KEYS[v], ""))
		var path := dir.path_join(file) if file != "" else ""
		player.stream = load_mp3(path)
		if player.stream != null:
			player.stream.loop = false
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

# ------------------------------------------------------------ one-shot cues
## Hand joystick cues: "hand" (an open hand is seen), "pinch" (the pinch is
## caught), "pinch_z" (a palm-down pinch: Z, a different tune), "release" (the fingers opened: a normal end of steering) and
## "lost" (control was cut: hand lost, two hands, stale events...), "catch" (#332: the easy
## mode's fist, じどうキャッチ, and the practice's fist step). Synthesised 8-bit blips (a
## square wave with a short envelope), so they need no file; a file named in
## audio.cue_<name> (in audio.dir, mp3) replaces one, at its own level from
## audio.cue_gain_db.<name> (#321: the hand and the pinch are 効果音ラボ's 決定ボタンを押す 1 / 3;
## #332: the release is キャンセル4, the catch 決定ボタンを押す23).
const CUE_RATE := 22050
const CUE_NOTES := {
	"hand": [[784.0, 0.06]],                           # "pon" (quiet)
	"pinch": [[988.0, 0.05], [1480.0, 0.11]],          # "pi-pon!" up
	"pinch_z": [[523.0, 0.05], [784.0, 0.05], [523.0, 0.05], [784.0, 0.1]],  # "po-pi-po-pi": Z mode
	"release": [[1480.0, 0.05], [988.0, 0.11]],        # "pon-pi" down: the pinch reversed
	"lost": [[523.0, 0.08], [392.0, 0.08], [262.0, 0.16]],  # "bu-bu-buu" down
	"catch": [[659.0, 0.05], [988.0, 0.05], [1319.0, 0.12]],  # "pi-po-pon!" up: the fist's catch
}
## Level of each cue relative to audio.volume_db.
## #304: leveled with tools/audio_levels.py (the hand's "pon" kept quiet)
const CUE_GAIN_DB := {"hand": -4.0, "pinch": -3.0, "pinch_z": -4.0, "release": -3.0, "lost": -4.0, "catch": -3.0}
## Every cue played, newest last (tests / debug; capped).
var cue_log: Array[String] = []
var _cue_player: AudioStreamPlayer
var _cues: Dictionary = {}
var _cue_gain: Dictionary = {}  # cue -> dB relative to volume_db
## Name of the cue played last (tests / debug).
var last_cue := ""

func _enter_tree() -> void:
	_cue_player = AudioStreamPlayer.new()
	_cue_player.name = "Sfx_cue"
	_cue_player.bus = AudioBuses.SFX
	add_child(_cue_player)
	var dir := str(GameConfig.get_value("audio", "dir", "res://assets/audio"))
	var file_gain = GameConfig.get_value("audio", "cue_gain_db", {})
	if not (file_gain is Dictionary):
		file_gain = {}
	for cue in CUE_NOTES.keys():
		var file := str(GameConfig.get_value("audio", "cue_" + cue, ""))
		var s: AudioStream = load_mp3(dir.path_join(file)) if file != "" else null
		if s is AudioStreamMP3:
			s.loop = false
		_cues[cue] = s if s != null else synth_blips(CUE_NOTES[cue])
		# a file has its own loudness; the synthesised blip keeps the level made for it
		_cue_gain[cue] = float(file_gain.get(cue, CUE_GAIN_DB.get(cue, 0.0))) if s != null else float(CUE_GAIN_DB.get(cue, 0.0))

func play_cue(cue: String) -> void:
	last_cue = cue
	cue_log.append(cue)
	if cue_log.size() > 32:
		cue_log.remove_at(0)
	if not enabled or not _cues.has(cue):
		return
	_cue_player.stream = _cues[cue]
	_cue_player.volume_db = volume_db + cue_gain(cue)
	_cue_player.play()

func cue_stream(cue: String) -> AudioStream:
	return _cues.get(cue)

## The cue's level relative to volume_db (dB).
func cue_gain(cue: String) -> float:
	return float(_cue_gain.get(cue, CUE_GAIN_DB.get(cue, 0.0)))

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

## The voice's current gain 0..1 (1 while it plays, falling during a fade).
func level(voice: String) -> float:
	return float(_level.get(voice, 0.0))

## Whether the axis ("z" / "xy") counts as moving (after the debounce).
func moving(axis: String) -> bool:
	return bool(_active.get(axis, false))

## Whether the voice is sounding (playing, fading included). Works without the files.
func sounding(voice: String) -> bool:
	return _level.get(voice, 0.0) > 0.0

## Called once per physics tick with the motion intensities (0..1): z = the arm
## going up or down (either way), xy = the travel. The only place the motion
## sounds are timed (see the top of this file).
func tick_motion(z_i: float, xy_i: float, dt: float) -> void:
	_clock += dt
	var want := {"z": z_i, "xy": xy_i}
	for a in VOICES:
		var i: float = want[a] if enabled else 0.0
		if not _active[a]:
			_above[a] = _above[a] + dt if i > MOVE_ON else 0.0
			if _above[a] >= START_CONFIRM_S - 1e-6:
				_active[a] = true
				_below[a] = 0.0
		else:
			_below[a] = _below[a] + dt if i < MOVE_OFF else 0.0
			if _below[a] >= STOP_DEBOUNCE_S - 1e-6:
				_active[a] = false
				_above[a] = 0.0
				_fade(a)  # its movement stopped: the sound still ringing fades out
	if (_active.z or _active.xy) and _clock - _last_beat >= INTERVAL_S - 1e-6:
		var v := "z" if _active.z else "xy"
		_fade("xy" if v == "z" else "z")
		_start(v)
		_last_beat = _clock
	for v in VOICES:
		if _fading[v]:
			_level[v] = maxf(0.0, _level[v] - dt / FADE_OUT_S)
			if _level[v] <= 0.0:
				_fading[v] = false
				var p: AudioStreamPlayer = _players[v]
				p.stop()
		_apply(v)

func _start(v: String) -> void:
	beat_log.append(v)
	beat_times.append(_clock)
	if beat_log.size() > 64:
		beat_log.remove_at(0)
		beat_times.remove_at(0)
	var p: AudioStreamPlayer = _players[v]
	if _fading[v]:
		p.stop()  # a tail fading out does not jump back to full volume
	_fading[v] = false
	_level[v] = 1.0
	_apply(v)
	if p.stream != null:
		p.play()

func _fade(v: String) -> void:
	if _level[v] > 0.0:
		_fading[v] = true

func _apply(v: String) -> void:
	var p: AudioStreamPlayer = _players[v]
	var g: float = _level[v]
	p.volume_db = volume_db + float(VOICE_GAIN_DB.get(v, 0.0)) + linear_to_db(g) if g > 0.001 else SILENT_DB

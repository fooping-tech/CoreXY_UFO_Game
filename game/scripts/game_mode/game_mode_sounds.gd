class_name GameModeSounds
extends Node
## The sounds of the score game (#138, files since #143). Each sound has a key
## (play("bumper"), play("jackpot")...). A key plays its **file** when the manifest
## (assets/audio/manifest.json: Kenney's CC0 sounds, with where each came from) names one
## that loads, and otherwise the sound synthesised here at start, as before: a missing
## file never breaks the game, it only sounds plainer.
##
## How they are played:
##   - a pool of players on the SFX buses; a sound of a Dial's side (absorb, drop, return,
##     release, fault) goes to that side's bus (left Dial left, right Dial right)
##   - priority: when every player is busy a priority 0 sound (a pin) is dropped, a higher
##     one takes the player of the least important sound playing
##   - at most one of a key per its min_gap_ms (a capsule rattling down the pins)
##   - a small random pitch on the hits so they do not sound like a machine gun
##   - "stop" silences everything else first
## The music is a short tune synthesised here (no CC0 loop could be fetched and checked;
## docs/audio_sources.md): one take for the game, a faster, fuller take for the last 30
## seconds, crossfaded, faded in and out, and turned down while a voice speaks.
##
## Pure presentation: nothing here is read by the score, the clock, the physics or the
## devices, and nothing waits for a sound to end.

const RATE := 22050
## beats per minute of the tune, and its notes (Hz, beats; 0 = a rest)
const BPM := 132.0
const HURRY_BPM := 160.0
const TUNE := [[523.3, 0.5], [659.3, 0.5], [784.0, 0.5], [659.3, 0.5], [880.0, 1.0], [784.0, 0.5], [659.3, 0.5],
	[587.3, 0.5], [698.5, 0.5], [880.0, 0.5], [698.5, 0.5], [784.0, 1.0], [0.0, 0.5], [784.0, 0.5],
	[523.3, 0.5], [659.3, 0.5], [784.0, 0.5], [1046.5, 0.5], [987.8, 1.0], [784.0, 0.5], [659.3, 0.5],
	[698.5, 0.5], [587.3, 0.5], [493.9, 0.5], [587.3, 0.5], [523.3, 1.5], [0.0, 0.5]]
## the bass under the hurry take: one note per two beats (Hz)
const BASS := [130.8, 130.8, 146.8, 196.0, 130.8, 164.8, 174.6, 130.8]
## at most one of these per PIN_GAP_S (a capsule rattling down the pins)
const PIN_GAP_S := 0.06
const MANIFEST := "res://assets/audio/manifest.json"
const AUDIO_DIR := "res://assets/audio/"
const PLAYERS := 8
## the music under the effects, and how far it steps back for a voice
const BGM_DB := -8.0
const DUCK_DB := -10.0
const FADE_S := 0.6
## sounds of a Dial's side: the key -> the lane state that side has just entered
const SIDE_SOUNDS := {"absorb": "ABSORBING", "drop": "DROPPING", "return": "RETURNING", "release": "RELEASING", "fault": "FAULT"}
## the pitch of "combo" by the step the combo reached
const COMBO_PITCH := [1.0, 1.0, 1.19, 1.5]
## sounds that are only synthesised here (#149: no file was added for the practice)
const SYNTH_ONLY := ["tutorial_ok", "summon"]

var enabled := true
var volume_db := -8.0
## false: only the synthesised sounds (config game_mode.sounds.files)
var use_files := true
var last_played := ""
## every sound asked for, newest last (tests)
var log: Array[String] = []
var bgm_on := false
var hurry := false
## the combo's step (0..3), for the pitch of "combo" (the controller's picture sets it)
var combo_step := 0
## what each player is playing: {key, priority, side, at_ms} ({} = free); tests read it
var voices: Array[Dictionary] = []
## how many sounds were dropped for want of a player (tests)
var dropped := 0
var _streams: Dictionary = {}  # key -> the synthesised stream
var _files: Dictionary = {}  # key -> the file's stream
var _meta: Dictionary = {}  # key -> the manifest's entry
var _players: Array[AudioStreamPlayer] = []
var _bgm: AudioStreamPlayer
var _bgm_fast: AudioStreamPlayer
var _bgm_gain := 0.0
var _fast_gain := 0.0
var _duck := 0.0
var _last_ms: Dictionary = {}  # key -> when it last played
var _side_of: Dictionary = {}  # lane state -> the side that entered it last
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	enabled = bool(GameConfig.get_value("audio", "enabled", true))
	volume_db = float(GameConfig.get_value("audio", "volume_db", -8.0))
	var gm = GameConfig.data.get("game_mode", {})
	var cfg: Dictionary = gm.get("sounds", {}) if gm is Dictionary and gm.get("sounds") is Dictionary else {}
	use_files = bool(cfg.get("files", true))
	AudioBuses.ensure(clampf(float(cfg.get("pan", AudioBuses.DEFAULT_PAN)), 0.0, 1.0))
	AudioBuses.apply(GameConfig.data.get("audio", {}) if GameConfig.data.get("audio") is Dictionary else {})
	_rng.seed = 143
	_streams = {
		"pin": StudySounds._tones([[1568.0, 0.03]], 0.18),
		"bumper": StudySounds._tones([[392.0, 0.04], [784.0, 0.08]], 0.4),
		"spinner": StudySounds._tones([[659.3, 0.03], [987.8, 0.03], [1318.5, 0.06]], 0.3),
		"switch": StudySounds._tones([[1174.7, 0.05], [1568.0, 0.1]], 0.3),
		"star": StudySounds._tones([[1046.5, 0.06], [1318.5, 0.06], [1568.0, 0.06], [2093.0, 0.2]], 0.35),
		"bonus": StudySounds._tones([[784.0, 0.08], [987.8, 0.08], [1174.7, 0.08], [1568.0, 0.3]], 0.4),
		"jackpot": StudySounds._tones([[523.3, 0.1], [659.3, 0.1], [784.0, 0.1], [1046.5, 0.1], [1318.5, 0.1], [1568.0, 0.1], [2093.0, 0.6]], 0.45),
		"goal": StudySounds._tones([[659.3, 0.07], [880.0, 0.16]], 0.35),
		"absorb": StudySounds._sweep(220.0, 1320.0, 0.5, 0.3),
		"drop": StudySounds._sweep(1320.0, 330.0, 0.25, 0.3),
		"return": StudySounds._sweep(990.0, 220.0, 0.6, 0.3),
		"release": StudySounds._tones([[523.3, 0.06], [784.0, 0.06], [1046.5, 0.18]], 0.35),
		"count": StudySounds._tones([[880.0, 0.12]], 0.35),
		"go": StudySounds._tones([[1318.5, 0.4]], 0.4),
		"hurry": StudySounds._tones([[987.8, 0.09], [0.0, 0.03], [987.8, 0.09], [0.0, 0.03], [1318.5, 0.25]], 0.4),
		"warning": StudySounds._tones([[1760.0, 0.07]], 0.3),
		"timeup": StudySounds._tones([[784.0, 0.15], [659.3, 0.15], [523.3, 0.5]], 0.4),
		"result": StudySounds._tones([[523.3, 0.13], [659.3, 0.13], [784.0, 0.13], [1046.5, 0.5], [784.0, 0.12], [1046.5, 0.7]], 0.4),
		"fault": StudySounds._tones([[262.0, 0.12], [196.0, 0.3]], 0.4),
		"stop": StudySounds._tones([[330.0, 0.1], [220.0, 0.3]], 0.4),
		# the kinds that came with #141, and the combo's step
		"pop": StudySounds._tones([[523.3, 0.03], [1046.5, 0.07]], 0.35),
		"target": StudySounds._tones([[880.0, 0.04], [1318.5, 0.08]], 0.3),
		"sling": StudySounds._tones([[1318.5, 0.03]], 0.2),
		"gem": StudySounds._tones([[1568.0, 0.04], [2093.0, 0.1]], 0.3),
		# the practice before the round (#149): "ping-pong" for a step done, the spell's rise
		"tutorial_ok": StudySounds._tones([[1318.5, 0.16], [1046.5, 0.42]], 0.4),
		"summon": StudySounds._sweep(196.0, 1568.0, 0.9, 0.3),
		"alien": StudySounds._tones([[659.3, 0.06], [880.0, 0.06], [1318.5, 0.06], [1760.0, 0.2]], 0.35),
		"warp": StudySounds._sweep(330.0, 1760.0, 0.3, 0.3),
		"combo": StudySounds._tones([[1046.5, 0.05], [1568.0, 0.12]], 0.3),
	}
	load_manifest()
	for i in PLAYERS:
		var p := AudioStreamPlayer.new()
		p.bus = AudioBuses.SFX
		add_child(p)
		_players.append(p)
		voices.append({})
	_bgm = AudioStreamPlayer.new()
	_bgm.name = "Bgm"
	_bgm.bus = AudioBuses.BGM
	_bgm.stream = _tune()
	add_child(_bgm)
	_bgm_fast = AudioStreamPlayer.new()
	_bgm_fast.name = "BgmHurry"
	_bgm_fast.bus = AudioBuses.BGM
	_bgm_fast.stream = _tune(HURRY_BPM, true)
	add_child(_bgm_fast)

## Reads the manifest and loads the files it names. A missing manifest, a missing file or
## one that does not load is skipped: that key keeps its synthesised sound.
func load_manifest(path := MANIFEST) -> void:
	_files = {}
	_meta = {}
	if not FileAccess.file_exists(path):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary) or not (parsed.get("sounds") is Dictionary):
		return
	for key in parsed.sounds.keys():
		var m = parsed.sounds[key]
		if not (m is Dictionary):
			continue
		_meta[key] = m
		var file := AUDIO_DIR + str(m.get("file", ""))
		if ResourceLoader.exists(file):
			var st = load(file)
			if st is AudioStream:
				_files[key] = st

## Every key that can sound (a file or a synthesised sound).
func keys() -> Array:
	var out := _streams.keys()
	for k in _files.keys():
		if not out.has(k):
			out.append(k)
	return out

## "file" / "synth" / "" (no such sound): what play(name) would use now.
func source_of(name: String) -> String:
	if use_files and _files.has(name):
		return "file"
	return "synth" if _streams.has(name) else ""

func priority_of(name: String) -> int:
	if _meta.has(name):
		return int(_meta[name].get("priority", 1))
	return 0 if name in ["pin", "sling"] else 1

func min_gap_ms(name: String) -> int:
	if _meta.has(name):
		return int(_meta[name].get("min_gap_ms", 0))
	return int(PIN_GAP_S * 1000.0) if name == "pin" else 0

## The controller's lane_changed: remembers which side entered a state last, so the
## sound played right after that step comes from that Dial's side. (A sound that follows a
## later event of a Dial, like the release, is given its side by the caller instead: both
## lanes can be in the same state by then.)
func on_lane(side: String, state: String) -> void:
	_side_of[state] = side

## The side a sound of `name` belongs to now ("" = the middle).
func side_of(name: String) -> String:
	return str(_side_of.get(SIDE_SOUNDS.get(name, ""), ""))

## Plays the sound `name`. `side` ("left" / "right"): the Dial it belongs to, when the
## caller knows it (an event of that Dial); left out, a Dial's sound takes the side that
## entered its lane state last (side_of).
func play(name: String, side := "") -> void:
	var now := Time.get_ticks_msec()
	var gap := min_gap_ms(name)
	if gap > 0 and now - int(_last_ms.get(name, -100000)) < gap:
		return
	_last_ms[name] = now
	last_played = name
	log.append(name)
	if log.size() > 64:
		log.remove_at(0)
	var src := source_of(name)
	if not enabled or src == "" or not is_inside_tree():
		return
	if name == "stop":
		silence()  # a stop cuts whatever was sounding
	var prio := priority_of(name)
	var slot := _slot(prio)
	if slot < 0:
		dropped += 1
		return
	var m: Dictionary = _meta.get(name, {}) if src == "file" else {}
	if side == "":
		side = side_of(name)
	var p := _players[slot]
	p.stream = _files[name] if src == "file" else _streams[name]
	p.bus = AudioBuses.sfx_bus(side)
	p.volume_db = volume_db + float(m.get("gain_db", 0.0))
	var jitter := float(m.get("pitch_jitter", 0.0))
	p.pitch_scale = 1.0 + _rng.randf_range(-jitter, jitter)
	if name == "combo":
		p.pitch_scale = COMBO_PITCH[clampi(combo_step, 0, COMBO_PITCH.size() - 1)]
	p.play()
	voices[slot] = {"key": name, "priority": prio, "side": side, "at_ms": now}

## A player for a sound of this priority: a free one, else the oldest of the least
## important sounds playing when that is less important than this one; -1 = none.
func _slot(prio: int) -> int:
	var worst := -1
	for i in _players.size():
		if not _players[i].playing:
			voices[i] = {}
			return i
		var v: Dictionary = voices[i]
		if worst < 0 or int(v.get("priority", 0)) < int(voices[worst].get("priority", 0)) \
				or (int(v.get("priority", 0)) == int(voices[worst].get("priority", 0)) and int(v.get("at_ms", 0)) < int(voices[worst].get("at_ms", 0))):
			worst = i
	if worst >= 0 and int(voices[worst].get("priority", 0)) < prio:
		return worst
	return -1

## How many players are sounding now.
func sounding() -> int:
	var n := 0
	for p in _players:
		if p.playing:
			n += 1
	return n

## Every effect stops now (the stop key, leaving the game). The music is set_bgm's.
func silence() -> void:
	for i in _players.size():
		_players[i].stop()
		voices[i] = {}

## The tune: on while the clock runs, the faster take for the last stretch. Both fade.
func set_bgm(on: bool, fast := false) -> void:
	bgm_on = on
	hurry = on and fast
	if _bgm == null or not is_inside_tree():
		return
	if on and enabled:
		for p in [_bgm, _bgm_fast]:
			if not p.playing:
				p.volume_db = -60.0
				p.play()

func _process(dt: float) -> void:
	if _bgm == null:
		return
	var want := 1.0 if bgm_on and enabled and not hurry else 0.0
	var want_fast := 1.0 if bgm_on and enabled and hurry else 0.0
	_bgm_gain = move_toward(_bgm_gain, want, dt / FADE_S)
	_fast_gain = move_toward(_fast_gain, want_fast, dt / FADE_S)
	_duck = move_toward(_duck, DUCK_DB if AudioBuses.voice_active() else 0.0, dt * 40.0)
	_fade(_bgm, _bgm_gain)
	_fade(_bgm_fast, _fast_gain)

func _fade(p: AudioStreamPlayer, gain: float) -> void:
	if gain <= 0.0:
		if p.playing:
			p.stop()
		return
	p.volume_db = volume_db + BGM_DB + _duck + linear_to_db(maxf(gain, 0.001))

## How far the music is turned down for a voice now (dB, 0 = not at all).
func duck_db() -> float:
	return _duck

## The tune as a loop. `bass`: the fuller take (a bass line and a tick on every beat).
static func _tune(bpm := BPM, bass := false) -> AudioStreamWAV:
	var beat := 60.0 / bpm
	var data := PackedByteArray()
	var at_beat := 0.0
	for n in TUNE:
		var f: float = n[0]
		var count := int(float(n[1]) * beat * RATE)
		for i in count:
			var t := float(i) / RATE
			var v := 0.0
			if f > 0.0:
				var env := minf(t / 0.005, 1.0) * (1.0 - 0.75 * float(i) / count)
				v = (1.0 if fmod(t * f, 1.0) < 0.5 else -1.0) * 0.22 * env  # a square lead
				v += (1.0 if fmod(t * f * 0.5, 1.0) < 0.25 else -1.0) * 0.1 * env  # and a thin octave below
			if bass:
				var b := at_beat + t / beat  # where in the tune, in beats
				var bf: float = BASS[int(b / 2.0) % BASS.size()]
				var in_beat := fmod(b, 1.0)
				v += (2.0 * fmod(t * bf, 1.0) - 1.0) * 0.16 * (1.0 - 0.5 * fmod(b, 2.0) / 2.0)  # a saw bass
				if in_beat < 0.06:  # a tick on the beat
					v += (fmod(t * 7919.0, 1.0) - 0.5) * 0.3 * (1.0 - in_beat / 0.06)
			var s := int(clampf(v, -1.0, 1.0) * 32000.0)
			data.append(s & 0xFF)
			data.append((s >> 8) & 0xFF)
		at_beat += float(n[1])
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = data.size() / 2
	return w

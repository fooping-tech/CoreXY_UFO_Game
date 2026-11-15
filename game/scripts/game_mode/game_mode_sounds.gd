class_name GameModeSounds
extends Node
## The sounds of the game mode (#138), synthesised at start like the study mode's (no
## audio files to license): the hits, the transfer, the countdown, and a short looping
## tune that speeds up for the last 30 seconds. Pure presentation.

const RATE := 22050
## beats per minute of the tune, and its notes (Hz, beats; 0 = a rest)
const BPM := 132.0
const TUNE := [[523.3, 0.5], [659.3, 0.5], [784.0, 0.5], [659.3, 0.5], [880.0, 1.0], [784.0, 0.5], [659.3, 0.5],
	[587.3, 0.5], [698.5, 0.5], [880.0, 0.5], [698.5, 0.5], [784.0, 1.0], [0.0, 0.5], [784.0, 0.5],
	[523.3, 0.5], [659.3, 0.5], [784.0, 0.5], [1046.5, 0.5], [987.8, 1.0], [784.0, 0.5], [659.3, 0.5],
	[698.5, 0.5], [587.3, 0.5], [493.9, 0.5], [587.3, 0.5], [523.3, 1.5], [0.0, 0.5]]
const HURRY_PITCH := 1.22
## at most one of these per PIN_GAP_S (a capsule rattling down the pins)
const PIN_GAP_S := 0.06

var enabled := true
var volume_db := -8.0
var last_played := ""
## every sound asked for, newest last (tests)
var log: Array[String] = []
var bgm_on := false
var hurry := false
var _streams: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var _bgm: AudioStreamPlayer
var _pin_ms := -1000

func _ready() -> void:
	enabled = bool(GameConfig.get_value("audio", "enabled", true))
	volume_db = float(GameConfig.get_value("audio", "volume_db", -8.0))
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
	}
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	_bgm = AudioStreamPlayer.new()
	_bgm.name = "Bgm"
	_bgm.stream = _tune()
	add_child(_bgm)

func play(name: String) -> void:
	if name == "pin":
		var now := Time.get_ticks_msec()
		if now - _pin_ms < int(PIN_GAP_S * 1000.0):
			return
		_pin_ms = now
	last_played = name
	log.append(name)
	if log.size() > 64:
		log.remove_at(0)
	if not enabled or not _streams.has(name) or not is_inside_tree():
		return
	var free: AudioStreamPlayer = _players[0]
	for p in _players:
		if not p.playing:
			free = p
			break
	free.stream = _streams[name]
	free.volume_db = volume_db
	free.play()

## The tune: on while the clock runs, faster for the last stretch.
func set_bgm(on: bool, fast := false) -> void:
	bgm_on = on
	hurry = on and fast
	if _bgm == null:
		return
	_bgm.pitch_scale = HURRY_PITCH if hurry else 1.0
	_bgm.volume_db = volume_db - 8.0
	if on and enabled and is_inside_tree():
		if not _bgm.playing:
			_bgm.play()
	elif _bgm.playing:
		_bgm.stop()

static func _tune() -> AudioStreamWAV:
	var beat := 60.0 / BPM
	var data := PackedByteArray()
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
			var s := int(clampf(v, -1.0, 1.0) * 32000.0)
			data.append(s & 0xFF)
			data.append((s >> 8) & 0xFF)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = data.size() / 2
	return w

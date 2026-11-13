class_name StudySounds
extends Node
## Short sounds for the study mode, synthesised at start (no audio files to license):
## chime (a problem filled), appear (HELP), shutter (a close-up taken), fanfare
## (homework complete), pop (a cracker), tick (a UI step). Pure presentation.

const RATE := 22050
var enabled := true
var volume_db := -6.0
var _streams: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var last_played := ""

func _ready() -> void:
	enabled = bool(GameConfig.get_value("audio", "enabled", true))
	_streams = {
		"chime": _tones([[1046.5, 0.09], [1568.0, 0.22]], 0.35),
		"appear": _sweep(330.0, 990.0, 0.35, 0.3),
		"shutter": _noise(0.07, 0.5),
		"fanfare": _tones([[523.3, 0.13], [659.3, 0.13], [784.0, 0.13], [1046.5, 0.5], [784.0, 0.12], [1046.5, 0.7]], 0.4),
		"pop": _noise(0.12, 0.6, true),
		"tick": _tones([[880.0, 0.05]], 0.25),
	}
	for i in 4:
		var p := AudioStreamPlayer.new()
		p.volume_db = volume_db
		add_child(p)
		_players.append(p)

func play(name: String) -> void:
	last_played = name
	if not enabled or not _streams.has(name):
		return
	for p in _players:
		if not p.playing:
			p.stream = _streams[name]
			p.play()
			return
	_players[0].stream = _streams[name]
	_players[0].play()

static func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w

static func _tones(notes: Array, amp: float) -> AudioStreamWAV:
	var s := PackedFloat32Array()
	for n in notes:
		var f: float = n[0]
		var count := int(float(n[1]) * RATE)
		for i in count:
			var t := float(i) / RATE
			var env := minf(t / 0.01, 1.0) * exp(-3.0 * t / maxf(float(n[1]), 0.01))
			s.append(amp * env * (sin(TAU * f * t) + 0.3 * sin(TAU * 2.0 * f * t)))
	return _wav(s)

static func _sweep(f0: float, f1: float, secs: float, amp: float) -> AudioStreamWAV:
	var s := PackedFloat32Array()
	var phase := 0.0
	var count := int(secs * RATE)
	for i in count:
		var k := float(i) / count
		phase += TAU * lerpf(f0, f1, k * k) / RATE
		s.append(amp * sin(phase) * sin(PI * k))
	return _wav(s)

static func _noise(secs: float, amp: float, low := false) -> AudioStreamWAV:
	var s := PackedFloat32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 86
	var prev := 0.0
	var count := int(secs * RATE)
	for i in count:
		var v := rng.randf_range(-1.0, 1.0)
		if low:
			prev = lerpf(prev, v, 0.15)
			v = prev * 2.5
		s.append(amp * v * exp(-6.0 * float(i) / count))
	return _wav(s)

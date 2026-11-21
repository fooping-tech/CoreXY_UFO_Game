class_name StudySounds
extends Node
## Short sounds for the study mode, synthesised at start (no audio files to license):
## chime (a problem filled), appear (HELP), shutter (a close-up taken), fanfare
## (homework complete), pop (a cracker), tick (a UI step); for the answer check (#237): drum (the
## roll before a verdict), boom (a big hit), sparkle (a quick run up). Pure presentation.
##
## The answer check's moments are cues (#237): several sounds at once, the game's sound files
## (assets/audio/manifest.json: Kenney, CC0, the score game's) layered with the synthesised ones;
## a file that is not there leaves its synthesised sound (or nothing).
##
## The music (#237): while the study mode runs, study_mode.bgm.file (default ending.mp3) from
## game/assets/audio/bgm/ (each machine's own, never in Git) loops on the BGM bus. No file, or the
## music off (audio.bgm_enabled), is silence.

const RATE := 22050
var enabled := true
var volume_db := -6.0
var _streams: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var last_played := ""
var music_file := "ending.mp3"
var music_gain_db := -6.0
var music: AudioStreamPlayer  # null when there is no music file
var _files: Dictionary = {}  # manifest key -> AudioStream
var last_cue := ""
## the project's own effects in assets/audio/ (added for the answer check): key -> file. Read
## from the disk when there (no import needed); a missing one leaves its stand-in ("a|b").
const OWN_FILES := {"pico": "pico.mp3", "don": "don.mp3", "jan": "jan.mp3"}
## a moment -> the sounds played together (a manifest key, an own file, or a synthesised one;
## "a|b" = a, or b when there is no a)
const CUES := {
	"check_start": ["go", "appear"],
	"drum": ["drum"],
	"correct": ["don|boom", "pico|star", "gem"],
	"combo": ["combo", "sparkle"],
	"review": ["pop", "switch"],
	"unclear": ["tick"],
	"reward": ["jan|fanfare", "boom", "jackpot"],
	"perfect": ["bonus", "sparkle"],
	"count": ["pin"],
	"power_show": ["warp"],
	"power_pick": ["boom", "star", "alien"],
	"ready": ["result", "chime"],
}

func _ready() -> void:
	enabled = bool(GameConfig.get_value("audio", "enabled", true))
	_streams = {
		"chime": _tones([[1046.5, 0.09], [1568.0, 0.22]], 0.35),
		"appear": _sweep(330.0, 990.0, 0.35, 0.3),
		"shutter": _noise(0.07, 0.5),
		"fanfare": _tones([[523.3, 0.13], [659.3, 0.13], [784.0, 0.13], [1046.5, 0.5], [784.0, 0.12], [1046.5, 0.7]], 0.4),
		"pop": _noise(0.12, 0.6, true),
		"tick": _tones([[880.0, 0.05]], 0.25),
		"drum": _roll(0.75, 0.45),
		"boom": _boom(0.55, 0.9),
		"sparkle": _tones([[1318.5, 0.05], [1568.0, 0.05], [2093.0, 0.05], [2637.0, 0.16]], 0.3),
	}
	_load_files()
	for i in 8:
		var p := AudioStreamPlayer.new()
		p.volume_db = volume_db
		add_child(p)
		_players.append(p)

## The study mode's music from the bgm folder (as the score game's: GameModeSounds).
func _load_music() -> void:
	var b = GameConfig.get_value("study_mode", "bgm", {})
	if b is Dictionary:
		music_file = str(b.get("file", music_file))
		music_gain_db = float(b.get("gain_db", music_gain_db))
	if music_file == "" or not GameModeSounds.load_music:
		return
	var stream := GameModeSounds.load_music_stream(GameModeSounds.MUSIC_DIR.path_join(music_file))
	if stream == null:
		return
	music = AudioStreamPlayer.new()
	music.name = "StudyMusic"
	music.bus = AudioBuses.BGM
	music.stream = stream
	music.volume_db = music_gain_db
	add_child(music)

func music_start() -> void:
	if music == null:
		_load_music()
	if music != null and not music.playing and bool(GameConfig.get_value("audio", "bgm_enabled", true)):
		music.play()

func music_stop() -> void:
	if music != null:
		music.stop()

func _load_files() -> void:
	for key in OWN_FILES:
		var own := GameModeSounds.load_music_stream(GameModeSounds.AUDIO_DIR + str(OWN_FILES[key]), false)
		if own != null:
			_files[key] = own
	if not FileAccess.file_exists(GameModeSounds.MANIFEST):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(GameModeSounds.MANIFEST))
	if not parsed is Dictionary or not parsed.get("sounds") is Dictionary:
		return
	for key in parsed.sounds:
		var m = parsed.sounds[key]
		var file := GameModeSounds.AUDIO_DIR + str(m.get("file", "")) if m is Dictionary else ""
		if file != "" and ResourceLoader.exists(file):
			var st = load(file)
			if st is AudioStream:
				_files[key] = st

## Several sounds for one moment (CUES).
func cue(name: String) -> void:
	last_cue = name
	for key in CUES.get(name, [name]):
		play(pick(str(key)))

## "a|b": the first of them that can sound.
func pick(choice: String) -> String:
	var options := choice.split("|")
	for k in options:
		if _files.has(k) or _streams.has(k):
			return k
	return options[0]

## A sound: the game's file when there is one, else the synthesised one.
func play(name: String) -> void:
	last_played = name
	var stream: AudioStream = _files.get(name, _streams.get(name))
	if not enabled or stream == null:
		return
	for p in _players:
		if not p.playing:
			p.stream = stream
			p.play()
			return
	_players[0].stream = stream
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

## A snare roll getting faster and louder (the moment before a verdict).
static func _roll(secs: float, amp: float) -> AudioStreamWAV:
	var s := PackedFloat32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 237
	var count := int(secs * RATE)
	var next := 0
	var gap := int(0.07 * RATE)
	var hit := 0
	for i in count:
		if i >= next:
			hit = i
			gap = maxi(int(gap * 0.88), int(0.025 * RATE))
			next = i + gap
		var k := float(i) / count
		var env := exp(-40.0 * float(i - hit) / RATE)
		s.append(amp * (0.4 + 0.6 * k) * env * rng.randf_range(-1.0, 1.0))
	return _wav(s)

## A deep hit: a falling sine and a thud of noise.
static func _boom(secs: float, amp: float) -> AudioStreamWAV:
	var s := PackedFloat32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 86
	var phase := 0.0
	var count := int(secs * RATE)
	for i in count:
		var t := float(i) / RATE
		phase += TAU * lerpf(140.0, 45.0, minf(t / 0.25, 1.0)) / RATE
		var v := sin(phase) * exp(-5.0 * t) + 0.35 * rng.randf_range(-1.0, 1.0) * exp(-30.0 * t)
		s.append(amp * clampf(v, -1.0, 1.0))
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

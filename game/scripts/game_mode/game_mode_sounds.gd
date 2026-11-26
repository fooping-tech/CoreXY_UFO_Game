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
##     release, fault) goes to that side's bus (#200: the one Dial, on the left)
##   - priority: when every player is busy a priority 0 sound (a pin) is dropped, a higher
##     one takes the player of the least important sound playing
##   - at most one of a key per its min_gap_ms (a capsule rattling down the pins)
##   - a small random pitch on the hits so they do not sound like a machine gun
##   - "stop" silences everything else first
## The music is a short tune synthesised here (no CC0 loop could be fetched and checked;
## docs/audio_sources.md): one take for the game, a faster, fuller take for the last 30
## seconds, switched at once (no fades, #181) and turned down while a voice speaks.
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
## the music under the effects, and how far it steps back for a voice. #304: the music files
## are leveled to -18 LUFS (game_mode.sounds.bgm.gain_db), the effects to about -14 (momentary,
## before audio.volume_db): -2 keeps the music about 6 dB under the big effects (was -8: lost
## under them)
const BGM_DB := -2.0
const DUCK_DB := -10.0
## The music files (#173): game/assets/audio/bgm/ is each machine's own (never in Git, #151).
## A track whose file is not there, or does not load, is as before: the synthesised tune for
## the round, silence for the menu and the result.
const MUSIC_DIR := "res://assets/audio/bgm/"
## top = the title screen at start (#181), menu = the score game's own title, tutorial = the
## practice, game = the clock runs, ending = the result
const TRACKS := ["top", "menu", "tutorial", "game", "ending"]
## false: no music file is read (the tests: this machine's files must not change them)
static var load_music := true
## sounds of a Dial's side: the key -> the lane state that side has just entered
const SIDE_SOUNDS := {"absorb": "ABSORBING", "drop": "DROPPING", "return": "RETURNING", "release": "RELEASING", "fault": "FAULT"}
## the pitch of "combo" by the step the combo reached
const COMBO_PITCH := [1.0, 1.0, 1.19, 1.5]
## sounds that are only synthesised here (#149: no file was added for the practice)
const SYNTH_ONLY := ["tutorial_ok", "summon", "timeup_hit", "result_count", "score_lock", "bonus_show", "capsule_pop", "colour_bonus", "bonus_hit", "final_hit", "new_record", "power_speed", "power_multi", "power_double"]
## #266: the capsule's entrance (カプセル回収！ as it comes up big), files of 効果音ラボ (the battle
## page's magic; game/assets/audio/se/README.md), not in the Kenney manifest. A missing file
## falls back to the synthesised sound of the same key.
## #320: thunder = 雷魔法1 (the same file as the plain capsule's), dark = 暗黒魔法.
## #328: the result's party poppers (FINAL SCORE) sound 「ジャン！」 (se/jan.mp3, the study mode's
## fanfare): the jingle and the falling sweep played there before sounded a little sad. A new
## place in the top ten (NEW RECORD!) sounds it too, with 歓声と拍手1 (cheer, se/cheer-applause1.mp3).
const OWN_FILES := {"result_jan": "se/jan.mp3", "cheer": "se/cheer-applause1.mp3", "reveal": "se/magic-thunder1.mp3", "reveal_fire": "se/magic-fire2.mp3",
	"reveal_water": "se/magic-ice2.mp3", "reveal_green": "se/magic-wind1.mp3",
	"reveal_thunder": "se/magic-thunder1.mp3", "reveal_dark": "se/magic-dark.mp3"}
## #304: each own file's level (dB, on audio.volume_db), as the manifest's gain_db: measured with
## tools/audio_levels.py and brought to the same loudness as the other big effects
const OWN_GAIN_DB := {"result_jan": 1.5, "cheer": -1.0, "reveal": -3.0, "reveal_fire": -1.0, "reveal_water": -3.0, "reveal_green": 1.0,
	"reveal_thunder": -3.0, "reveal_dark": 5.5}
## #325: the countdowns' own files (効果音ラボ; game/assets/audio/se/README.md): the start's
## electronic beep (プッ、プッ、プッ、ピー) and the end's voice (「10、9、8、7、6、5、4、3、2、1、0」).
## Not play()ed: each is started part-way on a player of its own so its numbers fall on the
## numbers of the screen (follow_cue), and stopped with the round. A missing file: the old
## count / go / warning sounds, one per number, as before.
const CUE_FILES := {"countdown_start": "se/electronic-countdown1.mp3", "countdown_end": "se/info-girl1-countdown2.mp3"}
## Where each number starts in the file (s), measured (#325: ffmpeg decode, 5 ms RMS, the first
## frame 30 dB under the file's peak). The last one is the anchor: it is put on 0 (GO! / TIME UP),
## the one before it on 1 and so on; every number is then within 16 ms (one frame) of the
## screen's. countdown_start: プッ (3) プッ (2) プッ (1) ピー (GO!, 1.6 s long, ends 4.63 s).
## countdown_end: 10 9 8 7 6 5 4 3 2 1 0 (the 0 ends 10.43 s; the file is 10.56 s).
const CUE_ONSETS := {"countdown_start": [0.000, 1.003, 2.005, 2.993],
	"countdown_end": [0.005, 1.023, 2.015, 3.003, 4.006, 5.004, 6.016, 7.014, 8.002, 9.000, 10.007]}
## #325: their level (dB on volume_db), tools/audio_levels.py: the beep -10.3, the voice -18.7
## momentary LUFS, both brought to the big effects' -22 (target + 8 - measured)
const CUE_GAIN_DB := {"countdown_start": -4.0, "countdown_end": 5.0}
## a cue further than this from where it should be is put back there (a long frame), at most
## once per CUE_RESEEK_MS
const CUE_SLACK_S := 0.12
const CUE_RESEEK_MS := 500
## #304: the synthesised round tune is louder than the leveled music files
const TUNE_GAIN_DB := -3.0
## the synthesised sounds of the result's show (#153): priority, and the least gap between
## two of a key (the counting blips come many a second and must never fill the players);
## gain_db (#304): the synthesised sound's level, as the manifest's (tools/audio_levels.py)
const SYNTH_META := {"timeup_hit": {"priority": 2, "gain_db": -3.0}, "result_count": {"priority": 0, "min_gap_ms": 40, "gain_db": 4.0},
	"score_lock": {"priority": 2, "gain_db": 4.0}, "bonus_show": {"priority": 2, "gain_db": 6.0}, "bonus_hit": {"priority": 2, "gain_db": 3.0},
	"capsule_pop": {"priority": 1, "min_gap_ms": 40, "gain_db": 2.0}, "colour_bonus": {"priority": 2, "gain_db": 1.0},
	"final_hit": {"priority": 2, "gain_db": -4.0}, "new_record": {"priority": 2, "gain_db": 1.0},
	"power_speed": {"priority": 2, "min_gap_ms": 400, "gain_db": -2.0}, "power_multi": {"priority": 2, "min_gap_ms": 400, "gain_db": 1.0},
	"power_double": {"priority": 2, "min_gap_ms": 400},
	"reveal": {"priority": 2, "min_gap_ms": 400, "gain_db": 1.0}, "reveal_fire": {"priority": 2, "min_gap_ms": 400},
	"reveal_water": {"priority": 2, "min_gap_ms": 400, "gain_db": 3.0}, "reveal_green": {"priority": 2, "min_gap_ms": 400, "gain_db": 2.0},
	"reveal_thunder": {"priority": 2, "min_gap_ms": 400}, "reveal_dark": {"priority": 2, "min_gap_ms": 400, "gain_db": 2.0},
	"result_jan": {"priority": 2}, "cheer": {"priority": 2},
	"tutorial_ok": {"gain_db": 3.0}, "gauge": {"gain_db": 4.0}, "summon": {"gain_db": -1.0}}

var enabled := true
var volume_db := -8.0
## false: only the synthesised sounds (config game_mode.sounds.files)
var use_files := true
var last_played := ""
## the pitch the last sound was really played at (tests)
var last_pitch := 1.0
## how many blips of the practice's gauge were asked for (tests)
var gauge_blips := 0
## every sound asked for, newest last (tests)
var log: Array[String] = []
var bgm_on := false
var hurry := false
## The menu is on the screen (the title screens): the main scene sets it. / The round is
## over and its result is shown: the score game's controller sets it.
var menu_on := false
var ending_on := false
var top_on := false
var tutorial_on := false
## no music at all now (#181: the settings screen's 校正 tab; the machine is listened to)
var silent := false
## track -> file name in MUSIC_DIR (config game_mode.sounds.bgm), and its own gain (dB)
var music_names := {"top": "top.wav", "menu": "intro.mp3", "tutorial": "tutorial.mp3", "game": "game.wav", "ending": "ending.mp3"}
var music_gain_db := {"top": 0.0, "menu": 0.0, "tutorial": 0.0, "game": 0.0, "ending": 0.0}
## #181: the jingle when a mode is chosen on the title screen (a file of MUSIC_DIR, played once)
var jingle_name := "Intro Jingle.wav"
var jingle_gain_db := 0.0
var jingles := 0  # how many were started
var _jingle: AudioStreamPlayer
## config game_mode.sounds.bgm.files: false = never the files
var use_music := true
var _music: Dictionary = {}  # track -> AudioStreamPlayer (only the tracks whose file loaded)
var _music_gain: Dictionary = {}  # track -> 0..1
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
## #188: the music a step down under a pickup's sound, for this long (no fade: #181)
var _pickup_duck_left := 0.0
var _pickup_duck_db := 0.0
var _last_ms: Dictionary = {}  # key -> when it last played
var _side_of: Dictionary = {}  # lane state -> the side that entered it last
var _rng := RandomNumberGenerator.new()
## #325: the countdown cue: its key ("" = none this round), where it was started from (s in the
## file, the output latency included), how often one was started / put back (tests)
var cue := ""
var cue_from := 0.0
var cue_starts := 0
var cue_seeks := 0
var _cue_files: Dictionary = {}  # key -> the file's stream
var _cue_player: AudioStreamPlayer
var _cue_seek_ms := -100000

func _ready() -> void:
	enabled = bool(GameConfig.get_value("audio", "enabled", true))
	volume_db = float(GameConfig.get_value("audio", "volume_db", -8.0))
	var gm = GameConfig.data.get("game_mode", {})
	var cfg: Dictionary = gm.get("sounds", {}) if gm is Dictionary and gm.get("sounds") is Dictionary else {}
	use_files = bool(cfg.get("files", true))
	var music: Dictionary = cfg.get("bgm", {}) if cfg.get("bgm") is Dictionary else {}
	use_music = bool(music.get("files", true))
	for track in TRACKS:
		if music.get(track) is String:
			music_names[track] = str(music[track])
		if music.get("gain_db") is Dictionary and music.gain_db.get(track) != null:
			music_gain_db[track] = clampf(float(music.gain_db[track]), -40.0, 12.0)
	if music.get("jingle") is String:
		jingle_name = str(music.jingle)
	if music.get("gain_db") is Dictionary and music.gain_db.get("jingle") != null:
		jingle_gain_db = clampf(float(music.gain_db.jingle), -40.0, 24.0)
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
		# the practice's gauge filling (#179): a short blip, played higher as it fills
		"gauge": StudySounds._tones([[659.3, 0.07]], 0.45),
		"summon": StudySounds._sweep(196.0, 1568.0, 0.9, 0.3),
		# the result's show (#153): the thud of TIME UP, the counting blip (its pitch is set
		# as it is played), the number stopping, a bonus called and landing, the last hit
		"timeup_hit": StudySounds._sweep(150.0, 38.0, 0.6, 0.55),
		"result_count": StudySounds._tones([[987.8, 0.04]], 0.2),
		"score_lock": StudySounds._tones([[392.0, 0.05], [784.0, 0.05], [1568.0, 0.3]], 0.4),
		"bonus_show": StudySounds._tones([[523.3, 0.09], [0.0, 0.04], [523.3, 0.07], [784.0, 0.28]], 0.4),
		"bonus_hit": StudySounds._tones([[1046.5, 0.045], [1318.5, 0.045], [1568.0, 0.045], [2093.0, 0.045], [2637.0, 0.2]], 0.35),
		"final_hit": StudySounds._sweep(520.0, 45.0, 0.7, 0.55),
		# #328: the stand-in of 「ジャン！」 (se/jan.mp3) when the file is missing: a bright chord up
		"result_jan": StudySounds._tones([[784.0, 0.06], [1046.5, 0.06], [1568.0, 0.45]], 0.5),
		# the stand-in of the cheer when its file is missing: the new record's climb
		"cheer": StudySounds._tones([[784.0, 0.07], [987.8, 0.07], [1174.7, 0.07], [1568.0, 0.07], [1975.5, 0.07], [2349.3, 0.45]], 0.4),
		# #323: a capsule pops out on a bonus's line (played higher for each one), and a colour
		# set's sparkling run (a quick rainbow up the scale)
		"capsule_pop": StudySounds._tones([[784.0, 0.03], [1568.0, 0.06]], 0.3),
		"colour_bonus": StudySounds._tones([[1046.5, 0.05], [1174.7, 0.05], [1318.5, 0.05], [1568.0, 0.05], [1760.0, 0.05],
			[2093.0, 0.05], [2637.0, 0.3]], 0.3),
		# a round made the top ten (#155): a quick climb to a long high note
		"new_record": StudySounds._tones([[784.0, 0.07], [987.8, 0.07], [1174.7, 0.07], [1568.0, 0.07], [1975.5, 0.07], [2349.3, 0.45]], 0.4),
		"alien": StudySounds._tones([[659.3, 0.06], [880.0, 0.06], [1318.5, 0.06], [1760.0, 0.2]], 0.35),
		"warp": StudySounds._sweep(330.0, 1760.0, 0.3, 0.3),
		"combo": StudySounds._tones([[1046.5, 0.05], [1568.0, 0.12]], 0.3),
		# #188: distinct arcade pickup cues. Synthesized; no third-party audio required.
		"power_speed": StudySounds._sweep(320.0, 1900.0, 0.46, 0.5),
		"power_multi": StudySounds._tones([[659.3, 0.09], [987.8, 0.09], [1568.0, 0.32]], 0.5),
		"power_double": StudySounds._tones([[523.3, 0.10], [784.0, 0.10], [1046.5, 0.10], [1568.0, 0.48]], 0.5),
		# #266: the capsule comes up big in the collection show (カプセル回収！): a chime, and
		# each kind its own: fire a roar going up, water bubbles, green a sparkling climb (the
		# stand-ins of OWN_FILES' magic sounds when those files are missing)
		"reveal": StudySounds._tones([[1046.5, 0.07], [1568.0, 0.07], [2093.0, 0.35]], 0.45),
		"reveal_fire": StudySounds._sweep(110.0, 880.0, 0.32, 0.5),
		"reveal_water": StudySounds._tones([[784.0, 0.05], [0.0, 0.02], [1046.5, 0.05], [0.0, 0.02], [659.3, 0.05], [0.0, 0.02],
			[1318.5, 0.05], [0.0, 0.02], [1046.5, 0.3]], 0.42),
		"reveal_green": StudySounds._tones([[1318.5, 0.05], [1568.0, 0.05], [1975.5, 0.05], [2637.0, 0.05], [3136.0, 0.3]], 0.38),
		# #320: thunder a crackle of quick high blips, dark a slow fall into the low notes
		"reveal_thunder": StudySounds._tones([[1760.0, 0.03], [0.0, 0.02], [2349.3, 0.03], [0.0, 0.02], [1760.0, 0.03], [0.0, 0.02],
			[2637.0, 0.25]], 0.42),
		"reveal_dark": StudySounds._sweep(440.0, 70.0, 0.6, 0.5),
	}
	load_manifest()
	_cue_player = AudioStreamPlayer.new()
	_cue_player.name = "Countdown"
	_cue_player.bus = AudioBuses.SFX
	add_child(_cue_player)
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
	load_music_files()

## Reads the music files that are there (each as a loop). A track with no file keeps what it
## had before there were files. Never an error: the folder is empty on most machines.
func load_music_files(dir := MUSIC_DIR) -> void:
	for track in _music.keys():
		_music[track].queue_free()
	_music = {}
	_music_gain = {}
	if _jingle != null:
		_jingle.queue_free()
		_jingle = null
	if not load_music or not use_music:
		return
	var once := load_music_stream(dir.path_join(jingle_name), false) if jingle_name != "" else null
	if once != null:
		_jingle = AudioStreamPlayer.new()
		_jingle.name = "Jingle"
		_jingle.bus = AudioBuses.SFX  # an effect: the effects' volume, heard with the music off too
		_jingle.stream = once
		print("[bgm] jingle: %s (%.1f s, once)" % [jingle_name, once.get_length()])
		add_child(_jingle)
	for track in TRACKS:
		var file := str(music_names.get(track, ""))
		var stream := load_music_stream(dir.path_join(file)) if file != "" else null
		if stream == null:
			if file != "" and FileAccess.file_exists(dir.path_join(file)):
				push_warning("bgm: %s could not be read as music (%s): as without a file" % [file, track])
			continue
		print("[bgm] %s: %s (%.0f s, loops)" % [track, file, stream.get_length()])
		var p := AudioStreamPlayer.new()
		p.name = "Music_" + track
		p.bus = AudioBuses.BGM
		p.stream = stream
		add_child(p)
		_music[track] = p
		_music_gain[track] = 0.0

## A music file as a looping stream (.mp3 / .ogg / .wav, read from the disk as it is: the
## folder's files are not imported resources of the project). null = not there / not readable.
static func load_music_stream(path: String, loop := true) -> AudioStream:
	if not FileAccess.file_exists(path):
		return null
	var disk := ProjectSettings.globalize_path(path)
	match path.get_extension().to_lower():
		"mp3":
			var mp3 := AudioStreamMP3.load_from_file(disk)
			if mp3 != null:
				mp3.loop = loop
			return mp3
		"ogg":
			var ogg := AudioStreamOggVorbis.load_from_file(disk)
			if ogg != null:
				ogg.loop = loop
			return ogg
		"wav":
			var wav := AudioStreamWAV.load_from_file(disk)
			if wav == null or wav.data.is_empty():
				return null
			var frame := (2 if wav.format == AudioStreamWAV.FORMAT_16_BITS else 1) * (2 if wav.stereo else 1)
			if loop and wav.format in [AudioStreamWAV.FORMAT_8_BITS, AudioStreamWAV.FORMAT_16_BITS]:
				wav.loop_begin = 0
				wav.loop_end = wav.data.size() / frame
				wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
			return wav
	return null

## Which music should sound now: "game" (the clock runs) / "ending" (the result) / "menu"
## (a title screen) / "" (none: the practice, the countdown, the other modes).
func track_wanted() -> String:
	if not enabled or silent:
		return ""
	if bgm_on:
		return "game"
	if ending_on:
		return "ending"
	if jingle_playing():
		return ""  # the jingle is heard alone; the next music starts after it
	if tutorial_on:
		return "tutorial"
	if top_on:
		return "top"
	if menu_on:
		return "menu"
	return ""

## #181: a mode was chosen on the title screen: the jingle, once (nothing without its file).
func play_jingle() -> void:
	if _jingle == null or not enabled or silent:
		return
	_jingle.volume_db = volume_db + jingle_gain_db
	_jingle.play()
	jingles += 1

func jingle_playing() -> bool:
	return _jingle != null and _jingle.playing

## The track is played from its file (else: the synthesised tune for "game", nothing otherwise).
func has_music(track: String) -> bool:
	return _music.has(track)

## Reads the manifest and loads the files it names. A missing manifest, a missing file or
## one that does not load is skipped: that key keeps its synthesised sound.
func load_manifest(path := MANIFEST) -> void:
	_files = {}
	_meta = {}
	_cue_files = {}
	if path == MANIFEST:  # the game's own files go with its own manifest (a test's other one: none)
		for key in OWN_FILES:
			var own := load_music_stream(AUDIO_DIR + str(OWN_FILES[key]), false)
			if own != null:
				_files[key] = own
		for key in CUE_FILES:
			var st := load_music_stream(AUDIO_DIR + str(CUE_FILES[key]), false)
			if st != null:
				_cue_files[key] = st
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

## #304: the level of `name` as play() would play it now (dB on volume_db): the manifest's
## gain_db for a manifest file, OWN_GAIN_DB for an own file, SYNTH_META's for a synthesised one.
func gain_db_of(name: String) -> float:
	var src := source_of(name)
	if src == "file":
		if _meta.has(name):
			return float(_meta[name].get("gain_db", 0.0))
		return float(OWN_GAIN_DB.get(name, 0.0))
	if src == "synth" and SYNTH_META.has(name):
		return float(SYNTH_META[name].get("gain_db", 0.0))
	return 0.0

func priority_of(name: String) -> int:
	if _meta.has(name):
		return int(_meta[name].get("priority", 1))
	if SYNTH_META.has(name):
		return int(SYNTH_META[name].get("priority", 1))
	return 0 if name in ["pin", "sling"] else 1

func min_gap_ms(name: String) -> int:
	if _meta.has(name):
		return int(_meta[name].get("min_gap_ms", 0))
	if SYNTH_META.has(name):
		return int(SYNTH_META[name].get("min_gap_ms", 0))
	return int(PIN_GAP_S * 1000.0) if name == "pin" else 0

## The controller's lane_changed: remembers which side entered a state last, so the
## sound played right after that step comes from that Dial's side. (A sound that follows a
## later event of a Dial, like the release, is given its side by the caller instead: the
## lane may have moved on by then.)
func on_lane(side: String, state: String) -> void:
	_side_of[state] = side

## The side a sound of `name` belongs to now ("" = the middle).
func side_of(name: String) -> String:
	return str(_side_of.get(SIDE_SOUNDS.get(name, ""), ""))

## Plays the sound `name`. `side` ("left"): the Dial it belongs to, when the
## caller knows it (an event of that Dial); left out, a Dial's sound takes the side that
## entered its lane state last (side_of). `pitch` > 0: played at that pitch (the result's
## counting blips climb as the number does).
func play(name: String, side := "", pitch := 0.0) -> void:
	var now := Time.get_ticks_msec()
	var gap := min_gap_ms(name)
	if gap > 0 and now - int(_last_ms.get(name, -100000)) < gap:
		return
	_last_ms[name] = now
	last_played = name
	last_pitch = pitch if pitch > 0.0 else 1.0
	if name == "gauge":
		gauge_blips += 1  # many per second: counted, not listed (they would push the rest out of the log)
	else:
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
	p.volume_db = volume_db + gain_db_of(name)
	var jitter := float(m.get("pitch_jitter", 0.0))
	p.pitch_scale = 1.0 + _rng.randf_range(-jitter, jitter)
	if name == "combo":
		p.pitch_scale = COMBO_PITCH[clampi(combo_step, 0, COMBO_PITCH.size() - 1)]
	if pitch > 0.0:
		p.pitch_scale = clampf(pitch, 0.25, 4.0)
	last_pitch = p.pitch_scale
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
	stop_cue()

# ------------------------------------------------------------------ #325: the countdowns
## The countdown `key` is played from its file (false: the old sound of each number).
func has_cue(key: String) -> bool:
	return enabled and use_files and _cue_files.has(key)

## The cue `key` says the number `n` (3/2/1/0 of the start, 10..0 of the end) itself, so the
## old sound of that number is not played (a longer countdown keeps it for the numbers before).
func cue_covers(key: String, n: int) -> bool:
	return has_cue(key) and n >= 0 and n < (CUE_ONSETS[key] as Array).size()

## Where in the cue the listener should be when `left` seconds are left before its last
## number (GO! / TIME UP): the last onset is put on 0 s.
static func cue_position(key: String, left: float) -> float:
	return float((CUE_ONSETS[key] as Array).back()) - left

## How far ahead of what is heard the mixer is (s): a sound started now is heard this late.
static func output_latency() -> float:
	return clampf(AudioServer.get_output_latency(), 0.0, 0.2)

## Each tick of a countdown: the cue `key` should be heard `at` seconds into its file now.
## Starts it there (output latency ahead, so it is heard on time) once it is due, puts it back
## when it has drifted from the screen (a long frame), and never starts it twice in a round
## (stop_cue ends the round's cue). Another cue playing is stopped for it.
func follow_cue(key: String, at: float) -> void:
	if not has_cue(key) or not is_inside_tree():
		return
	var want := at + output_latency()
	if cue == key:
		if _cue_player.playing and want < _cue_player.stream.get_length():
			var heard := _cue_player.get_playback_position() + AudioServer.get_time_since_last_mix()
			var now := Time.get_ticks_msec()
			if absf(heard - want) > CUE_SLACK_S and now - _cue_seek_ms >= CUE_RESEEK_MS:
				_cue_player.seek(maxf(want, 0.0))
				_cue_seek_ms = now
				cue_seeks += 1
		return
	var stream: AudioStream = _cue_files[key]
	if want < 0.0 or want >= stream.get_length() - 0.05:
		return  # not yet / too late to be heard
	_cue_player.stop()
	_cue_player.stream = stream
	_cue_player.volume_db = volume_db + float(CUE_GAIN_DB.get(key, 0.0))
	_cue_player.play(want)
	cue = key
	cue_from = want
	cue_starts += 1
	_cue_seek_ms = Time.get_ticks_msec()
	last_played = key
	log.append(key)
	if log.size() > 64:
		log.remove_at(0)

## The countdown is over (time up, the result): only the cue `keep` plays on (the end's voice
## is on its 0 at TIME UP and ends by itself 0.55 s later; follow_cue kept it in step); any
## other cue stops.
func end_cue(keep: String) -> void:
	if cue != "" and cue != keep:
		stop_cue()

## The cue stops now (a stop, the title, a new round).
func stop_cue() -> void:
	if _cue_player != null:
		_cue_player.stop()
	cue = ""

func cue_playing() -> bool:
	return _cue_player != null and _cue_player.playing

## The tune: on while the clock runs, the faster take for the last stretch.
func set_bgm(on: bool, fast := false) -> void:
	bgm_on = on
	hurry = on and fast
	if on and _jingle != null and _jingle.playing:
		_jingle.stop()
	if _bgm == null or not is_inside_tree():
		return
	_process(0.0)  # at once: no music fades (#181)

func _process(dt: float) -> void:
	if _bgm == null:
		return
	# the round's music from its file: one track to the end (the last stretch has its own
	# sounds; the synthesised hurry take is another tune and is not laid over it)
	var synth := not _music.has("game")
	var want := 1.0 if bgm_on and enabled and not silent and not hurry and synth else 0.0
	var want_fast := 1.0 if bgm_on and enabled and not silent and hurry and synth else 0.0
	var track := track_wanted()
	for t in _music.keys():
		var p: AudioStreamPlayer = _music[t]
		var on: bool = t == track
		if on and not p.playing:
			p.play()  # from its start, every time it comes back
		_music_gain[t] = 1.0 if on else 0.0  # no fade (#181): on or off at once
		_fade(p, float(_music_gain[t]), float(music_gain_db.get(t, 0.0)))
	_bgm_gain = want
	_fast_gain = want_fast
	for pair in [[_bgm, want], [_bgm_fast, want_fast]]:
		if pair[1] > 0.0 and not pair[0].playing:
			pair[0].play()
	_pickup_duck_left = maxf(_pickup_duck_left - dt, 0.0)
	_duck = move_toward(_duck, DUCK_DB if AudioBuses.voice_active() else 0.0, dt * 40.0)
	_fade(_bgm, _bgm_gain, TUNE_GAIN_DB)
	_fade(_bgm_fast, _fast_gain, TUNE_GAIN_DB)
	# the jingle is never over a music: silence ends it, and so does the round's or the result's
	# music (those start on time; a long jingle is cut, not laid over them)
	if _jingle != null and _jingle.playing and (silent or not enabled or bgm_on or ending_on):
		_jingle.stop()

func _fade(p: AudioStreamPlayer, gain: float, extra_db := 0.0) -> void:
	if gain <= 0.0:
		if p.playing:
			p.stop()
		return
	p.volume_db = volume_db + BGM_DB + minf(_duck, pickup_duck()) + extra_db + linear_to_db(maxf(gain, 0.001))

## The music is `db` lower for `seconds` (a pickup's sound is heard over it), then as it was:
## a step down and a step back, never a fade. A voice's own, deeper duck stays.
func duck(seconds: float, db: float) -> void:
	if seconds <= 0.0 or db >= 0.0:
		return
	_pickup_duck_left = seconds
	_pickup_duck_db = db
	if _bgm != null and is_inside_tree():
		_process(0.0)

func pickup_duck() -> float:
	return _pickup_duck_db if _pickup_duck_left > 0.0 else 0.0

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

extends SceneTree
## Writes the game's synthesised sounds to WAV files for tools/audio_levels.py (#304).
##
##     OUT=/some/dir godot --headless --path game --script ../tools/audio_dump_synth.gd
##
## gm_<key>.wav (GameModeSounds), gm_bgm_tune.wav, st_<key>.wav (StudySounds),
## cue_<key>.wav (Sfx's hand cues). The scripts are loaded at run time (GameConfig is an
## autoload, there only once the tree runs). Nothing here plays a sound or touches a device.

var _frames := 0
var _nodes: Array = []

func _initialize() -> void:
	var gm = load("res://scripts/game_mode/game_mode_sounds.gd")
	gm.load_music = false
	for path in ["res://scripts/game_mode/game_mode_sounds.gd", "res://scripts/study_mode/study_sounds.gd", "res://scripts/ui/sfx.gd"]:
		var n: Node = load(path).new()
		root.add_child(n)
		_nodes.append(n)

func _process(_dt: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false
	var out := OS.get_environment("OUT")
	if out == "" or not DirAccess.dir_exists_absolute(out):
		push_error("OUT must name an existing folder")
		return true
	var g = _nodes[0]
	for k in g._streams:
		_save(g._streams[k], out.path_join("gm_" + k + ".wav"))
	_save(g._bgm.stream, out.path_join("gm_bgm_tune.wav"))
	for k in _nodes[1]._streams:
		_save(_nodes[1]._streams[k], out.path_join("st_" + k + ".wav"))
	for k in _nodes[2]._cues:
		_save(_nodes[2]._cues[k], out.path_join("cue_" + k + ".wav"))
	print("[audio_dump_synth] done: ", out)
	return true

func _save(s, path: String) -> void:
	if s is AudioStreamWAV:
		(s as AudioStreamWAV).save_to_wav(path)

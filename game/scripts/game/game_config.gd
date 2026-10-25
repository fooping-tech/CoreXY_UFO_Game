extends Node
## Autoload: loads config/game_config.json (repo root) with built-in defaults.
## Values can also be changed at runtime from the debug UI.

const DEFAULTS := {
	"robot": {
		"x_min_mm": 0.0, "x_max_mm": 390.0,
		"y_min_mm": 0.0, "y_max_mm": 200.0,
		"z_min_mm": 0.0, "z_max_mm": 100.0,
		"z_up_is_positive": true,
	},
	"world": {"travel_x_cm": 52.0, "travel_z_cm": 36.0, "rope_min_cm": 16.0, "rope_max_cm": 70.0,
		"fit_travel_x_to_screen": true},
	"physics": {
		"segment_count": 16, "substeps": 16, "gravity": 980.0, "damping": 0.45,
		"ufo_drag": 0.25, "ufo_mass": 25.0, "rope_length_rate": 60.0, "swing_gain": 1.0,
	},
	"projection": {"pitch_deg": 28.0, "pixels_per_unit": 6.0, "xy_display_scale": 1.0, "perspective": 0.0045, "depth_scale": 1.0, "edge_margin_px": 24.0},
	"render": {"pixel_scale": 3.0, "rope_width_px": 6.0, "particles": true, "screen_shake": true, "shake_max_px": 12.0, "particle_amount": 1.0},
	"audio": {"enabled": true, "volume_db": -8.0, "dir": "res://assets/audio",
		"move": "wizard-flight1.mp3", "up": "magic-statusup1.mp3", "down": "hyun1.mp3"},
	"camera": {"enabled": true,
		"overview": {"match": "C270", "flip_h": false, "flip_v": false},
		"focus": {"match": "", "flip_h": false, "flip_v": false},
		"scope": {"enabled": true, "settle_s": 0.7, "hold_s": 10.0, "zoom": 1.0}},
	"network": {"websocket_url": "ws://127.0.0.1:8765", "state_timeout_ms": 1500, "command_timeout_ms": 3000},
}

var data: Dictionary = {}
var loaded_from: String = "(defaults)"

func _ready() -> void:
	data = DEFAULTS.duplicate(true)
	for path in _candidate_paths():
		if FileAccess.file_exists(path):
			var f := FileAccess.open(path, FileAccess.READ)
			if f == null:
				continue
			var parsed = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				_merge(data, parsed)
				loaded_from = path
				break
	print("[GameConfig] loaded from ", loaded_from)

func _candidate_paths() -> Array[String]:
	var out: Array[String] = []
	# Running from the editor / `godot --path game`: repo-root config/ is one up.
	var root := ProjectSettings.globalize_path("res://")
	out.append(root.path_join("../config/game_config.json").simplify_path())
	# Exported build: next to the executable, or bundled copy.
	out.append(OS.get_executable_path().get_base_dir().path_join("config/game_config.json"))
	out.append("res://config/game_config.json")
	return out

func _merge(dst: Dictionary, src: Dictionary) -> void:
	for k in src.keys():
		if dst.has(k) and dst[k] is Dictionary and src[k] is Dictionary:
			_merge(dst[k], src[k])
		else:
			dst[k] = src[k]

func get_value(section: String, key: String, fallback = null):
	if data.has(section) and data[section] is Dictionary and data[section].has(key):
		return data[section][key]
	return fallback

func robot() -> Dictionary:
	return data["robot"]

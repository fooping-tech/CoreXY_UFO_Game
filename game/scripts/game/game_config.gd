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
	"gesture": {"enabled": false, "allow_real_robot": false, "camera": "C270", "stale_ms": 350.0, "arm_delay_ms": 120.0,
		"scheme": "pinch_joystick", "schemes": {},
		"roi": [0.0, 0.0, 1.0, 1.0], "roi_enabled": false, "pinch_start": 1.0, "pinch_release": 1.5, "pinch_confirm_ms": 0.0, "lost_grace_ms": 300.0,
		"joystick": {"radius": 0.15, "deadzone": 0.12, "full": 0.8, "max_speed_mm_s": 30.0, "curve": 1.5, "smoothing_ms": 80.0,
			"invert_x": false, "invert_y": false, "swap_xy": false}},
	"camera": {"enabled": true,
		"overview": {"match": "C270", "flip_h": false, "flip_v": false},
		"focus": {"match": "Innomaker", "flip_h": false, "flip_v": false},
		"scope": {"enabled": true, "settle_s": 0.7, "hold_s": 10.0, "zoom": 1.0}},
	"network": {"websocket_url": "ws://127.0.0.1:8765", "state_timeout_ms": 1500, "command_timeout_ms": 3000},
	"study": {"enabled": false, "timeout_s": 90.0, "max_image_bytes": 700000,
		"max_image_edge": 1280, "camera_role": "overview"},
	"homework": {"enabled": false, "interval_s": 10.0, "timeout_s": 30.0, "max_image_edge": 1024,
		"max_image_bytes": 700000, "camera_role": "overview", "stall_s": 180.0, "stall_min_gain": 5.0,
		"advice_timeout_s": 120.0},
}

var data: Dictionary = {}
var loaded_from: String = "(defaults)"

## The settings screen (#93): config/settings_schema.json says which keys it may change;
## config/local_settings.json (not in Git) holds the changed ones and is read over
## game_config.json. Keys or values the schema does not allow are ignored, so a hand-edited
## file cannot reach the calibration or the safety settings.
const SCHEMA_FILE := "settings_schema.json"
const LOCAL_FILE := "local_settings.json"
var schema: Dictionary = {}
var base: Dictionary = {}    # data without the local overrides
var local: Dictionary = {}   # "a.b.c" -> value: the overrides in use
var local_path := ""
var local_warnings: Array[String] = []

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
	base = data.duplicate(true)
	var dir := loaded_from.get_base_dir() if loaded_from != "(defaults)" else ""
	if dir != "":
		var sc = read_json(dir.path_join(SCHEMA_FILE))
		schema = sc if sc is Dictionary else {}
		local_path = dir.path_join(str(schema.get("file", LOCAL_FILE)))
		load_local()

## Reads local_path over the base (again): only what the schema allows.
func load_local() -> void:
	for k in local.keys():
		path_set(data, k, path_get(base, k))
	local = {}
	local_warnings = []
	if local_path == "" or not FileAccess.file_exists(local_path):
		return
	var raw = read_json(local_path)
	if not raw is Dictionary:
		local_warnings.append("%s が読めません（JSON のオブジェクトではない）" % local_path)
	else:
		local = filter_overrides(flatten(raw), schema_items(schema), local_warnings)
	for k in local.keys():
		path_set(data, k, local[k])
	for w in local_warnings:
		push_warning("[GameConfig] " + w)
	if not local.is_empty():
		print("[GameConfig] local settings from ", local_path, ": ", ", ".join(local.keys()))

## Drops the overrides for this run (the tests: the machine's own file must not change them).
func drop_local() -> void:
	for k in local.keys():
		path_set(data, k, path_get(base, k))
	local = {}

## The settings screen's save: `values` maps keys to the form's values. Keeps those that
## differ from game_config.json (the rest are the default again), writes them to
## local_path and uses them in `data` (most parts read it at start: the next start).
## Returns "" or the reason it could not be written.
func save_local(values: Dictionary) -> String:
	if local_path == "":
		return "設定ファイルの場所がわかりません"
	var items := schema_items(schema)
	var keep := local.duplicate()
	for k in values.keys():
		if not items.has(k):
			return "この画面では変えられない項目です: %s" % k
		var v = check_value(items[k], values[k])
		if v == null:
			return "値が正しくありません: %s" % k
		if same_value(v, path_get(base, k)):
			keep.erase(k)
		else:
			keep[k] = v
	var text := JSON.stringify(nest(keep), "  ", true)
	var f := FileAccess.open(local_path, FileAccess.WRITE)
	if f == null:
		return "%s に書けません（%s）" % [local_path, error_string(FileAccess.get_open_error())]
	f.store_string(text + "\n")
	f.close()
	for k in local.keys():
		path_set(data, k, path_get(base, k))
	local = keep
	for k in local.keys():
		path_set(data, k, local[k])
	return ""

func value(key: String, fallback = null):
	return path_get(data, key, fallback)

func base_value(key: String, fallback = null):
	return path_get(base, key, fallback)

static func read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(f.get_as_text()) if f != null else null

## key -> item of every section
static func schema_items(sc: Dictionary) -> Dictionary:
	var out := {}
	var secs = sc.get("sections", [])
	if secs is Array:
		for sec in secs:
			if sec is Dictionary and sec.get("items") is Array:
				for it in sec["items"]:
					if it is Dictionary and it.has("key"):
						out[str(it["key"])] = it
	return out

## The value as the item allows it, or null when it does not.
static func check_value(item: Dictionary, v):
	match str(item.get("type", "")):
		"bool":
			return v if v is bool else null
		"enum":
			for o in item.get("options", []):
				if o is Array and o.size() > 0 and v is String and str(o[0]) == v:
					return v
			return null
		"number":
			if not (v is float or v is int) or is_nan(float(v)) or is_inf(float(v)):
				return null
			var x := float(v)
			if item.has("min") and x < float(item["min"]) or item.has("max") and x > float(item["max"]):
				return null
			return x
		"text":
			if not v is String or v.length() > int(item.get("max_length", 200)):
				return null
			for ch in v:
				if ch.unicode_at(0) < 32:
					return null  # no control characters (newlines, escapes)
			return v
	return null

static func filter_overrides(flat: Dictionary, items: Dictionary, warnings: Array[String]) -> Dictionary:
	var out := {}
	for k in flat.keys():
		if not items.has(k):
			warnings.append("設定画面で変えられない項目は使いません: %s" % k)
			continue
		var v = check_value(items[k], flat[k])
		if v == null:
			warnings.append("値が正しくないので使いません: %s = %s" % [k, str(flat[k])])
			continue
		out[k] = v
	return out

static func same_value(a, b) -> bool:
	if (a is float or a is int) and (b is float or b is int):
		return is_equal_approx(float(a), float(b))
	return typeof(a) == typeof(b) and a == b

static func flatten(d: Dictionary, prefix := "") -> Dictionary:
	var out := {}
	for k in d.keys():
		var key := str(k) if prefix == "" else prefix + "." + str(k)
		if d[k] is Dictionary and not (d[k] as Dictionary).is_empty():
			out.merge(flatten(d[k], key))
		else:
			out[key] = d[k]
	return out

static func nest(flat: Dictionary) -> Dictionary:
	var out := {}
	for k in flat.keys():
		path_set(out, k, flat[k])
	return out

static func path_get(d: Dictionary, key: String, fallback = null):
	var cur = d
	for part in key.split("."):
		if not (cur is Dictionary and cur.has(part)):
			return fallback
		cur = cur[part]
	return cur

static func path_set(d: Dictionary, key: String, v) -> void:
	var parts := key.split(".")
	var cur := d
	for i in range(parts.size() - 1):
		if not cur.get(parts[i]) is Dictionary:
			cur[parts[i]] = {}
		cur = cur[parts[i]]
	cur[parts[parts.size() - 1]] = v

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

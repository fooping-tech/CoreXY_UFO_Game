class_name CapsuleColourProbe
extends CanvasLayer
## #291: カプセル色判定テスト. Shows why the arm camera's frame is a colour (or the capsule
## would be normal), with the same CapsuleKinds.classify() and Reader the score game uses
## (no second algorithm): the frame that was judged (the focus role: the stabilized stream
## when it is live), the ROI, a mask of what each looked-at pixel was (red / blue / green, too
## grey, too dark, no colour's hue), the counts and shares (the left-out pixels are in the
## denominator), the hues of the saturated pixels, min_share / dominance passed or not, the
## frame's verdict and why, and the votes of memory_s seconds with the final kind.
##
## The values tried here are this screen's own copy: they start as the game's (the running
## round's, else game_config.json) and are never given to the game or written to the config.
## 戻す takes the game's again; コピー / 保存 hand the tried values out explicitly
## (the clipboard, a file under user://capsule_probe/). Each frame is judged with the tried
## values and with the game's, side by side.
##
## Paused, the frame stays and a changed value judges it again (no vote); 1 フレーム takes
## one. Recording writes one JSON line per judged frame (user://capsule_probe/*.jsonl) with
## what the capsule shown really is (the label), so the hit rate and the undecided rate can be
## counted; an image is saved only by its button. A missing camera, a failed read or a frame
## that did not change is shown as such and never voted.
##
## Opened from the debug panel's カメラ tab; works in any screen and stands alone (no round,
## no crane, no Dial). With a round running it also shows the game's own reading (read only).
## Never a robot or Dial command. Closed, it does nothing.

signal closed

const WIDTH := 680.0
const VIEW_H := 440.0
const DIR := "user://capsule_probe/"
const KIND_LABELS := {"fire": "赤（fire）", "water": "青（water）", "green": "緑（green）", "thunder": "黄（thunder）",
	"dark": "紫（dark）", "": "なし"}
## the short name of each colour in the counts (CapsuleKinds.COLOURED's order)
const SHORT := {"fire": "赤", "water": "青", "green": "緑", "thunder": "黄", "dark": "紫"}
## what the capsule in front of the camera really is (the recording's label)
const LABELS := [["", "ラベルなし"], ["fire", "赤のカプセル"], ["water", "青のカプセル"], ["green", "緑のカプセル"],
	["thunder", "黄のカプセル"], ["dark", "紫のカプセル"], ["none", "カプセルなし（背景のみ）"]]
const FRAME_STATUS := {"live": "取得", "no_camera": "カメラ未接続", "headless": "画面なし（headless）",
	"failed": "取得失敗", "stale": "未更新（前と同じ画像）", "none": "まだ取っていない", "file": "保存した画像"}
const MASK_COLORS := {CapsuleKinds.SAMPLE_LOW_SAT: Color(0.1, 0.12, 0.3, 0.55),
	CapsuleKinds.SAMPLE_LOW_VAL: Color(0, 0, 0, 0.7), CapsuleKinds.SAMPLE_HUE_MISS: Color(1, 0.4, 1, 0.75)}

var main: Node
## where frames come from: func() -> Image (tests). Unset: the arm camera (CameraHub focus).
var frame_source := Callable()
## the values tried (the read section) and the memory; the game's, to compare and go back to
var cfg := {}
var memory_s := 20.0
var base_cfg := {}
var base_memory := 20.0
var reader := CapsuleKinds.Reader.new()
var base_reader := CapsuleKinds.Reader.new()
var paused := false
var frame: Image = null
## the last grab: {"status": FRAME_STATUS key, "camera", "stabilized", "w", "h", "at" (unix s)}
var frame_info := {"status": "none"}
var result := {}
var base_result := {}
var show_mask := true
var show_left_out := false
var recording := false
var label := ""
var export_path := ""
var lines_written := 0
## label -> {"n": frames, "cur": {kind: n}, "base": {kind: n}}
var tally := {}
var dir := DIR
## frames that were the same as the one before (not voted here; the game does vote them)
var stale_frames := 0
var _file_out: FileAccess = null
var _frame_tex: ImageTexture = null
var _sample_left := 0.0
## the game's values vote at the game's own sample_hz (review on #293), not the tried one
var _base_left := 0.0
var _last_hash := -1
var _root: Control
var _status: Label
var _pause_b: Button
var _view_holder: Control
var _view: TextureRect
var _mask: TextureRect
var _overlay: Control
var _mask_tex: ImageTexture
var _numbers: Label
var _hist: Control
var _votes: Label
var _game: Label
var _spins := {}
var _record_info: Label
var _tally_label: Label
var _record_cb: CheckBox

func setup(m: Node) -> void:
	main = m
	layer = 30  # over the title, the settings screen and the debug panel
	reset_settings()
	_build()
	visible = false
	set_process(false)

func active() -> bool:
	return visible

func open() -> void:
	# the game's values may have changed since (a new round, a reloaded config): compare with
	# them now; the tried values stay as they were
	var g := game_settings()
	base_cfg = g.read
	base_memory = g.memory_s
	base_reader.memory_s = base_memory
	visible = true
	set_process(true)
	_sample_left = 0.0
	_base_left = 0.0
	refresh()

func close() -> void:
	set_recording(false)
	visible = false
	set_process(false)
	closed.emit()

func _process(dt: float) -> void:
	tick(dt)

## One step of the screen's time (the tests call it).
func tick(dt: float) -> void:
	reader.advance(dt)
	base_reader.advance(dt)
	if not paused:
		# one frame serves both when both are due; each set of votes keeps its own rate
		_sample_left -= dt
		_base_left -= dt
		var cur := _sample_left <= 0.0
		var base := _base_left <= 0.0
		if cur:
			_sample_left = 1.0 / maxf(float(cfg.sample_hz), 0.5)
		if base:
			_base_left = 1.0 / maxf(float(base_cfg.sample_hz), 0.5)
		if cur or base:
			sample(cur, base)
	# the votes' window moves on, paused too (review on #293): what is shown keeps up
	if _votes != null:
		_votes.text = votes_text()
	_refresh_game()

# ------------------------------------------------------------------ the values
## The game's values: the running round's (main.game_mode), else the config's.
func game_settings() -> Dictionary:
	var gm = main.get("game_mode") if main != null else null
	if gm != null:
		return {"read": (gm.kinds.read as Dictionary).duplicate(true), "memory_s": float(gm.colour_reader.memory_s)}
	var ck = GameConfig.get_value("game_mode", "capsule_kinds", {})
	ck = ck if ck is Dictionary else {}
	var k := CapsuleKinds.new()
	k.configure(ck)
	return {"read": k.read.duplicate(true), "memory_s": clampf(float(ck.get("memory_s", 20.0)), 2.0, 120.0)}

## 戻す: the game's values again (the frame shown is judged again).
func reset_settings() -> void:
	var g := game_settings()
	base_cfg = g.read
	base_memory = g.memory_s
	cfg = base_cfg.duplicate(true)
	memory_s = base_memory
	reader.memory_s = memory_s
	base_reader.memory_s = base_memory
	_sync_spins()
	rejudge()

## The tried values, as they would go in config game_mode.capsule_kinds.
func settings_json() -> Dictionary:
	return {"read": cfg.duplicate(true), "memory_s": memory_s}

## Changes one tried value: "min_sat", "roi:0".."roi:3", "hue:fire:0" / "hue:fire:1", "memory_s", ...
func set_value(key: String, v: float) -> void:
	var parts := key.split(":")
	match parts[0]:
		"roi":
			var roi: Array = (cfg.roi as Array).duplicate()
			roi[int(parts[1])] = clampf(v, 0.0, 1.0)
			cfg.roi = roi
		"hue":
			var hues: Dictionary = (cfg.hues as Dictionary).duplicate(true)
			var r: Array = (hues.get(parts[1], [0.0, 0.0]) as Array).duplicate()
			r[int(parts[2])] = clampf(v, 0.0, 1.0)
			hues[parts[1]] = r
			cfg.hues = hues
		"memory_s":
			memory_s = clampf(v, 2.0, 120.0)
			reader.memory_s = memory_s
		"min_votes":
			cfg.min_votes = maxi(1, int(v))
		_:
			cfg[parts[0]] = v
	rejudge()

func value_of(key: String) -> float:
	var parts := key.split(":")
	match parts[0]:
		"roi":
			return float(cfg.roi[int(parts[1])])
		"hue":
			return float(cfg.hues.get(parts[1], [0.0, 0.0])[int(parts[2])])
		"memory_s":
			return memory_s
	return float(cfg.get(parts[0], 0.0))

func copy_settings() -> String:
	var t := JSON.stringify(settings_json(), "  ")
	DisplayServer.clipboard_set(t)
	_say("試した値をクリップボードにコピーした（config の game_mode.capsule_kinds に手で入れる）")
	return t

## 保存: the tried values in a file of their own (never the game's config).
func save_settings() -> String:
	var path := _file("read_%s.json" % _stamp())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_say("保存できなかった: " + path)
		return ""
	f.store_string(JSON.stringify(settings_json(), "  "))
	f.close()
	_say("試した値を保存: " + ProjectSettings.globalize_path(path))
	return path

# ------------------------------------------------------------------ frames
func set_paused(on: bool) -> void:
	paused = on
	refresh()

## 1 フレーム: one frame now (voted), paused or not.
func step_frame() -> void:
	sample()

## A saved picture (画像を保存's PNG, or any image file), judged once and held (paused): the
## same picture with other values. False when it cannot be read.
func load_image(path: String) -> bool:
	var img := Image.load_from_file(path) if FileAccess.file_exists(path) else null
	paused = true
	if img == null or img.is_empty():
		frame_info = {"status": "failed", "camera": path, "stabilized": false, "w": 0, "h": 0,
			"at": Time.get_unix_time_from_system()}
		frame = null
		result = CapsuleKinds.classify(null)
		base_result = result
		refresh()
		return false
	frame_info = {"status": "file", "camera": path.get_file(), "stabilized": false, "w": img.get_width(),
		"h": img.get_height(), "at": Time.get_unix_time_from_system()}
	frame = img
	_show_frame()
	judge(true)
	return true

func clear_votes() -> void:
	reader.clear()
	base_reader.clear()
	refresh()

## A frame of the arm camera, judged and voted when it is a new one: by the tried values'
## votes (`cur`) and the game's (`base`), each when its sample is due.
func sample(cur := true, base := true) -> void:
	var g := _grab()
	frame_info = g
	var img: Image = g.get("img")
	g.erase("img")
	if g.status != "live":
		if g.status == "stale":
			stale_frames += 1
		else:
			frame = null
			result = CapsuleKinds.classify(null)
			base_result = result
		refresh()
		return
	frame = img
	_show_frame()
	judge(true, cur, base)

## The frame on screen: one texture, updated in place when the size stays.
func _show_frame() -> void:
	if _view == null:
		return
	if frame == null:
		_view.texture = null
		return
	if _frame_tex == null or Vector2i(_frame_tex.get_size()) != frame.get_size():
		_frame_tex = ImageTexture.create_from_image(frame)
	else:
		_frame_tex.update(frame)
	_view.texture = _frame_tex

## Judges the frame shown again with the values now (no vote: the same picture once more).
func rejudge() -> void:
	if frame != null:
		judge(false)
	else:
		refresh()

func judge(vote: bool, cur := true, base := true) -> void:
	result = CapsuleKinds.classify(frame, cfg, true)
	base_result = CapsuleKinds.classify(frame, base_cfg)
	if vote:
		if cur:
			reader.add(str(result.kind))
		if base:
			base_reader.add(str(base_result.kind))
		_count()
		if recording:
			_write(record())
	_update_mask()
	refresh()

func _grab() -> Dictionary:
	var out := {"status": "none", "camera": "", "stabilized": false, "w": 0, "h": 0,
		"at": Time.get_unix_time_from_system()}
	var img: Image = null
	if frame_source.is_valid():
		out.camera = "test"
		img = frame_source.call()
	else:
		var cams = main.get("cameras") if main != null else null
		if cams == null or not cams.has_feed("focus"):
			out.status = "no_camera"
			return out
		if DisplayServer.get_name() == "headless":
			out.status = "headless"
			return out
		out.camera = cams.feed_name("focus")
		out.stabilized = cams.external_live("focus") and bool(cams.stream.header.get("stabilized", true))
		var tex: Texture2D = cams.texture("focus")
		img = tex.get_image() if tex != null else null
	if img == null or img.is_empty():
		out.status = "failed"
		return out
	out.w = img.get_width()
	out.h = img.get_height()
	# a camera that stopped keeps giving the same picture: never judged as a new frame
	var hsh := hash(img.get_data())
	out.status = "stale" if hsh == _last_hash else "live"
	_last_hash = hsh
	out.img = img
	return out

# ------------------------------------------------------------------ recording
func set_recording(on: bool) -> void:
	recording = on
	if on and export_path == "":
		export_path = _file("probe_%s.jsonl" % _stamp())
	if not on and _file_out != null:
		_file_out.close()
		_file_out = null
	refresh()

func set_label(l: String) -> void:
	label = l
	refresh()

## One frame's line: when, the picture's size, the camera, the values, the counts, the
## frame's verdict (tried and game values), the votes and the final kind; the round's reading.
func record() -> Dictionary:
	var votes := reader.explain(int(cfg.min_votes), float(cfg.min_ratio))
	var base_votes := base_reader.explain(int(base_cfg.min_votes), float(base_cfg.min_ratio))
	var line := {"time": Time.get_datetime_string_from_unix_time(int(frame_info.get("at", 0)), true),
		"unix": float(frame_info.get("at", 0.0)), "label": label,
		"image": {"w": int(frame_info.get("w", 0)), "h": int(frame_info.get("h", 0))},
		"camera": {"name": str(frame_info.get("camera", "")), "stabilized": bool(frame_info.get("stabilized", false)),
			"status": str(frame_info.get("status", ""))},
		"settings": settings_json(), "result": plain(result),
		"base": {"kind": base_result.get("kind", ""), "reason": base_result.get("reason", ""),
			"share": base_result.get("share", 0.0)},
		"votes": votes, "final": votes.kind, "base_final": base_votes.kind}
	var gs := _game_status()
	if not gs.is_empty():
		gs.last = plain(gs.last)
		line.game = gs
	return line

## classify()'s answer without the mask, ready for JSON.
static func plain(r: Dictionary) -> Dictionary:
	var out := r.duplicate(true)
	out.erase("samples")
	if out.get("hue_hist") is PackedInt32Array:
		out.hue_hist = Array(out.hue_hist)
	var roi = out.get("roi")
	if roi is Rect2i:
		out.roi = [roi.position.x, roi.position.y, roi.size.x, roi.size.y]
	return out

## One line more; the file stays open while recording (closed when it stops).
func _write(line: Dictionary) -> void:
	if _file_out == null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
		_file_out = FileAccess.open(export_path, FileAccess.READ_WRITE if FileAccess.file_exists(export_path) else FileAccess.WRITE)
		if _file_out == null:
			_say("書けなかった: " + export_path)
			return
		_file_out.seek_end()
	_file_out.store_line(JSON.stringify(line))
	_file_out.flush()
	lines_written += 1

func _count() -> void:
	if label == "":
		return
	var t: Dictionary = tally.get(label, {"n": 0, "cur": {}, "base": {}})
	t.n += 1
	var k := str(result.kind)
	var bk := str(base_result.kind)
	t.cur[k] = int(t.cur.get(k, 0)) + 1
	t.base[bk] = int(t.base.get(bk, 0)) + 1
	tally[label] = t

## {right, undecided, wrong} frames of `lbl` with the tried values ("cur") or the game's ("base").
func rates(lbl: String, which := "cur") -> Dictionary:
	var t: Dictionary = tally.get(lbl, {})
	var out := {"n": int(t.get("n", 0)), "right": 0, "undecided": 0, "wrong": 0}
	var counts: Dictionary = t.get(which, {})
	for k in counts:
		var n := int(counts[k])
		if (lbl == "none" and k == "") or k == lbl:
			out.right += n
		elif k == "":
			out.undecided += n
		else:
			out.wrong += n
	return out

## 画像を保存: the frame shown, as a PNG (only by this button).
func save_image() -> String:
	if frame == null:
		_say("保存する画像がない")
		return ""
	var path := _file("frame_%s.png" % _stamp())
	if frame.save_png(path) != OK:
		_say("保存できなかった: " + path)
		return ""
	_say("画像を保存: " + ProjectSettings.globalize_path(path))
	return path

func _file(name: String) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	return dir.path_join(name)

static func _stamp() -> String:
	return Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "_") \
		+ "_%03d" % (Time.get_ticks_msec() % 1000)

# ------------------------------------------------------------------ the game's reading
func _game_status() -> Dictionary:
	var gm = main.get("game_mode") if main != null else null
	if gm == null or not gm.has_method("colour_status"):
		return {}
	return gm.colour_status()

func game_text() -> String:
	var st := _game_status()
	if st.is_empty():
		return "ゲーム: スコアゲームがない"
	if not bool(st.active):
		return "ゲーム: スコアゲームは動いていない（この画面だけで計測中）"
	var v: Dictionary = st.votes
	var s := "ゲーム %s・%s" % [st.phase, "読取中" if st.reading else "読んでいない"]
	if st.easy:
		s += "・かんたん %s %s" % [st.easy_state, st.easy_step]
	s += "\n票（%d 秒）: %s・色なし %d → %s（%s）" % [int(st.memory_s), counts_text(v.counts), int(v.none), str(v.kind),
		CapsuleKinds.VOTE_REASONS.get(str(v.reason), str(v.reason))]
	var last: Dictionary = st.last
	if not last.is_empty():
		s += "\n最後のフレーム: %s（%s）%.1f 秒前" % [KIND_LABELS.get(str(last.kind), str(last.kind)),
			CapsuleKinds.REASONS.get(str(last.reason), str(last.reason)), float(st.clock) - float(last.get("at", st.clock))]
	if float(st.cleared_at) >= 0.0:
		s += "\n票のリセット: %.1f 秒前" % (float(st.clock) - float(st.cleared_at))
	for e in st.events:
		s += "\n  %.1f 秒前 %s %s" % [float(st.clock) - float(e[0]), {"reset": "リセット", "decided": "確定"}.get(e[1], e[1]), e[2]]
	if str(st.last_kind) != "":
		s += "\n最後に確定した種類: " + str(st.last_kind)
	return s

func _refresh_game() -> void:
	if _game != null:
		_game.text = game_text()

# ------------------------------------------------------------------ text
func numbers_text() -> String:
	var fi := frame_info
	var s := "フレーム: %s" % FRAME_STATUS.get(str(fi.get("status", "none")), str(fi.get("status")))
	if int(fi.get("w", 0)) > 0:
		s += "・%d×%d" % [int(fi.w), int(fi.h)]
	if str(fi.get("camera", "")) != "":
		s += "・" + str(fi.camera) + ("・揺れ補正" if bool(fi.get("stabilized", false)) else "")
	if stale_frames > 0:
		s += "・未更新で票に入れなかったフレーム %d（ゲームはこれも票に入れる）" % stale_frames
	if paused:
		s += "・一時停止中（値を変えると同じ画像で判定し直す。票は増えない）"
	if result.is_empty() or str(result.get("reason", "no_frame")) == "no_frame":
		return s + "\n判定: なし（%s）" % CapsuleKinds.REASONS.no_frame
	var r := result
	var looked := maxi(int(r.looked), 1)
	var roi: Rect2i = r.roi
	s += "\nROI: x %d y %d w %d h %d（%d 画素）・間引き %d → 見た画素 %d" % [roi.position.x, roi.position.y,
		roi.size.x, roi.size.y, int(r.roi_pixels), int(r.step), int(r.looked)]
	s += "\n色ごと（分母は見た画素すべて）: %s" % counts_text(r.counts, r.shares)
	s += "\n除外: 彩度不足 %d（%.1f%%）・明度不足 %d（%.1f%%）・色相範囲外 %d（%.1f%%）" % [
		int(r.low_sat), 100.0 * r.low_sat / looked, int(r.low_val), 100.0 * r.low_val / looked,
		int(r.hue_miss), 100.0 * r.hue_miss / looked]
	var ratio := "∞" if int(r.second_n) == 0 else "%.2f" % (float(r.best_n) / float(r.second_n))
	s += "\n最多 %s %d・2 位 %s %d・比 %s" % [KIND_LABELS.get(str(r.best), "-"), int(r.best_n),
		KIND_LABELS.get(str(r.second), "-"), int(r.second_n), ratio]
	s += "\nmin_share %.3f: %s・dominance %.2f: %s" % [float(cfg.min_share), "○" if r.share_ok else "×",
		float(cfg.dominance), "○" if r.dominance_ok else "×"]
	s += "\nこのフレーム: %s（%s）　ゲームの値なら: %s（%s）" % [KIND_LABELS.get(str(r.kind), str(r.kind)),
		CapsuleKinds.REASONS.get(str(r.reason), str(r.reason)), KIND_LABELS.get(str(base_result.get("kind", "")), "?"),
		CapsuleKinds.REASONS.get(str(base_result.get("reason", "")), "?")]
	return s

## "赤 3・青 0・..." of every colour (with `shares`: "赤 3（1.2%）・...").
static func counts_text(counts: Dictionary, shares := {}) -> String:
	var parts: Array[String] = []
	for k in CapsuleKinds.COLOURED:
		var n := int(counts.get(k, 0))
		if shares.is_empty():
			parts.append("%s %d" % [SHORT[k], n])
		else:
			parts.append("%s %d（%.1f%%）" % [SHORT[k], n, 100.0 * float(shares.get(k, 0.0))])
	return "・".join(parts)

func votes_text() -> String:
	var v := reader.explain(int(cfg.min_votes), float(cfg.min_ratio))
	var bv := base_reader.explain(int(base_cfg.min_votes), float(base_cfg.min_ratio))
	var s := "票（直近 %d 秒）: %s・色なし %d" % [int(memory_s), counts_text(v.counts), int(v.none)]
	s += "\nmin_votes %d: %s・min_ratio %.2f: %s（%.2f）" % [int(cfg.min_votes), "○" if v.votes_ok else "×",
		float(cfg.min_ratio), "○" if v.ratio_ok else "×", float(v.ratio)]
	s += "\n最終判定: %s（%s）　ゲームの値なら: %s" % [str(v.kind), CapsuleKinds.VOTE_REASONS.get(str(v.reason), str(v.reason)),
		str(bv.kind)]
	if float(v.first_at) >= 0.0:
		s += "\n票の始まり: %.1f 秒前" % (reader.clock - float(v.first_at))
	if reader.cleared_at >= 0.0:
		s += "・リセット: %.1f 秒前" % (reader.clock - reader.cleared_at)
	return s

func tally_text() -> String:
	if tally.is_empty():
		return "集計: ラベルを選んで撮ると、ラベルごとに 正しい / 未判定 / 誤り のフレーム数を数える"
	var lines: Array[String] = []
	for l in LABELS:
		var k: String = l[0]
		if k == "" or not tally.has(k):
			continue
		var c := rates(k, "cur")
		var b := rates(k, "base")
		lines.append("%s %d: 試した値 正 %d・未判定 %d・誤 %d／ゲームの値 正 %d・未判定 %d・誤 %d" % [l[1], c.n,
			c.right, c.undecided, c.wrong, b.right, b.undecided, b.wrong])
	return "\n".join(lines)

func _say(t: String) -> void:
	if _record_info != null:
		_record_info.text = t

func refresh() -> void:
	if _root == null:
		return
	_status.text = "フレーム: " + FRAME_STATUS.get(str(frame_info.get("status", "none")), "?")
	_status.add_theme_color_override("font_color", PanelKit.GOOD if frame_info.get("status") in ["live", "file"] else PanelKit.BAD)
	_pause_b.text = "再開" if paused else "一時停止"
	if frame == null:
		_view.texture = null
	_numbers.text = numbers_text()
	_votes.text = votes_text()
	_tally_label.text = tally_text()
	_record_cb.set_pressed_no_signal(recording)
	if recording and export_path != "":
		_record_info.text = "記録中: %s（%d 行）" % [ProjectSettings.globalize_path(export_path), lines_written]
	_mask.visible = show_mask and frame != null and result.has("samples")
	_layout_mask()
	_overlay.queue_redraw()
	_hist.queue_redraw()
	_refresh_game()

# ------------------------------------------------------------------ the screen
func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.04, 0.1, 1.0)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(shade)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = 16
	scroll.offset_right = -16
	scroll.offset_top = 12
	scroll.offset_bottom = -12
	_root.add_child(scroll)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	scroll.add_child(box)

	var row := PanelKit.row(box)
	row.add_child(StudyHud.label("カプセル色判定テスト", 28, PanelKit.YELLOW, 6))
	row.add_child(PanelKit.button("閉じる", 18, close))
	PanelKit.wrapped(box, "アームのカメラ（focus）のフレームを、スコアゲームと同じ判定（CapsuleKinds.classify と票）で調べる。"
		+ "ここで変えた値はゲームにも設定ファイルにも入らない。ロボット・Dial には何も送らない。", 14, PanelKit.MUTED, 2, WIDTH)
	row = PanelKit.row(box)
	_status = StudyHud.label("", 17, PanelKit.GOOD, 2)
	row.add_child(_status)
	_pause_b = PanelKit.button("一時停止", 16, func(): set_paused(not paused))
	row.add_child(_pause_b)
	row.add_child(PanelKit.button("1 フレーム", 16, step_frame))
	row.add_child(PanelKit.button("票をリセット", 16, clear_votes))
	row.add_child(PanelKit.button("画像を保存", 16, func(): save_image()))

	var frame_box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("0b1122")
	frame_box.add_theme_stylebox_override("panel", sb)
	box.add_child(frame_box)
	_view_holder = Control.new()
	_view_holder.custom_minimum_size = Vector2(WIDTH, VIEW_H)
	_view_holder.clip_contents = true
	_view_holder.resized.connect(func():
		if _mask != null and _overlay != null:
			_layout_mask()
			_overlay.queue_redraw())
	frame_box.add_child(_view_holder)
	_view = TextureRect.new()
	_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_view_holder.add_child(_view)
	_mask = TextureRect.new()
	_mask.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_mask.stretch_mode = TextureRect.STRETCH_SCALE
	_mask.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_view_holder.add_child(_mask)
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	_view_holder.add_child(_overlay)

	row = PanelKit.row(box)
	for o in [["show_mask", "色のマスク", true], ["show_left_out", "除外した画素も（紺 彩度不足・黒 明度不足・桃 色相範囲外）", false]]:
		var key: String = o[0]
		var cb := CheckBox.new()
		cb.text = o[1]
		cb.button_pressed = o[2]
		cb.focus_mode = Control.FOCUS_NONE
		cb.add_theme_font_size_override("font_size", 14)
		cb.toggled.connect(func(on: bool):
			set(key, on)
			_update_mask()
			refresh())
		row.add_child(cb)
	_numbers = PanelKit.wrapped(box, "", 15, Color.WHITE, 2, WIDTH)
	box.add_child(StudyHud.label("ROI の色相（彩度・明度を通った画素）と各色の範囲", 14, PanelKit.CYAN, 2))
	_hist = Control.new()
	_hist.custom_minimum_size = Vector2(WIDTH, 70)
	_hist.draw.connect(_draw_hist)
	box.add_child(_hist)
	_votes = PanelKit.wrapped(box, "", 16, PanelKit.YELLOW, 2, WIDTH)
	_game = PanelKit.wrapped(box, "", 14, PanelKit.CYAN, 2, WIDTH)

	box.add_child(StudyHud.label("試す値（初めはゲームの値）", 18, PanelKit.CYAN, 3))
	var grid := GridContainer.new()
	grid.columns = 4
	box.add_child(grid)
	for d in [["roi:0", "ROI x", 0.0, 1.0, 0.01], ["roi:1", "ROI y", 0.0, 1.0, 0.01], ["roi:2", "ROI 幅", 0.01, 1.0, 0.01],
			["roi:3", "ROI 高さ", 0.01, 1.0, 0.01], ["min_sat", "min_sat", 0.0, 1.0, 0.01], ["min_val", "min_val", 0.0, 1.0, 0.01],
			["min_share", "min_share", 0.0, 1.0, 0.005], ["dominance", "dominance", 1.0, 10.0, 0.1],
			["hue:fire:0", "赤 から", 0.0, 1.0, 0.005], ["hue:fire:1", "赤 まで", 0.0, 1.0, 0.005],
			["hue:water:0", "青 から", 0.0, 1.0, 0.005], ["hue:water:1", "青 まで", 0.0, 1.0, 0.005],
			["hue:green:0", "緑 から", 0.0, 1.0, 0.005], ["hue:green:1", "緑 まで", 0.0, 1.0, 0.005],
			["hue:thunder:0", "黄 から", 0.0, 1.0, 0.005], ["hue:thunder:1", "黄 まで", 0.0, 1.0, 0.005],
			["hue:dark:0", "紫 から", 0.0, 1.0, 0.005], ["hue:dark:1", "紫 まで", 0.0, 1.0, 0.005],
			["sample_hz", "sample_hz", 0.5, 30.0, 0.5], ["min_votes", "min_votes", 1, 50, 1],
			["min_ratio", "min_ratio", 0.0, 1.0, 0.05], ["memory_s", "memory_s", 2.0, 120.0, 1.0]]:
		var key: String = d[0]
		var s := PanelKit.spin(grid, d[1], d[2], d[3], d[4], value_of(key))
		s.custom_minimum_size = Vector2(120, 0)
		s.value_changed.connect(func(v: float): set_value(key, v))
		_spins[key] = s
	PanelKit.wrapped(box, "色相は 0〜1（赤は 1 をまたぐ: から > まで）。ROI は画像の幅・高さに対する割合。", 13, PanelKit.MUTED, 2, WIDTH)
	row = PanelKit.row(box)
	row.add_child(PanelKit.button("ゲームの値に戻す", 16, reset_settings))
	row.add_child(PanelKit.button("試した値をコピー", 16, func(): copy_settings()))
	row.add_child(PanelKit.button("試した値を保存", 16, func(): save_settings()))

	box.add_child(StudyHud.label("記録（JSONL）と集計", 18, PanelKit.CYAN, 3))
	row = PanelKit.row(box)
	var opt := OptionButton.new()
	opt.focus_mode = Control.FOCUS_NONE
	opt.add_theme_font_size_override("font_size", 15)
	for l in LABELS:
		opt.add_item(l[1])
	opt.item_selected.connect(func(i: int): set_label(LABELS[i][0]))
	row.add_child(opt)
	_record_cb = CheckBox.new()
	_record_cb.text = "判定したフレームを記録する"
	_record_cb.focus_mode = Control.FOCUS_NONE
	_record_cb.add_theme_font_size_override("font_size", 15)
	_record_cb.toggled.connect(set_recording)
	row.add_child(_record_cb)
	row.add_child(PanelKit.button("集計を消す", 15, func():
		tally.clear()
		refresh()))
	_record_info = PanelKit.wrapped(box, "", 13, PanelKit.MUTED, 2, WIDTH)
	_tally_label = PanelKit.wrapped(box, "", 14, Color.WHITE, 2, WIDTH)

func _sync_spins() -> void:
	for key in _spins:
		(_spins[key] as SpinBox).set_value_no_signal(value_of(key))

## The mask: one cell per looked-at pixel, coloured by what it was.
func _update_mask() -> void:
	if _mask == null or not result.has("samples"):
		return
	var cols := int(result.cols)
	var rows := int(result.rows)
	if cols <= 0 or rows <= 0:
		return
	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	var samples: PackedByteArray = result.samples
	var kind_of := {}
	for k in CapsuleKinds.SAMPLE_KIND:
		kind_of[CapsuleKinds.SAMPLE_KIND[k]] = CapsuleKinds.COLORS[k]
	for i in mini(samples.size(), cols * rows):
		var v := samples[i]
		var col := Color.TRANSPARENT
		if kind_of.has(v):
			col = kind_of[v]
			col.a = 0.85
		elif show_left_out:
			col = MASK_COLORS.get(v, Color.TRANSPARENT)
		img.set_pixel(i % cols, i / cols, col)
	if _mask_tex == null or Vector2i(_mask_tex.get_size()) != Vector2i(cols, rows):
		_mask_tex = ImageTexture.create_from_image(img)
	else:
		_mask_tex.update(img)
	_mask.texture = _mask_tex

## Where the frame shows in the view.
func _shown() -> Rect2:
	if frame == null:
		return Rect2()
	return SheetCheckPanel.frame_rect(Vector2(frame.get_size()), _view_holder.size)

func _to_view(r: Rect2, shown: Rect2) -> Rect2:
	var k := shown.size / Vector2(frame.get_size())
	return Rect2(shown.position + r.position * k, r.size * k)

func _layout_mask() -> void:
	var shown := _shown()
	if not shown.has_area() or not result.has("cols"):
		return
	var roi: Rect2i = result.roi
	var step := int(result.step)
	var r := _to_view(Rect2(roi.position, Vector2(int(result.cols) * step, int(result.rows) * step)), shown)
	_mask.position = r.position
	_mask.size = r.size

func _draw_overlay() -> void:
	var shown := _shown()
	if not shown.has_area():
		var font := ThemeDB.fallback_font
		_overlay.draw_string(font, Vector2(20, VIEW_H / 2.0), FRAME_STATUS.get(str(frame_info.get("status", "none")), ""),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 22, PanelKit.BAD)
		return
	if result.has("roi"):
		var roi: Rect2i = result.roi
		_overlay.draw_rect(_to_view(Rect2(roi), shown), PanelKit.YELLOW, false, 2.0)
	if frame_info.get("status") == "stale":
		_overlay.draw_rect(Rect2(shown.position, Vector2(shown.size.x, 28)), Color(0.5, 0, 0, 0.8))
		_overlay.draw_string(ThemeDB.fallback_font, shown.position + Vector2(8, 21), "未更新のフレーム（判定に使っていない）",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color.WHITE)

## The hues of the saturated, bright pixels (bars over the hue strip) and each colour's range.
func _draw_hist() -> void:
	var w := _hist.size.x
	var h := _hist.size.y
	var n := CapsuleKinds.HUE_BINS
	var bw := w / n
	for i in n:
		_hist.draw_rect(Rect2(i * bw, h - 8, bw, 8), Color.from_hsv((i + 0.5) / n, 0.9, 0.9))
	var hist = result.get("hue_hist")
	if hist is PackedInt32Array and hist.size() == n:
		var top := 1
		for c in hist:
			top = maxi(top, c)
		for i in n:
			var bh := (h - 30) * float(hist[i]) / top
			_hist.draw_rect(Rect2(i * bw + 1, h - 10 - bh, bw - 2, bh), Color.from_hsv((i + 0.5) / n, 0.7, 1.0))
	var hues: Dictionary = cfg.get("hues", {})
	var y := 2.0
	for k in CapsuleKinds.COLOURED:
		if not hues.has(k):
			continue
		var lo := float(hues[k][0])
		var hi := float(hues[k][1])
		var col: Color = CapsuleKinds.COLORS[k]
		var spans := [[lo, hi]] if lo <= hi else [[lo, 1.0], [0.0, hi]]
		for sp in spans:
			_hist.draw_rect(Rect2(float(sp[0]) * w, y, (float(sp[1]) - float(sp[0])) * w, 5), col)
		y += 7.0

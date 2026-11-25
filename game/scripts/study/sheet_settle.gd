class_name SheetSettle
extends RefCounted
## #298: when a camera frame may go to the worksheet reader (the reader's hand-off, §3.1: "send
## once the picture has settled: no hand in it, not what was sent before; not the first frames of a
## camera just opened"). A small grey copy of the frame is taken a few times a second (`sample`);
## `blocker` says why not now ("" = it may go):
##   warming  - the camera has given frames for less than warmup_s (dark, the exposure settling)
##   dark     - the picture is (nearly) black
##   moving   - it changed more than move_diff between samples within the last still_s (a hand
##              moving over the sheet, the sheet being put down)
## `same_as_sent` says the picture is what was sent last (the watch then sends nothing again).
## A hand held still over the sheet is not seen: that needs more than the picture's change.
## Presentation side only: nothing here moves the arm or talks to the backend.

const SIG_W := 32
const SIG_H := 24

var warmup_s := 2.0
var still_s := 1.0
var move_diff := 0.03  # mean change of a 32x24 grey copy (0..1) that counts as moving
var same_diff := 0.012  # below this the picture is the one sent
var dark_level := 0.06  # mean brightness (0..1) under which the picture is black
var sample_hz := 4.0

var _sig := PackedFloat32Array()
var _sent := PackedFloat32Array()
var _still_since := -1.0
var _brightness := 0.0
var last_diff := 0.0
var _sample_left := 0.0

func configure(d: Dictionary) -> void:
	warmup_s = float(d.get("warmup_s", warmup_s))
	still_s = float(d.get("still_s", still_s))
	move_diff = float(d.get("move_diff", move_diff))
	same_diff = float(d.get("same_diff", same_diff))
	dark_level = float(d.get("dark_level", dark_level))
	sample_hz = maxf(float(d.get("sample_hz", sample_hz)), 0.5)

## The grey 32x24 copy of an image (0..1 per cell).
static func signature(img: Image) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if img == null or img.is_empty():
		return out
	var small := img.duplicate()
	small.convert(Image.FORMAT_RGB8)
	small.resize(SIG_W, SIG_H, Image.INTERPOLATE_BILINEAR)
	out.resize(SIG_W * SIG_H)
	for y in SIG_H:
		for x in SIG_W:
			out[y * SIG_W + x] = small.get_pixel(x, y).get_luminance()
	return out

## The mean difference of two signatures (1.0 when they cannot be compared).
static func diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.is_empty() or a.size() != b.size():
		return 1.0
	var sum := 0.0
	for i in a.size():
		sum += absf(a[i] - b[i])
	return sum / a.size()

## Time passes; true when a new sample is due (the caller then gives one with `sample`).
func due(dt: float) -> bool:
	_sample_left -= dt
	if _sample_left > 0.0:
		return false
	_sample_left = 1.0 / sample_hz
	return true

## One look at the picture at `now_s` (seconds, any clock that only goes forward).
func sample(img: Image, now_s: float) -> void:
	var sig := signature(img)
	if sig.is_empty():
		reset()
		return
	last_diff = diff(sig, _sig)
	if _sig.is_empty() or last_diff > move_diff:
		_still_since = now_s
	_sig = sig
	var sum := 0.0
	for v in sig:
		sum += v
	_brightness = sum / sig.size()

## Forget the samples (no picture, another camera).
func reset() -> void:
	_sig = PackedFloat32Array()
	_still_since = -1.0
	last_diff = 0.0

## Why a frame may not go now ("" = it may). `live_s`: how long the camera has given frames.
func blocker(now_s: float, live_s: float) -> String:
	if live_s < warmup_s:
		return "warming"
	if _sig.is_empty():
		return "warming"
	if _brightness < dark_level:
		return "dark"
	if _still_since < 0.0 or now_s - _still_since < still_s:
		return "moving"
	return ""

## The picture now is the one sent last (nothing new on the sheet).
func same_as_sent() -> bool:
	return not _sent.is_empty() and diff(_sig, _sent) < same_diff

## The picture now went to the reader.
func mark_sent() -> void:
	_sent = _sig.duplicate()

## The last sending did not count (the reader failed): the same picture may go again.
func forget_sent() -> void:
	_sent = PackedFloat32Array()

## The blocker in words, for the adult (the status line).
static func text(why: String) -> String:
	match why:
		"warming":
			return "カメラの映像が落ち着くのを待っています"
		"dark":
			return "カメラの映像が真っ暗です"
		"moving":
			return "手やプリントが動いています（止まってから読みます）"
	return ""

class_name OpticalFlow
extends RefCounted
## Optical flow between two small grey images, for the arm camera's scope (#141): how
## the picture moved, on a grid of cells, by block matching. For every cell a block of the
## earlier image is looked for around the same place in the later one (the offset with the
## smallest sum of absolute differences); a cell with no texture, or whose best match is
## not clearly better than the others, reports nothing.
##
## Pure (bytes in, vectors out), so the tests drive it with made-up images. It is small on
## purpose: 5 x 5 cells on a 48 x 48 image costs about a millisecond in GDScript.
##
## Presentation only: the vectors are drawn over the camera view. They are never used to
## move the robot, to judge anything, or sent anywhere.

var cols := 5
var rows := 5
## the block's side (px) and how far it is looked for (px, each way)
var block := 8
var search := 3
## every `step`-th pixel of the block is compared
var step := 2
## a block whose brightest and darkest sample differ by less than this has no texture
var min_contrast := 24
## the best match must beat staying still by this much per sample, or the cell is still
var still_bias := 2.0

## The flow from `prev` to `cur` (both w x h bytes, one grey byte per pixel, row by row).
## One entry per cell, row by row: {at: Vector2 (the cell's centre, 0..1 of the image),
## v: Vector2 (how far the picture moved there, px), ok: bool (false = no texture)}.
func estimate(prev: PackedByteArray, cur: PackedByteArray, w: int, h: int) -> Array:
	var out: Array = []
	if w <= 0 or h <= 0 or prev.size() != w * h or cur.size() != w * h:
		return out
	var margin := search + block / 2
	for r in rows:
		for c in cols:
			var cx := int(lerpf(margin, w - margin, (c + 0.5) / cols))
			var cy := int(lerpf(margin, h - margin, (r + 0.5) / rows))
			var cell := {"at": Vector2(float(cx) / w, float(cy) / h), "v": Vector2.ZERO, "ok": false}
			out.append(cell)
			var x0 := cx - block / 2
			var y0 := cy - block / 2
			# the block's samples (and whether there is anything to match)
			var lo := 255
			var hi := 0
			var samples := PackedInt32Array()
			var offsets := PackedInt32Array()
			for by in range(0, block, step):
				for bx in range(0, block, step):
					var i := (y0 + by) * w + x0 + bx
					var p := prev[i]
					samples.append(p)
					offsets.append(i)
					lo = mini(lo, p)
					hi = maxi(hi, p)
			if hi - lo < min_contrast:
				continue
			var n := samples.size()
			cell.ok = true
			# staying still wins unless moving is clearly better (noise does not make arrows):
			# an offset has to beat the still picture's difference by still_bias per sample
			var still := 0
			for k in n:
				still += absi(samples[k] - cur[offsets[k]])
			var best := still - int(still_bias * n)
			var best_d := Vector2i.ZERO
			for dy in range(-search, search + 1):
				for dx in range(-search, search + 1):
					if dx == 0 and dy == 0:
						continue
					var shift := dy * w + dx
					var sad := 0
					for k in n:
						sad += absi(samples[k] - cur[offsets[k] + shift])
						if sad >= best:
							break
					if sad < best:
						best = sad
						best_d = Vector2i(dx, dy)
			cell.v = Vector2(best_d)
	return out

## The mean of the cells that reported (zero when none did).
static func mean(cells: Array) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for c in cells:
		if c.ok:
			sum += c.v
			n += 1
	return sum / n if n > 0 else Vector2.ZERO

## How many cells had texture.
static func tracked(cells: Array) -> int:
	var n := 0
	for c in cells:
		if c.ok:
			n += 1
	return n

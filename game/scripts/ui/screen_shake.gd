class_name ScreenShake
extends Node
## Trauma-based screen shake. Kicks add trauma (0..1), which decays over time;
## the offset is max_offset_px * trauma^2 * smooth noise, so small kicks stay
## subtle and big ones read clearly.
##
## It moves the viewport's canvas transform only, after the projection: the rope
## simulation, the anchor and the UFO's world position are never touched, and
## CanvasLayers (the debug panel) do not shake.

var enabled := true
var max_offset_px := 12.0
## Trauma lost per second.
var decay := 1.2

var trauma := 0.0
var offset := Vector2.ZERO
var _t := 0.0
var _noise := FastNoiseLite.new()

func _ready() -> void:
	_noise.seed = randi()
	_noise.frequency = 0.9

func add_trauma(amount: float) -> void:
	if enabled:
		trauma = clampf(trauma + amount, 0.0, 1.0)

func _process(dt: float) -> void:
	step(dt)
	if is_inside_tree():
		get_viewport().canvas_transform = Transform2D(0.0, offset)

## Advance the shake by dt (separate from _process so it can be tested).
func step(dt: float) -> void:
	_t += dt
	trauma = maxf(trauma - decay * dt, 0.0)
	if not enabled:
		trauma = 0.0
	var amp := max_offset_px * trauma * trauma
	# simplex noise mostly stays within +-0.4: stretch it to use the full range
	var n := Vector2(_noise.get_noise_2d(_t * 60.0, 0.0), _noise.get_noise_2d(0.0, _t * 60.0 + 100.0)) * 2.2
	offset = n.limit_length(1.0) * amp

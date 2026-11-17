class_name PowerUpManager
extends RefCounted
## Time-limited powers in the 150-second score game (#188).
## This never controls the robot or any device. The controller interprets the effects.
const KINDS := ["speed", "multiball", "double"]
const LABELS := {"speed": "SPEED UP!", "multiball": "MULTI BALL!", "double": "DOUBLE SCORE!"}

var duration := {"speed": 10.0, "double": 15.0}
var left := {"speed": 0.0, "double": 0.0}

func configure(cfg: Dictionary) -> void:
	var values: Dictionary = cfg.get("duration_s", {}) if cfg.get("duration_s") is Dictionary else {}
	for key in duration.keys():
		duration[key] = clampf(float(values.get(key, duration[key])), 0.1, 60.0)

func reset() -> void:
	for key in left.keys():
		left[key] = 0.0

## Repeated collection refreshes, never stacks a multiplier or time indefinitely.
func collect(kind: String) -> bool:
	if not kind in KINDS:
		return false
	if duration.has(kind):
		left[kind] = float(duration[kind])
	return true

func active(kind: String) -> bool:
	return float(left.get(kind, 0.0)) > 0.0

func seconds(kind: String) -> int:
	return int(ceil(float(left.get(kind, 0.0))))

## Returns effects that ended on this tick, so the controller can restore the lights.
func advance(dt: float) -> Array[String]:
	var ended: Array[String] = []
	for kind in left.keys():
		var prior := float(left[kind])
		left[kind] = maxf(prior - maxf(dt, 0.0), 0.0)
		if prior > 0.0 and float(left[kind]) <= 0.0:
			ended.append(kind)
	return ended

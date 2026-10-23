class_name Projection25D
extends RefCounted
## Fixed-camera projection from the rope's 3D world frame to 2D screen pixels.
##
## The camera sits in front of the scene, looking slightly downward by
## `pitch_deg`. World +Z points towards the camera. Rotation about the X axis
## by the pitch gives view coordinates; a simple pin-hole divide adds the
## depth cue (objects further away look higher on screen and smaller).
##
## Every rope point and the UFO MUST go through `project()` so they never
## disagree about where the attachment point is.

## Camera downward tilt (degrees). 0 = looking straight ahead; ~25 = top-down-ish.
var pitch_deg: float = 28.0
## Pixels per world unit (cm) at depth 0.
var pixels_per_unit: float = 6.0
## Horizontal/depth display multiplier applied to XZ (crane travel) only.
var xy_display_scale: float = 1.0
## Perspective strength. 0 = orthographic. Scale = 1 / (1 - d * perspective).
var perspective: float = 0.0045
## Extra multiplier for how strongly front/back moves show as vertical offset.
var depth_scale: float = 1.0
## Screen position of world origin (the rest anchor), set by the main scene.
var origin_px: Vector2 = Vector2(640.0, 40.0)

class Result:
	var screen: Vector2
	var scale: float
	var depth: float # bigger = closer to camera (for draw ordering)

func project(world: Vector3) -> Result:
	var r := Result.new()
	var pitch := deg_to_rad(pitch_deg)
	var c := cos(pitch)
	var s := sin(pitch)
	var x := world.x * xy_display_scale
	var z := world.z * xy_display_scale * depth_scale
	# Rotate about X by -pitch (camera looking down): view-up and view-depth.
	var vy := world.y * c - z * s
	var vd := z * c + world.y * s
	var denom := 1.0 - vd * perspective
	denom = maxf(denom, 0.2)
	r.scale = 1.0 / denom
	r.depth = vd
	r.screen = origin_px + Vector2(x, -vy) * pixels_per_unit * r.scale
	return r

func project_point(world: Vector3) -> Vector2:
	return project(world).screen

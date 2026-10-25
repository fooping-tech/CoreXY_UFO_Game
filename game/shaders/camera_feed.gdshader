shader_type canvas_item;
// Converts a live USB camera feed (CameraServer) to RGB. Runs once per camera,
// on a rect filling that camera's SubViewport (CameraHub); every view then shows
// the viewport's plain RGB texture (camera_view.gdshader / TextureRect).
//  mode 0: no camera -> dim animated static
//  mode 1: RGB feed (rgb_tex)
//  mode 2: YCbCr in two planes (y_tex + cbcr_tex), what macOS delivers
//  mode 3: YCbCr packed in one texture (rgb_tex.rgb = Y, Cb, Cr)

uniform sampler2D y_tex : filter_linear;
uniform sampler2D cbcr_tex : filter_linear;
uniform sampler2D rgb_tex : filter_linear;
uniform int mode = 0;
uniform bool flip_h = false;
uniform bool flip_v = false;

vec3 ycbcr_to_rgb(float y, vec2 cbcr) {
	// BT.601 full range (the Godot camera feeds)
	vec2 c = cbcr - vec2(0.5);
	return vec3(y + 1.402 * c.y, y - 0.344136 * c.x - 0.714136 * c.y, y + 1.772 * c.x);
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 uv = UV;
	if (flip_h) { uv.x = 1.0 - uv.x; }
	if (flip_v) { uv.y = 1.0 - uv.y; }
	vec3 col;
	if (mode == 1) {
		col = texture(rgb_tex, uv).rgb;
	} else if (mode == 2) {
		col = ycbcr_to_rgb(texture(y_tex, uv).r, texture(cbcr_tex, uv).rg);
	} else if (mode == 3) {
		vec3 p = texture(rgb_tex, uv).rgb;
		col = ycbcr_to_rgb(p.r, p.gb);
	} else {
		float n = hash(floor(UV * vec2(120.0, 90.0)) + floor(TIME * 18.0));
		col = vec3(0.04, 0.09, 0.16) + n * 0.12;
	}
	COLOR = vec4(clamp(col, 0.0, 1.0), 1.0);
}

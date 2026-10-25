shader_type canvas_item;
// Shows a camera's RGB texture (TEXTURE, from CameraHub) in a rect:
// fit 0 stretches it over the rect (give the rect the camera's aspect);
// fit 1 covers the rect, cropping the longer side (the round scope).
// circle masks a disc with a soft rim; open (0..1) is an iris for opening.

uniform int fit = 1;
uniform float feed_aspect = 1.333333;
uniform float rect_aspect = 1.0;
uniform float zoom = 1.0;
uniform bool circle = true;
uniform float open : hint_range(0.0, 1.0) = 1.0;
uniform float scanlines : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 uv = UV;
	if (fit == 1) {
		if (feed_aspect > rect_aspect) {
			uv.x = 0.5 + (uv.x - 0.5) * rect_aspect / feed_aspect;
		} else {
			uv.y = 0.5 + (uv.y - 0.5) * feed_aspect / rect_aspect;
		}
	}
	uv = vec2(0.5) + (uv - vec2(0.5)) / max(zoom, 0.01);
	vec3 col = texture(TEXTURE, uv).rgb;
	if (scanlines > 0.0) {
		col *= 1.0 - scanlines * (0.5 + 0.5 * sin(FRAGCOORD.y * 3.14159));
	}
	float a = 1.0;
	if (circle) {
		float r = length((UV - vec2(0.5)) * 2.0);
		float rim = max(open, 0.0001);
		a = 1.0 - smoothstep(rim - 0.02, rim, r);
		// a cool vignette toward the rim
		col = mix(col, col * vec3(0.55, 0.8, 1.0), smoothstep(0.55, 1.0, r / rim) * 0.6);
	}
	COLOR = vec4(col, a * COLOR.a);
}

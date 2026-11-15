shader_type canvas_item;
// #116: the study worksheet straightened from the live overview camera. UV is the page (0..1 of
// A4 across / down); H maps the page to the camera image (0..1), from the four corner marks.
uniform sampler2D cam : filter_linear;
uniform mat3 page_to_image;

void fragment() {
	vec3 p = page_to_image * vec3(UV, 1.0);
	vec2 q = p.xy / p.z;
	if (p.z <= 0.0 || q.x < 0.0 || q.y < 0.0 || q.x > 1.0 || q.y > 1.0) {
		COLOR = vec4(0.12, 0.14, 0.2, 1.0);  // outside the camera's view
	} else {
		COLOR = vec4(texture(cam, q).rgb, 1.0);
	}
}

shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D src : filter_nearest, repeat_disable;
uniform vec2 blur_channels;

void fragment() {
	ivec2 size = textureSize(src, 0);
	ivec2 p = ivec2(FRAGCOORD.xy);
	vec4 c = texelFetch(src, p, 0);
	vec4 sum = vec4(0.0);
	float count = 0.0;
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			ivec2 q = p + ivec2(dx, dy);
			if (q.x < 0 || q.y < 0 || q.x >= size.x || q.y >= size.y) {
				continue;
			}
			sum += texelFetch(src, q, 0);
			count += 1.0;
		}
	}
	vec4 blurred = sum / count;
	COLOR = vec4(
		mix(c.r, max(c.r, blurred.r), blur_channels.x),
		mix(c.g, max(c.g, blurred.g), blur_channels.y),
		c.b, c.a);
}

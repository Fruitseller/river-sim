shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform float blur_px;
uniform float corner_px;
uniform vec4 dim;

void fragment() {
	vec2 size = 1.0 / max(fwidth(UV), vec2(1e-6));
	vec2 half_size = 0.5 * size;
	float radius = min(corner_px, min(half_size.x, half_size.y));
	vec2 q = abs((UV - 0.5) * size) - (half_size - radius);
	float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
	float inside = clamp(0.5 - dist, 0.0, 1.0);

	float lod = log2(max(blur_px, 1.0)) - 1.0;
	vec2 ring = 0.5 * blur_px * SCREEN_PIXEL_SIZE;
	vec3 sum = textureLod(screen_tex, SCREEN_UV, lod).rgb;
	for (int i = 0; i < 8; i++) {
		float a = float(i) * 0.78539816;
		sum += textureLod(screen_tex, SCREEN_UV + vec2(cos(a), sin(a)) * ring, lod).rgb;
	}
	COLOR = vec4(sum / 9.0 * dim.rgb, inside);
}

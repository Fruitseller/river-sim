layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_height;
layout(set = 0, binding = 1) uniform sampler2D src_flux;
layout(set = 0, binding = 2) uniform sampler2D src_accum;
layout(set = 0, binding = 3, rg32f) uniform writeonly image2D dst_height;
layout(set = 0, binding = 4, rgba16f) uniform writeonly image2D dst_flux;
layout(set = 0, binding = 5, rgba16f) uniform writeonly image2D dst_accum;
layout(push_constant, std430) uniform Params {
	vec4 size;
	vec4 hard_freq;
	vec4 hard_weight;
} pc;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(pc.size.xy);
	if (p.x >= size.x || p.y >= size.y) {
		return;
	}
	ivec2 src_size = size / 2;
	vec2 g = (vec2(p) + 0.5) * 0.5 - 0.5;
	ivec2 i = ivec2(floor(g));
	vec2 f = g - vec2(i);
	vec4 wx = cubic_weights(f.x);
	vec4 wy = cubic_weights(f.y);
	float h = 0.0;
	for (int b = 0; b < 4; b++) {
		float row = 0.0;
		for (int a = 0; a < 4; a++) {
			ivec2 q = clamp(i + ivec2(a - 1, b - 1), ivec2(0), src_size - 1);
			row += wx[a] * texelFetch(src_height, q, 0).r;
		}
		h += wy[b] * row;
	}
	vec2 uv = (vec2(p) + 0.5) / vec2(size);
	vec4 s = textureLod(src_flux, uv, 0.0);
	vec4 a = textureLod(src_accum, uv, 0.0);
	vec2 cell = (vec2(p) + 0.5) / pc.size.z - 0.5;
	imageStore(dst_height, p, vec4(h, h, 0.0, 0.0));
	imageStore(dst_flux, p, vec4(s.r * 0.5, 0.0, s.b * 0.5, s.a));
	imageStore(dst_accum, p, vec4(a.rgb, hardness_at(cell, pc.hard_freq.xyz, pc.hard_weight.xyz)));
}

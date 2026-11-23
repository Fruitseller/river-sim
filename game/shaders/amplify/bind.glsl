layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_height;
layout(set = 0, binding = 1) uniform sampler2D sim_height;
layout(set = 0, binding = 2) uniform sampler2D sim_filled;
layout(set = 0, binding = 3) uniform sampler2D cell_mask;
layout(set = 0, binding = 4) uniform sampler2D cell_mean;
layout(set = 0, binding = 5, rg16f) uniform writeonly image2D dst_offset;
layout(set = 0, binding = 6) uniform sampler2D src_flux;
layout(push_constant, std430) uniform Params {
	vec4 size;
	vec4 bound;
	vec4 steep;
	vec4 region;
} pc;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(pc.size.xy);
	if (p.x >= size.x || p.y >= size.y) {
		return;
	}
	vec2 uv = (vec2(p) + 0.5) / vec2(size);
	float hs = textureLod(sim_height, uv, 0.0).r;
	float off = texelFetch(src_height, p, 0).r - hs * pc.size.z;
	off = shaped(off - textureLod(cell_mean, uv, 0.0).r, texelFetch(src_flux, p, 0).a,
		pc.bound, pc.steep);
	vec2 cell = (vec2(p) + 0.5) / (pc.size.x / pc.region.y) - 0.5;
	float patch_noise = vnoise(cell / pc.steep.w + 31.7) * 0.65 + vnoise(cell / pc.steep.w * 2.3 + 5.2) * 0.35;
	off *= mix(pc.region.x, 1.0, smoothstep(0.35, 0.65, patch_noise));
	float sea = pc.size.w;
	float w = textureLod(cell_mask, uv, 0.0).r * smoothstep(sea + 0.008, sea + 0.04, hs);
	off *= w;
	float depth = textureLod(sim_filled, uv, 0.0).r - hs;
	if (off > 0.0) {
		off *= 1.0 - smoothstep(pc.bound.w * 0.5, pc.bound.w, depth);
	}
	imageStore(dst_offset, p, vec4(off, w, 0.0, 0.0));
}

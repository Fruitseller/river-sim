layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D sim_protect;
layout(set = 0, binding = 1) uniform sampler2D sim_height;
layout(set = 0, binding = 2, r16f) uniform writeonly image2D dst_mask;
layout(push_constant, std430) uniform Params {
	vec4 size;
} pc;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	int n = int(pc.size.x);
	if (p.x >= n || p.y >= n) {
		return;
	}
	float near = 0.0;
	float sum = 0.0;
	float norm = 0.0;
	for (int b = -3; b <= 3; b++) {
		for (int a = -3; a <= 3; a++) {
			ivec2 q = clamp(p + ivec2(a, b), ivec2(0), ivec2(n - 1));
			float w = exp(-float(a * a + b * b) / 4.5);
			float v = texelFetch(sim_protect, q, 0).r;
			sum += w * v;
			norm += w;
			if (abs(a) <= 1 && abs(b) <= 1) {
				near = max(near, v);
			}
		}
	}
	float free = min(1.0 - near, 1.0 - smoothstep(0.0, 0.55, sum / norm));
	float sea = pc.size.y;
	float coast = smoothstep(sea + 0.008, sea + 0.04, texelFetch(sim_height, p, 0).r);
	imageStore(dst_mask, p, vec4(free * coast));
}

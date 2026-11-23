layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_mean;
layout(set = 0, binding = 1, r32f) uniform writeonly image2D dst_correction;
layout(push_constant, std430) uniform Params {
	vec4 size;
} pc;

const float R = -0.17157288;
const float C = 1.41421356;
const int REACH = 8;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	int n = int(pc.size.x);
	if (p.x >= n || p.y >= n) {
		return;
	}
	float sigma = pc.size.y;
	float sum = 0.0;
	if (sigma > 0.0) {
		int reach = min(REACH, int(ceil(2.5 * sigma)));
		float norm = 0.0;
		for (int b = -reach; b <= reach; b++) {
			for (int a = -reach; a <= reach; a++) {
				ivec2 q = clamp(p + ivec2(a, b), ivec2(0), ivec2(n - 1));
				float w = exp(-float(a * a + b * b) / (2.0 * sigma * sigma));
				sum += w * texelFetch(src_mean, q, 0).r;
				norm += w;
			}
		}
		sum /= norm;
	} else {
		float w[5] = float[5](C, C * R, C * R * R, C * R * R * R, C * R * R * R * R);
		for (int b = -4; b <= 4; b++) {
			for (int a = -4; a <= 4; a++) {
				ivec2 q = clamp(p + ivec2(a, b), ivec2(0), ivec2(n - 1));
				sum += w[abs(a)] * w[abs(b)] * texelFetch(src_mean, q, 0).r;
			}
		}
	}
	imageStore(dst_correction, p, vec4(sum));
}

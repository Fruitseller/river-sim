// Zellmittel der rohen Abweichung (fein − bilineare Sim-Höhe) je Sim-Zelle.
// mean_solve.glsl macht daraus das Korrekturfeld, bind.glsl zieht es ab: die
// Verfeinerung erhält das Mittel.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_height;
layout(set = 0, binding = 1) uniform sampler2D sim_height;  // linear
layout(set = 0, binding = 2, r32f) uniform writeonly image2D dst_mean;
layout(push_constant, std430) uniform Params {
	vec4 size;   // x Sim-Gitter n, y Texel je Zelle, z Überhöhung
} pc;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	int n = int(pc.size.x);
	if (p.x >= n || p.y >= n) {
		return;
	}
	int k = int(pc.size.y);
	float fine_n = float(n * k);
	float sum = 0.0;
	for (int b = 0; b < k; b++) {
		for (int a = 0; a < k; a++) {
			ivec2 q = p * k + ivec2(a, b);
			vec2 uv = (vec2(q) + 0.5) / fine_n;
			sum += texelFetch(src_height, q, 0).r - textureLod(sim_height, uv, 0.0).r * pc.size.z;
		}
	}
	imageStore(dst_mean, p, vec4(sum / float(k * k)));
}

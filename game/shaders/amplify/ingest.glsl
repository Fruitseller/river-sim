// Stufe 1 aus der Sim-Höhe: bikubisch auf doppelte Auflösung. Jede Sim-Zelle
// wird 2×2 Texel; Texel I liegt bei Sim-Koordinate (I + 0,5)/2 − 0,5.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D sim_height;
layout(set = 0, binding = 1, rg32f) uniform writeonly image2D dst_height;
layout(set = 0, binding = 2, rgba16f) uniform writeonly image2D dst_flux;
layout(set = 0, binding = 3, rgba16f) uniform writeonly image2D dst_accum;
layout(push_constant, std430) uniform Params {
	vec4 size;    // xy Zielgröße, z Sim-Gitter n, w Überhöhung
	vec4 flow;    // x Eigenfläche je Texel, y Sim-Zellweite in Welteinheiten
	vec4 hard_freq;    // Härte-Rauschen: Frequenz je Oktave (1/Zellen)
	vec4 hard_weight;  // und Gewicht je Oktave (Summe 1)
} pc;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= int(pc.size.x) || p.y >= int(pc.size.y)) {
		return;
	}
	int n = int(pc.size.z);
	vec2 g = (vec2(p) + 0.5) * 0.5 - 0.5;
	ivec2 i = ivec2(floor(g));
	vec2 f = g - vec2(i);
	vec4 wx = cubic_weights(f.x);
	vec4 wy = cubic_weights(f.y);
	vec4 dwx = cubic_slopes(f.x);
	vec4 dwy = cubic_slopes(f.y);
	float h = 0.0;
	vec2 grad = vec2(0.0);
	for (int b = 0; b < 4; b++) {
		float row = 0.0;
		float row_dx = 0.0;
		for (int a = 0; a < 4; a++) {
			ivec2 q = clamp(i + ivec2(a - 1, b - 1), ivec2(0), ivec2(n - 1));
			float v = texelFetch(sim_height, q, 0).r;
			row += wx[a] * v;
			row_dx += dwx[a] * v;
		}
		h += wy[b] * row;
		grad += vec2(wy[b] * row_dx, dwy[b] * row);
	}
	h *= pc.size.w;
	// Gefälle der Sim-Fläche selbst: der thermische Abtrag lässt stehen, was
	// die Sim so steil gebaut hat (step.glsl).
	float sim_slope = length(grad) * pc.size.w / pc.flow.y;
	imageStore(dst_height, p, vec4(h, h, 0.0, 0.0));
	imageStore(dst_flux, p, vec4(pc.flow.x, 0.0, 0.0, sim_slope));
	imageStore(dst_accum, p, vec4(0.0, 0.0, 0.0, hardness_at(g, pc.hard_freq.xyz, pc.hard_weight.xyz)));
}

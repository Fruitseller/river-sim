const float STREAM_MAX = 60000.0;

const ivec2 NB[8] = ivec2[8](
	ivec2(0, 1), ivec2(1, 1), ivec2(1, 0), ivec2(1, -1),
	ivec2(0, -1), ivec2(-1, -1), ivec2(-1, 0), ivec2(-1, 1));
const float NB_DIST[8] = float[8](1.0, 1.41421356, 1.0, 1.41421356,
	1.0, 1.41421356, 1.0, 1.41421356);

uint pcg(uint v) {
	uint s = v * 747796405u + 2891336453u;
	uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return (w >> 22u) ^ w;
}
float hash21(ivec2 p) {
	return float(pcg(uint(p.x) + pcg(uint(p.y)))) * (1.0 / 4294967295.0);
}
float vnoise(vec2 p) {
	ivec2 i = ivec2(floor(p));
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + ivec2(1, 0)), u.x),
	           mix(hash21(i + ivec2(0, 1)), hash21(i + ivec2(1, 1)), u.x), u.y);
}
float hardness_at(vec2 cell, vec3 freq, vec3 weight) {
	return vnoise(cell * freq.x + 17.3) * weight.x + vnoise(cell * freq.y + 4.1) * weight.y
	     + vnoise(cell * freq.z + 91.7) * weight.z;
}

vec4 cubic_weights(float t) {
	float t2 = t * t;
	float t3 = t2 * t;
	return vec4(-0.5 * t3 + t2 - 0.5 * t,
	             1.5 * t3 - 2.5 * t2 + 1.0,
	            -1.5 * t3 + 2.0 * t2 + 0.5 * t,
	             0.5 * t3 - 0.5 * t2);
}

float soft_bound(float off, float down, float up) {
	return off < 0.0 ? -down * tanh(-off / down) : up * tanh(off / up);
}

vec4 cubic_slopes(float t) {
	float t2 = t * t;
	return vec4(-1.5 * t2 + 2.0 * t - 0.5,
	             4.5 * t2 - 5.0 * t,
	            -4.5 * t2 + 4.0 * t + 0.5,
	             1.5 * t2 - t);
}

float shaped(float raw, float sim_slope, vec4 bound, vec4 steep) {
	float gain = mix(bound.z, steep.x, smoothstep(steep.y, max(steep.z, steep.y + 1e-6), sim_slope));
	return soft_bound(raw * gain, bound.x, bound.y);
}

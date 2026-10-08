// Phacelle-Noise + Erosionsfilter als gemeinsames Include: der Terrain-Shader
// nutzt es für das feine Detail, die Flusstal-Studie (#116) zusätzlich in
// einem Back-Pass für die grobe Verschiebung. Keine Uniforms, nur Funktionen.
// ---------------------------------------------------------------------------
// Phacelle-Noise + Erosionsfilter — portiert aus „Advanced Terrain Erosion
// Filter", Copyright (c) 2025 Rune Skovbo Johansen, Mozilla Public License 2.0
// (https://mozilla.org/MPL/2.0/). Referenz: docs/references/runevision-erosion/.
// ---------------------------------------------------------------------------

vec2 ehash(vec2 x) {
	const vec2 k = vec2(0.3183099, 0.3678794);
	x = x * k + k.yx;
	return -1.0 + 2.0 * fract(16.0 * k * fract(x.x * x.y * (x.x + x.y)));
}

float ease_out(float t) {
	float v = 1.0 - clamp(t, 0.0, 1.0);
	return 1.0 - v * v;
}

float smooth_start(float t, float smoothing) {
	if (t >= smoothing) { return t - 0.5 * smoothing; }
	return smoothing <= 0.0 ? t : 0.5 * t * t / smoothing;
}

float pow_inv(float t, float power) {
	return 1.0 - pow(1.0 - clamp(t, 0.0, 1.0), power);
}

// normalize() auf dem Null-Vektor ist undefiniert (GPU: NaN) — auf EXAKT flachem
// Terrain (Einebnen-Werkzeug, Floor-Clamp) wurde daraus eine schwarze Fläche.
// Degenerierte Richtungen bekommen einen festen Ersatz; die Detail-Masken blenden
// bei Steigung ≈ 0 ohnehin auf null, der Ersatzwert ist also unsichtbar.
vec2 safe_dir(vec2 v) {
	return dot(v, v) > 1e-14 ? v * inversesqrt(dot(v, v)) : vec2(0.7071, 0.7071);
}

// Streifenmuster entlang normDir: cos/sin-Paare aus 4×4 zufällig versetzten
// Zellen interpoliert + normalisiert. Rückgabe: (cos, sin, sideDir).
vec4 phacelle_noise(vec2 p, vec2 norm_dir, float freq, float offset, float normalization) {
	vec2 side_dir = norm_dir.yx * vec2(-1.0, 1.0) * freq * 6.2831853;
	offset *= 6.2831853;
	vec2 p_int = floor(p);
	vec2 p_frac = fract(p);
	vec2 phase_dir = vec2(0.0);
	float weight_sum = 1e-9;
	for (int i = -1; i <= 2; i++) {
		for (int j = -1; j <= 2; j++) {
			vec2 grid_offset = vec2(float(i), float(j));
			vec2 v = p_frac - grid_offset - ehash(p_int + grid_offset) * 0.5;
			float w = max(0.0, exp(-dot(v, v) * 2.0) - 0.01111);
			weight_sum += w;
			float wave = dot(v, side_dir) + offset;
			phase_dir += vec2(cos(wave), sin(wave)) * w;
		}
	}
	vec2 interp = phase_dir / weight_sum;
	float mag = max(1.0 - normalization, length(interp));
	return vec4(interp / mag, side_dir);
}

// Erosions-Detail: 3 Oktaven „stacked faded gullies" auf dem Sim-Höhenfeld.
// slope = dh/duv des groben Felds. Rückgabe: (dh, dsx, dsy, ridgeMap); die
// Magnitude landet in out_mag (zum Normieren der Schattierung).
vec4 erosion_detail_at(vec2 p, vec2 slope, float fade_target_in, float scale,
                       float strength_rel, out float out_mag) {
	const float GULLY_WEIGHT = 0.5;
	const float DETAIL = 1.5;
	const vec4 ROUNDING = vec4(0.1, 0.0, 0.15, 2.0);
	const vec4 ONSET = vec4(1.25, 1.25, 2.8, 1.5);
	const vec2 ASSUMED_SLOPE = vec2(0.7, 1.0);
	const float CELL_SCALE = 0.7;
	const float NORMALIZATION = 0.5;
	const int OCTAVES = 3;

	float strength = strength_rel * scale;
	float fade_target = clamp(fade_target_in, -1.0, 1.0);
	vec3 hs = vec3(0.0); // Delta-Akkumulator (Höhe, Steigung)
	float freq = 1.0 / (scale * CELL_SCALE);
	float slope_len = max(length(slope), 1e-10);
	float magnitude = 1e-9;
	float rounding_mult = 1.0;

	float rounding_input = mix(ROUNDING.y, ROUNDING.x, clamp(fade_target + 0.5, 0.0, 1.0)) * ROUNDING.z;
	float combi_mask = ease_out(smooth_start(slope_len * ONSET.x, rounding_input * ONSET.x));
	float ridge_mask = ease_out(slope_len * ONSET.z);
	float ridge_fade = fade_target;
	vec2 gully_slope = mix(slope, slope / slope_len * ASSUMED_SLOPE.x, ASSUMED_SLOPE.y);

	for (int i = 0; i < OCTAVES; i++) {
		vec4 ph = phacelle_noise(p * freq, safe_dir(gully_slope), CELL_SCALE, 0.25, NORMALIZATION);
		ph.zw *= -freq;
		float sloping = abs(ph.y);
		gully_slope += sign(ph.y) * ph.zw * strength * GULLY_WEIGHT;

		vec3 gullies = vec3(ph.x, ph.y * ph.zw);
		vec3 faded = mix(vec3(fade_target, 0.0, 0.0), gullies * GULLY_WEIGHT, combi_mask);
		hs += faded * strength;
		magnitude += strength;
		fade_target = faded.x;

		float rounding_oct = mix(ROUNDING.y, ROUNDING.x, clamp(ph.x + 0.5, 0.0, 1.0)) * rounding_mult;
		float new_mask = ease_out(smooth_start(sloping * ONSET.y, rounding_oct * ONSET.y));
		combi_mask = pow_inv(combi_mask, DETAIL) * new_mask;

		ridge_fade = mix(ridge_fade, gullies.x, ridge_mask);
		ridge_mask *= ease_out(sloping * ONSET.w);

		strength *= 0.5;
		freq *= 2.0;
		rounding_mult *= ROUNDING.w;
	}
	out_mag = magnitude;
	return vec4(hs, ridge_fade * (1.0 - ridge_mask));
}


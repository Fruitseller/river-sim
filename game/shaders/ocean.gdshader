// Offenes Meer mit derselben Wasseroptik wie Raster-Seen und Flussbänder.
// Eigene Weltkoordinaten-Wellen statt eines metallischen StandardMaterials.
shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;

uniform float u_time = 0.0;
uniform float world_size = 100.0;
uniform float sea_level = 0.15;
uniform sampler2D height_tex : filter_linear, repeat_disable;

// Wasser-Kalibrierung über die Brücke (Issues #91/#92): Main.gd setzt die
// Werte beim Aufbau aus SimRender.WaterUniforms. BEWUSST ohne Default — ein
// Literal-Default wäre wieder eine Kopie der Kalibrierung (die #92 abschafft);
// die Editor-Vorschau ohne SimNode ist damit unkalibriert (alles Null), aber
// TOTAL: calib_window sowie max() an Tiefen-Divisor und Fresnel-Exponent
// sichern gegen die Null-Uniforms ab (smoothstep mit edge0 >= edge1 und
// pow(0.0, 0.0) sind laut GLSL-Spec undefiniert; Review zu #105).
// Wächter: SimCoreTests/WaterUniformsTests.swift (default-frei, gelesen),
// game/tests/water_uniforms.gd (End-to-End: jede Uniform wird gesetzt).
uniform float water_fresnel_exponent;
uniform float water_fresnel_sky_mix;
uniform float water_roughness_steep;
uniform float water_roughness_grazing;
uniform float water_specular_steep;
uniform float water_specular_grazing;
uniform vec3 water_sky_reflect_color;

// Offenes Meer (#155, übernommen aus dem Studien-Hebel `frame`): Farbe aus
// der Wassertiefe über dem Sim-Schelf, Brandungssaum, Rausch-Wellen.
// Begründung der Werte: SimCore WaterRender.ocean*.
uniform float water_ocean_depth_span;
uniform float water_ocean_mid_depth;
uniform float water_ocean_surf_depth;
uniform float water_ocean_surf_strength;
uniform float water_ocean_surf_scale;
uniform float water_ocean_surf_drift;
uniform float water_ocean_surf_noise_lo;
uniform float water_ocean_surf_noise_hi;
uniform float water_ocean_wave_frequency;
uniform float water_ocean_wave_amplitude;
uniform float water_ocean_wave_lacunarity;
uniform float water_ocean_wave_gain;
uniform float water_ocean_wave_fade_lo;
uniform float water_ocean_wave_fade_hi;
uniform float water_ocean_wave_drift_x;
uniform float water_ocean_wave_drift_z;
uniform float water_ocean_wave_octave_speedup;
uniform vec3 water_ocean_shallow_color;
uniform vec3 water_ocean_mid_color;
uniform vec3 water_ocean_deep_color;
uniform vec3 water_ocean_surf_color;

varying vec2 v_world;

// Wolkenschatten (#151): gemeinsame Funktion mit Terrain und Bändern.
#include "res://shaders/clouds.gdshaderinc"

float calib_window(float lo, float hi, float x) {
	return smoothstep(lo, max(hi, lo + 1e-6), x);
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
	           mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0)), u.x), u.y);
}

// Normalen-Gradient aus Rausch-Oktaven. Jede Oktave blendet aus, sobald
// ihre Rausch-Zellen unter die Pixelgröße fallen: die Ferne bleibt ruhig statt
// in Moiré und Streifen zu zerfallen. Die Oktaven-Versätze entkoppeln nur die
// Muster, der Differenzen-Schritt ist numerisch — beides keine Kalibrierung.
// `footprint` kommt vom Aufrufer, VOR dem discard bestimmt: Ableitungen nach
// einem nicht-uniformen discard sind undefiniert (Nachbarn im Quad fehlen).
vec2 ocean_wave_grad(vec2 p, float footprint, float t) {
	vec2 drift = vec2(water_ocean_wave_drift_x, water_ocean_wave_drift_z) * t;
	vec2 g = vec2(0.0);
	float freq = water_ocean_wave_frequency;
	float amp = water_ocean_wave_amplitude;
	for (int o = 0; o < 4; o++) {
		vec2 q = p * freq + drift * (1.0 + float(o) * water_ocean_wave_octave_speedup)
		       + vec2(float(o) * 13.7, float(o) * 7.1);
		float e = 0.08;
		float n0 = noise2(q);
		vec2 d = vec2(noise2(q + vec2(e, 0.0)) - n0, noise2(q + vec2(0.0, e)) - n0) / e;
		g += d * amp * (1.0 - calib_window(water_ocean_wave_fade_lo, water_ocean_wave_fade_hi, footprint * freq));
		freq *= water_ocean_wave_lacunarity;
		amp *= water_ocean_wave_gain;
	}
	return g;
}

void vertex() {
	v_world = VERTEX.xz;
}

void fragment() {
	vec2 p = v_world;
	vec2 terrain_uv = p / world_size + vec2(0.5);
	bool inside_terrain = all(greaterThanEqual(terrain_uv, vec2(0.0)))
	                   && all(lessThanEqual(terrain_uv, vec2(1.0)));
	float footprint = length(fwidth(p));
	// Außerhalb des Sim-Quadrats ist das Meer tief.
	float h = inside_terrain ? texture(height_tex, terrain_uv).r : sea_level - water_ocean_depth_span;
	if (h > sea_level) {
		discard;
	}
	vec2 grad = ocean_wave_grad(p, footprint, u_time);
	vec3 water_n_ws = normalize(vec3(-grad.x, 1.0, -grad.y));
	vec3 water_n_vs = normalize(mat3(VIEW_MATRIX) * water_n_ws);
	NORMAL = water_n_vs;

	// Tiefe über dem Sim-Schelf, normiert 0…1.
	float depth = clamp((sea_level - h) / max(water_ocean_depth_span, 1e-6), 0.0, 1.0);
	vec3 water = mix(water_ocean_shallow_color, water_ocean_mid_color,
	                 calib_window(0.0, water_ocean_mid_depth, depth));
	water = mix(water, water_ocean_deep_color, calib_window(water_ocean_mid_depth, 1.0, depth));
	float ndv = clamp(dot(water_n_vs, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, max(water_fresnel_exponent, 1e-6));
	water = mix(water, water_sky_reflect_color, fresnel * water_fresnel_sky_mix);

	// Brandung: schmaler, von Rauschen gebrochener Saum direkt an der Küste.
	float surf = 1.0 - calib_window(0.0, water_ocean_surf_depth, depth);
	surf *= calib_window(water_ocean_surf_noise_lo, water_ocean_surf_noise_hi,
	                     noise2(p * water_ocean_surf_scale + vec2(u_time * water_ocean_surf_drift, 0.0)));
	water = mix(water, water_ocean_surf_color, surf * water_ocean_surf_strength);

	water *= cloud_light(p, u_time);
	ALBEDO = water;
	ALPHA = 1.0;
	ROUGHNESS = mix(water_roughness_steep, water_roughness_grazing, fresnel);
	METALLIC = 0.0;
	SPECULAR = mix(water_specular_steep, water_specular_grazing, fresnel);
}

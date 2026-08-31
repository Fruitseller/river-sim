// Offenes Meer mit derselben Wasseroptik wie Raster-Seen und Flussbänder.
// Eigene Weltkoordinaten-Wellen statt eines metallischen StandardMaterials.
shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;

uniform float u_time = 0.0;
uniform float world_size = 100.0;
uniform float sea_level = 0.15;
uniform sampler2D height_tex : filter_linear, repeat_disable;

// Wasser-Kalibrierung über die Brücke (Issue #91, Expand-Schritt): dieselben
// Zahlen wie die Literale im Body unten, als Uniform-Default. Main.gd
// überschreibt sie beim Aufbau mit SimRender.WaterUniforms; der Body liest
// vorerst weiter seine Literale — der Umstieg auf die Uniforms ist der
// Contract-Schritt. Defaults gepinnt von SimCoreTests/WaterUniformsTests.swift,
// End-to-End von game/tests/water_uniforms.gd.
uniform float water_fresnel_exponent = 5.0;
uniform float water_fresnel_sky_mix = 0.55;
uniform float water_roughness_steep = 0.34;
uniform float water_roughness_grazing = 0.08;
uniform float water_specular_steep = 0.55;
uniform float water_specular_grazing = 1.0;
uniform vec3 water_shallow_color = vec3(0.18, 0.37, 0.42);
uniform vec3 water_deep_color = vec3(0.03, 0.12, 0.26);
uniform vec3 water_sky_reflect_color = vec3(0.62, 0.7, 0.76);
uniform vec3 water_flow_shimmer_color = vec3(0.012, 0.018, 0.025);

varying vec2 v_world;

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

void vertex() {
	v_world = VERTEX.xz;
}

void fragment() {
	vec2 p = v_world;
	vec2 terrain_uv = p / world_size + vec2(0.5);
	bool inside_terrain = all(greaterThanEqual(terrain_uv, vec2(0.0)))
	                   && all(lessThanEqual(terrain_uv, vec2(1.0)));
	if (inside_terrain && texture(height_tex, terrain_uv).r > sea_level) {
		discard;
	}
	vec2 swell_dir = normalize(vec2(0.82, 0.57));
	vec2 cross_dir = vec2(-swell_dir.y, swell_dir.x);
	float phase1 = dot(p, swell_dir) * 0.72 - u_time * 1.35;
	float phase2 = dot(p, cross_dir) * 1.31 - u_time * 0.82 + 1.7;
	float phase3 = dot(p, normalize(swell_dir + cross_dir)) * 2.7 - u_time * 1.9;
	vec2 grad = swell_dir * cos(phase1) * 0.052
	          + cross_dir * cos(phase2) * 0.026
	          + normalize(swell_dir + cross_dir) * cos(phase3) * 0.012;
	vec3 water_n_ws = normalize(vec3(-grad.x, 1.0, -grad.y));
	vec3 water_n_vs = normalize(mat3(VIEW_MATRIX) * water_n_ws);
	NORMAL = water_n_vs;

	float depth = clamp(0.82 + (noise2(p * 0.055) - 0.5) * 0.16, 0.0, 1.0);
	vec3 shallow = vec3(0.18, 0.37, 0.42);
	vec3 deep = vec3(0.03, 0.12, 0.26);
	vec3 water = mix(shallow, deep, depth);
	float ndv = clamp(dot(water_n_vs, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, 5.0);
	vec3 sky = vec3(0.62, 0.7, 0.76);
	water = mix(water, sky, fresnel * 0.55);

	float flow = sin(dot(p, swell_dir) * 1.4 - u_time * 4.0) * 0.5
	           + sin(dot(p, swell_dir) * 3.1 - u_time * 6.5 + 1.7) * 0.5;
	water += flow * vec3(0.012, 0.018, 0.025);

	ALBEDO = water;
	ALPHA = 1.0;
	ROUGHNESS = mix(0.34, 0.08, fresnel);
	METALLIC = 0.0;
	SPECULAR = mix(0.55, 1.0, fresnel);
}

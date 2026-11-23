shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;

uniform float u_time = 0.0;
uniform float world_size = 100.0;
uniform float grid_n = 256.0;
uniform float sea_level = 0.15;
uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D height_prev_tex : filter_linear, repeat_disable;
uniform float height_blend = 1.0;

uniform float water_fresnel_exponent;
uniform float water_roughness;
uniform float water_specular;

uniform float water_ocean_depth_span;
uniform float water_ocean_mid_depth;
uniform float water_ocean_shoal_scale;
uniform float water_ocean_shoal_depth_variation;
uniform float water_ocean_breaker_spacing;
uniform float water_ocean_breaker_width;
uniform float water_ocean_breaker_depth;
uniform float water_ocean_breaker_strength;
uniform float water_ocean_surf_depth;
uniform float water_ocean_surf_strength;
uniform float water_ocean_surf_scale;
uniform float water_ocean_surf_drift;
uniform float water_ocean_surf_noise_lo;
uniform float water_ocean_surf_noise_hi;
uniform float water_ocean_surf_plume_cut;
uniform float water_ocean_surf_slope_lo;
uniform float water_ocean_surf_slope_hi;
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

uniform sampler2D plume_tex : filter_linear_mipmap, repeat_disable, hint_default_black;
uniform sampler2D plume_prev_tex : filter_linear_mipmap, repeat_disable, hint_default_black;
uniform float overlay_blend = 1.0;
uniform float water_ocean_plume_lod;
uniform float water_ocean_plume_opacity;
uniform vec3 water_ocean_plume_color;

varying vec2 v_world;

#include "res://shaders/clouds.gdshaderinc"

vec2 grid_uv(vec2 xz) {
	float n = max(grid_n, 2.0);
	return ((xz / world_size + 0.5) * (n - 1.0) + 0.5) / n;
}

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

vec4 bspline_weights(float v) {
	vec4 n = vec4(1.0, 2.0, 3.0, 4.0) - v;
	vec4 s = n * n * n;
	float x = s.x;
	float y = s.y - 4.0 * s.x;
	float z = s.z - 4.0 * s.y + 6.0 * s.x;
	return vec4(x, y, z, 6.0 - x - y - z) * (1.0 / 6.0);
}

float texture_bspline(sampler2D tex, vec2 uv, float n) {
	vec2 t = uv * n - 0.5;
	vec2 f = fract(t);
	t -= f;
	vec4 xc = bspline_weights(f.x);
	vec4 yc = bspline_weights(f.y);
	vec4 c = t.xxyy + vec2(-0.5, 1.5).xyxy;
	vec4 s = vec4(xc.xz + xc.yw, yc.xz + yc.yw);
	vec4 o = (c + vec4(xc.yw, yc.yw) / s) / n;
	float s0 = texture(tex, o.xz).r;
	float s1 = texture(tex, o.yz).r;
	float s2 = texture(tex, o.xw).r;
	float s3 = texture(tex, o.yw).r;
	float sx = s.x / (s.x + s.y);
	float sy = s.z / (s.z + s.w);
	return mix(mix(s3, s2, sx), mix(s1, s0, sx), sy);
}

float sediment_plume(vec2 p) {
	vec2 uv = grid_uv(p);
	float lod = water_ocean_plume_lod;
	float s = textureLod(plume_tex, uv, lod).r;
	return overlay_blend < 1.0 ? mix(textureLod(plume_prev_tex, uv, lod).r, s, overlay_blend) : s;
}

void vertex() {
	v_world = VERTEX.xz;
}

void fragment() {
	vec2 p = v_world;
	vec2 terrain_uv = grid_uv(p);
	bool inside_terrain = all(greaterThanEqual(terrain_uv, vec2(0.0)))
	                   && all(lessThanEqual(terrain_uv, vec2(1.0)));
	float footprint = length(fwidth(p));
	float h = sea_level - water_ocean_depth_span;
	float h_shelf = h;
	if (inside_terrain) {
		float n = max(grid_n, 2.0);
		h = texture(height_tex, terrain_uv).r;
		h_shelf = texture_bspline(height_tex, terrain_uv, n);
		if (height_blend < 1.0) {
			h = mix(texture(height_prev_tex, terrain_uv).r, h, height_blend);
			h_shelf = mix(texture_bspline(height_prev_tex, terrain_uv, n), h_shelf, height_blend);
		}
	}
	float shelf_slope = length(vec2(dFdx(h_shelf), dFdy(h_shelf))) / max(footprint, 1e-6);
	if (h > sea_level) {
		discard;
	}
	vec2 grad = ocean_wave_grad(p, footprint, u_time);
	vec3 water_n_ws = normalize(vec3(-grad.x, 1.0, -grad.y));
	vec3 water_n_vs = normalize(mat3(VIEW_MATRIX) * water_n_ws);
	NORMAL = water_n_vs;

	float depth = clamp((sea_level - h_shelf) / max(water_ocean_depth_span, 1e-6), 0.0, 1.0);
	float plume = 0.0;
	float sediment = 0.0;
	if (inside_terrain) {
		plume = sediment_plume(p);
		if (depth < 1.0 || plume > 0.0) {
			vec2 q = p * water_ocean_shoal_scale;
			float banks = noise2(q + vec2(noise2(q.yx), 0.0));
			float streaks = noise2(q * vec2(1.5, 3.0));
			depth *= 1.0 + water_ocean_shoal_depth_variation *
			         (banks + streaks - 1.0) * (1.0 - depth);
			sediment = plume * (0.55 + banks * streaks);
		}
	}
	vec3 water = mix(water_ocean_shallow_color, water_ocean_mid_color,
	                 calib_window(0.0, water_ocean_mid_depth, depth));
	water = mix(water, water_ocean_deep_color, calib_window(water_ocean_mid_depth, 1.0, depth));
	water = mix(water, water_ocean_plume_color, clamp(sediment * water_ocean_plume_opacity, 0.0, 1.0));
	float ndv = clamp(dot(water_n_vs, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, max(water_fresnel_exponent, 1e-6));
	water *= 1.0 - fresnel;

	float line_depth = clamp((sea_level - h) / max(water_ocean_depth_span, 1e-6), 0.0, 1.0);
	if (line_depth < water_ocean_breaker_depth) {
		float slope_gate = calib_window(water_ocean_surf_slope_lo, water_ocean_surf_slope_hi, shelf_slope);
		vec2 foam_uv = p * water_ocean_surf_scale + vec2(u_time * water_ocean_surf_drift, 0.0);
		float patches = noise2(foam_uv);
		float gaps = calib_window(water_ocean_surf_noise_lo, water_ocean_surf_noise_hi, patches);
		float wash = 1.0 - calib_window(0.0, water_ocean_surf_depth, line_depth);
		float distance_to_shore = (sea_level - h) / max(shelf_slope, water_ocean_surf_slope_lo + 1e-6);
		float swell = noise2(foam_uv * 0.4);
		float spray = noise2(foam_uv * 2.0);
		vec2 centers = water_ocean_breaker_spacing * (vec2(1.0, 2.0) + (swell - 0.5) * vec2(0.45, -0.65));
		vec2 crest_distance = abs(vec2(distance_to_shore) - centers + water_ocean_breaker_width * (spray - 0.5));
		float width = max(1e-6, water_ocean_breaker_width * (0.5 + patches));
		vec2 crests = 1.0 - smoothstep(vec2(0.0), vec2(width), crest_distance);
		float outer_gaps = calib_window(water_ocean_surf_noise_lo, water_ocean_surf_noise_hi, 1.0 - patches);
		float breakers = max(crests.x * gaps, crests.y * outer_gaps) * water_ocean_breaker_strength
		               * (1.0 - calib_window(0.0, water_ocean_breaker_depth, line_depth));
		float surf = max(wash * gaps, breakers) * slope_gate;
		surf *= clamp(1.0 - plume * water_ocean_surf_plume_cut, 0.0, 1.0);
		water = mix(water, water_ocean_surf_color, surf * water_ocean_surf_strength);
	}

	water *= cloud_light(vec3(p.x, NODE_POSITION_WORLD.y, p.y), u_time);
	ALBEDO = water;
	ALPHA = 1.0;
	ROUGHNESS = water_roughness;
	METALLIC = 0.0;
	SPECULAR = water_specular;
}

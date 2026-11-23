shader_type spatial;
render_mode cull_disabled, depth_draw_never;

uniform float u_time = 0.0;

uniform float ribbon_blend = 1.0;
uniform bool ribbon_outgoing = false;

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D hf_tex : filter_linear, repeat_disable;
uniform sampler2D height_prev_tex : filter_linear, repeat_disable;
uniform sampler2D hf_prev_tex : filter_linear, repeat_disable;
uniform sampler2D water_tex : filter_linear, repeat_disable;
uniform sampler2D water_prev_tex : filter_linear, repeat_disable;
uniform float height_blend = 1.0;
uniform float overlay_blend = 1.0;
uniform float world_size = 100.0;
uniform float grid_n = 256.0;
uniform float sea_level = 0.15;

uniform float water_lake_gate_lo;
uniform float water_lake_gate_hi;
uniform float water_pond_contour_lo;
uniform float water_pond_contour_hi;
uniform float water_ribbon_still_lo;
uniform float water_ribbon_still_hi;
uniform float water_ribbon_delta_lo;
uniform float water_ribbon_delta_hi;
uniform float water_fresnel_exponent;
uniform float water_opacity_shallow;
uniform float water_opacity_deep;
uniform float water_roughness;
uniform float water_specular;
uniform vec3 water_shallow_color;
uniform vec3 water_deep_color;
uniform vec3 water_flow_shimmer_color;
uniform vec3 water_delta_plume_color;
uniform vec3 water_oxbow_water_color;
uniform float water_ribbon_bend_depth;
uniform vec3 water_riffle_color;
uniform float water_riffle_depth;
uniform vec3 water_foam_color;
uniform float water_foam_amount;
uniform float water_foam_scale;
uniform float water_river_specular;
uniform float water_cloud_reflection;
uniform float water_ribbon_shoal_mix;
uniform vec3 water_ribbon_shoal_color;
uniform float water_ribbon_waterline;
uniform float water_ribbon_waterline_jitter;
uniform float water_ribbon_waterline_scale;
uniform float water_ribbon_bank_opacity;
uniform float water_ribbon_fade_cap;
uniform vec3 water_ribbon_bank_color;
uniform vec3 water_bed_color;
uniform float water_ribbon_ripple_frequency;
uniform float water_ribbon_ripple_amplitude;
uniform float water_ribbon_ripple_stretch;
uniform float water_ribbon_ripple_speed;
uniform float water_ocean_wave_lacunarity;
uniform float water_ocean_wave_gain;
uniform float water_ocean_wave_fade_lo;
uniform float water_ocean_wave_fade_hi;
uniform float water_ocean_depth_span;
uniform vec3 water_ocean_shallow_color;
uniform float water_corridor_shore;
uniform float water_corridor_shore_bend;

#include "res://shaders/corridor_common.gdshaderinc"

float calib_window(float lo, float hi, float x) {
	return smoothstep(lo, max(hi, lo + 1e-6), x);
}

float ribbon_fade_alpha(float a) {
	float share = ribbon_outgoing ? 1.0 - ribbon_blend : ribbon_blend;
	if (share >= 1.0) {
		return a;
	}
	return 1.0 - pow(1.0 - clamp(a, 0.0, water_ribbon_fade_cap), max(share, 0.0));
}

varying vec2 v_dir;
varying float v_rank;
varying float v_alpha;
varying float v_kind;
varying float v_bend;
varying vec3 v_world;
varying vec4 v_flow;
varying vec4 v_profile;

#include "res://shaders/clouds.gdshaderinc"

float ribbon_hash(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float ribbon_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(ribbon_hash(i), ribbon_hash(i + vec2(1.0, 0.0)), u.x),
	           mix(ribbon_hash(i + vec2(0.0, 1.0)), ribbon_hash(i + vec2(1.0)), u.x), u.y);
}

vec2 grid_uv(vec2 xz) {
	float n = max(grid_n, 2.0);
	return ((xz / world_size + 0.5) * (n - 1.0) + 0.5) / n;
}

float water_g_at(vec2 uv) {
	float g = texture(water_tex, uv).g;
	return overlay_blend < 1.0 ? mix(texture(water_prev_tex, uv).g, g, overlay_blend) : g;
}

float lake_mask_at(vec2 uv) {
	float h = texture(height_tex, uv).r;
	h = height_blend < 1.0 ? mix(texture(height_prev_tex, uv).r, h, height_blend) : h;
	float hf = texture(hf_tex, uv).r;
	hf = overlay_blend < 1.0 ? mix(texture(hf_prev_tex, uv).r, hf, overlay_blend) : hf;
	float pond = max(hf - h, 0.0) * step(sea_level, hf);
	return calib_window(water_pond_contour_lo, water_pond_contour_hi, pond)
		* calib_window(water_lake_gate_lo, water_lake_gate_hi, water_g_at(uv));
}

vec2 ribbon_ripple_grad(vec2 q, float footprint) {
	vec2 g = vec2(0.0);
	float freq = water_ribbon_ripple_frequency;
	float amp = water_ribbon_ripple_amplitude;
	for (int o = 0; o < 3; o++) {
		vec2 p = q * freq + vec2(float(o) * 13.7, float(o) * 7.1);
		float e = 0.08;
		float n0 = ribbon_noise(p);
		vec2 d = vec2(ribbon_noise(p + vec2(e, 0.0)) - n0, ribbon_noise(p + vec2(0.0, e)) - n0) / e;
		g += d * amp * (1.0 - calib_window(water_ocean_wave_fade_lo, water_ocean_wave_fade_hi, footprint * freq));
		freq *= water_ocean_wave_lacunarity;
		amp *= water_ocean_wave_gain;
	}
	return g;
}

void vertex() {
	v_dir = COLOR.rg * 2.0 - 1.0;
	v_rank = COLOR.b;
	v_alpha = COLOR.a;
	v_kind = UV2.x;
	v_bend = UV2.y;
	v_flow = CUSTOM0;
	v_profile = CUSTOM1;
	vec3 p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float running_v = (1.0 - step(0.25, UV2.x)) * step(0.05, length(v_dir));
	float half_band = 0.5 * max(CUSTOM0.w, 0.0);
	float f = corridor_widen(p, max(CUSTOM1.z, 1e-4), COLOR.a * running_v * CUSTOM1.x,
		INV_VIEW_MATRIX[3].xyz, PROJECTION_MATRIX);
	if (f > 1.001) {
		vec2 dir = normalize(v_dir);
		vec2 perp = vec2(-dir.y, dir.x);
		float off = half_band * (UV.x * 2.0 - 1.0);
		p.xz += perp * (corridor_widened_offset(off, max(CUSTOM1.z, 1e-4), f) - off);
		v_profile.y = max(v_profile.y, corridor_terrain_y(p.xz) + CORRIDOR_LID_CLEAR);
	}
	VERTEX = p;
	v_world = p;
	POSITION = corridor_clip(p, v_profile.y, INV_VIEW_MATRIX[3].xyz, VIEW_MATRIX, PROJECTION_MATRIX);
}

void fragment() {
	float still = calib_window(water_ribbon_still_lo, water_ribbon_still_hi, v_kind);
	float delta = (1.0 - still) * calib_window(water_ribbon_delta_lo, water_ribbon_delta_hi, v_kind);

	vec2 guv = grid_uv(v_world.xz);
	float h_terrain = texture(height_tex, guv).r;
	if (height_blend < 1.0) {
		h_terrain = mix(texture(height_prev_tex, guv).r, h_terrain, height_blend);
	}
	float in_sea = clamp((sea_level - h_terrain) / max(water_ocean_depth_span * 0.1, 1e-5), 0.0, 1.0);

	float presence = clamp(v_alpha, 0.0, 1.0);
	float visible = smoothstep(0.05, 0.75, mix(presence, 1.0, in_sea));
	float across_band = 1.0 - abs(UV.x * 2.0 - 1.0);
	float across = clamp((across_band - (1.0 - visible)) / max(visible, 1e-3), 0.0, 1.0);
	float aa = max(fwidth(across_band), 1e-4) / max(visible, 1e-3);
	float footprint = length(fwidth(v_world.xz));
	float band_width = max(v_flow.w, 0.0);

	float line = water_ribbon_waterline
		+ (ribbon_noise(v_world.xz * water_ribbon_waterline_scale) - 0.5) * 2.0 * water_ribbon_waterline_jitter;
	float wet = smoothstep(line - aa, line + aa, across);
	float profile = calib_window(line, 1.0, across);
	float corridor = clamp(v_profile.x, 0.0, 1.0);
	float off_w = abs(UV.x * 2.0 - 1.0) * 0.5 * band_width;
	float aa_w = max(fwidth(off_w), 1e-5);
	if (corridor > 0.0) {
		float side = UV.x < 0.5 ? -1.0 : 1.0;
		float shore_w = max(v_profile.z, 1e-5)
			* (water_corridor_shore - water_corridor_shore_bend * side * clamp(v_bend, -1.0, 1.0));
		float wet_c = 1.0 - smoothstep(shore_w - aa_w, shore_w + aa_w, off_w);
		float profile_c = clamp(1.0 - off_w / max(shore_w, 1e-5), 0.0, 1.0);
		wet = mix(wet, wet_c, corridor);
		profile = mix(profile, profile_c, corridor);
	}
	float bank = calib_window(0.0, line, across) * (1.0 - wet) * (1.0 - in_sea) * (1.0 - corridor);

	float depth = clamp(0.35 + v_rank * 1.5, 0.0, 1.0) * mix(0.7, 1.0, smoothstep(0.0, 0.45, profile));
	depth = mix(depth, depth * 0.35, delta);
	float running = (1.0 - still) * (1.0 - delta);
	float riffle = clamp(v_flow.x, 0.0, 1.0) * running;
	float whitewater = clamp(v_flow.y, 0.0, 1.0) * running;
	float steep = clamp(v_flow.z, 0.0, 1.0) * running;
	depth *= mix(1.0, water_riffle_depth, riffle);
	float outward = -(UV.x * 2.0 - 1.0) * clamp(v_bend, -1.0, 1.0);
	depth = clamp(depth + water_ribbon_bend_depth * outward, 0.0, 1.0);

	vec3 water = mix(water_shallow_color, water_deep_color, depth);
	water = mix(water, water_delta_plume_color, delta * 0.5);
	water = mix(water, water_oxbow_water_color, still * 0.5);

	vec2 d1 = normalize(length(v_dir) > 0.05 ? v_dir : vec2(0.7, 0.7));
	vec2 d2 = vec2(-d1.y, d1.x);
	float speed = water_ribbon_ripple_speed * (1.0 - still);
	vec2 q = vec2(UV.y * water_ribbon_ripple_stretch - u_time * speed, UV.x * band_width);
	float local_speed = speed * (0.6 + 1.6 * steep + 0.6 * riffle);
	float ph0 = fract(u_time * 0.2);
	float ph1 = fract(ph0 + 0.5);
	float w0 = 1.0 - abs(2.0 * ph0 - 1.0);
	vec2 q0 = vec2(UV.y * water_ribbon_ripple_stretch - local_speed * ph0 * 5.0, UV.x * band_width);
	vec2 q1 = vec2(UV.y * water_ribbon_ripple_stretch - local_speed * ph1 * 5.0 + 3.7, UV.x * band_width + 1.3);
	vec2 g_flow = running > 0.5
		? ribbon_ripple_grad(q0, footprint) * w0 + ribbon_ripple_grad(q1, footprint) * (1.0 - w0)
		: ribbon_ripple_grad(q, footprint);
	vec2 gq = g_flow * mix(1.0, 0.4, still) * mix(0.6, 1.0, depth)
		* (1.0 + 1.5 * max(riffle, steep));
	vec2 grad = d1 * gq.x * water_ribbon_ripple_stretch + d2 * gq.y;
	vec3 water_n_ws = normalize(vec3(-grad.x, 1.0, -grad.y));
	vec3 water_n_vs = normalize(mat3(VIEW_MATRIX) * water_n_ws);

	float ndv = clamp(dot(water_n_vs, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, max(water_fresnel_exponent, 1e-6));

	float flow = (ribbon_noise(vec2(q.x * 0.35 - u_time * speed * 0.5, q.y * 2.2) * water_ribbon_ripple_frequency + 5.3) - 0.5) * 2.0;
	water += flow * water_flow_shimmer_color * (1.0 - still);

	float opacity = mix(water_opacity_shallow, water_opacity_deep, depth);
	vec3 water_final = mix(water, mix(water_bed_color, water, opacity), 1.0 - corridor);
	float streak_far = ribbon_noise(vec2(q.x * 0.8 - u_time * speed * 0.8, q.y * 2.8) * water_foam_scale * 0.3 + 2.7);
	float streak_near = sqrt(ribbon_noise(vec2(q.x * 1.2 - u_time * speed, q.y * 2.4) * water_foam_scale + 9.1)
		* ribbon_noise(vec2(q.x * 0.6 - u_time * speed, q.y * 4.0) * water_foam_scale + 4.4));
	float near_w = 1.0 - smoothstep(0.3, 1.0, footprint * water_foam_scale * 8.0);
	float streak = mix(streak_far, streak_near, near_w);
	water_final = mix(water_final, water_riffle_color, riffle * mix(0.4, 1.0, smoothstep(0.3, 0.7, streak)) * profile);
	float shoal_gate = smoothstep(0.55, 0.75, ribbon_noise(vec2(q.x * 4.0, q.y * 2.0) + 31.0));
	water_final = mix(water_final, water_ribbon_shoal_color,
		water_ribbon_shoal_mix * max(-outward, 0.0) * shoal_gate * (1.0 - smoothstep(0.0, 0.15, profile)));
	float foam_drive = clamp(whitewater + 0.5 * riffle * (1.0 - 0.5 * depth), 0.0, 1.0);
	float blob = ribbon_noise(vec2(q.x * 2.5, q.y) * water_foam_scale * 0.5 + 17.0);
	float foam_n = streak * 0.55 + blob * 0.45;
	float foam = smoothstep(0.78 - 0.3 * foam_drive, 1.03 - 0.3 * foam_drive, foam_n)
		* smoothstep(0.15, 0.6, foam_drive) * profile * water_foam_amount * mix(0.6, 1.0, near_w);
	water_final = mix(water_final, water_ocean_shallow_color, in_sea * (1.0 - presence * 0.5));
	water_final *= 1.0 - fresnel;
	water_final = mix(water_final, water_foam_color, clamp(foam, 0.0, 1.0));

	vec3 col = mix(water_ribbon_bank_color, water_final, wet);
	col *= cloud_light(v_world, u_time);
	ALBEDO = col;
	vec3 view_g = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	float g_size = exp2(ceil(log2(max(footprint * 2.0, 0.004))));
	vec2 g_pos = v_world.xz / g_size;
	vec2 cell = floor(g_pos);
	float g_tick = floor(u_time * 3.0);
	vec2 jit = vec2(ribbon_hash(cell + g_tick), ribbon_hash(cell.yx + 17.0 + g_tick)) - 0.5;
	vec2 g_ctr = vec2(ribbon_hash(cell + 41.0 + g_tick), ribbon_hash(cell.yx + 73.0 + g_tick)) * 0.5 + 0.25;
	float g_dot = 1.0 - smoothstep(0.1, 0.3, length(fract(g_pos) - g_ctr));
	vec3 n_glint = normalize(water_n_ws + vec3(jit.x, 0.0, jit.y) * 0.5);
	float glint = pow(max(dot(reflect(-view_g, n_glint), normalize(corridor_sun_dir)), 0.0), 900.0)
		* g_dot * wet * (1.0 - still) * (1.0 - foam) * smoothstep(0.005, 0.05, footprint);
	NORMAL = normalize(mix(mat3(VIEW_MATRIX) * vec3(0.0, 1.0, 0.0), water_n_vs, wet));
	float lake = lake_mask_at(guv);
	float sea_alpha = mix(smoothstep(0.0, 0.25, presence), presence, in_sea);
	float body = mix(1.0, clamp(max(opacity, fresnel) + foam, 0.0, 1.0), corridor);
	ALPHA = ribbon_fade_alpha(sea_alpha * max(wet * body, bank * water_ribbon_bank_opacity)
		* (1.0 - lake * (1.0 - delta) * (1.0 - corridor)));
	vec3 cam_w = CAMERA_POSITION_WORLD;
	LIGHT_VERTEX = (VIEW_MATRIX * vec4(corridor_lid_point(v_world, v_profile.y, cam_w), 1.0)).xyz;
	float water_rough = mix(water_roughness, 0.55, still);
	water_rough = mix(water_rough, 0.7, foam);
	ROUGHNESS = mix(0.6, water_rough, wet);
	float spec = mix(water_specular, water_river_specular, running * (1.0 - foam));
	SPECULAR = mix(0.4, spec, wet);
	vec3 view_ws = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	vec3 refl = reflect(-view_ws, water_n_ws);
	float cloud_w = still * wet * water_cloud_reflection;
	float cloud_hit = clouds_enabled && cloud_w > 0.0 && refl.y > 0.05 && v_world.y < cloud_height
		? cloud_cover(v_world.xz + refl.xz * (cloud_height - v_world.y) / refl.y, u_time) : 0.0;
	EMISSION = vec3(0.9, 0.93, 0.97) * cloud_hit * cloud_w * (0.35 + 0.65 * fresnel)
		+ vec3(1.0, 0.92, 0.78) * glint * 3.0;
}

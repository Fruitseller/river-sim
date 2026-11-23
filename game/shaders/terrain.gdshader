shader_type spatial;
render_mode cull_disabled;

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D hf_tex : filter_linear, repeat_disable;
uniform sampler2D color_tex : filter_linear, repeat_disable;
uniform sampler2D surface_tex : filter_linear, repeat_disable;
uniform sampler2D cover_tex : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D height_prev_tex : filter_linear, repeat_disable;
uniform sampler2D hf_prev_tex : filter_linear, repeat_disable;
uniform sampler2D color_prev_tex : filter_linear, repeat_disable;
uniform sampler2D surface_prev_tex : filter_linear, repeat_disable;
uniform sampler2D cover_prev_tex : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D flow_prev_tex : filter_linear, repeat_disable;
uniform sampler2D water_prev_tex : filter_linear, repeat_disable;
uniform float height_blend = 1.0;
uniform float overlay_blend = 1.0;
uniform sampler2D debug_difference_tex : filter_linear, repeat_disable;
uniform sampler2D water_tex : filter_linear, repeat_disable;
uniform sampler2D flow_tex : filter_linear, repeat_disable;
uniform float hscale = 24.0;
uniform float world_size = 100.0;
uniform float grid_n = 256.0;
uniform float u_time = 0.0;
uniform float sea_level = 0.15;
uniform float veg_alt_lo = 0.45;
uniform float veg_alt_hi = 0.72;

uniform float detail_strength = 0.16;
uniform bool detail_enabled = true;
uniform bool material_enabled = true;
uniform bool debug_difference = false;

uniform float water_lake_gate_lo;
uniform float water_lake_gate_hi;
uniform float water_river_mask_lo;
uniform float water_river_mask_hi;
uniform float water_wall_slope_lo;
uniform float water_wall_slope_hi;
uniform float water_shore_lo;
uniform float water_shore_hi;
uniform float water_pond_contour_lo;
uniform float water_pond_contour_hi;
uniform float water_geometry_lift_lo;
uniform float water_geometry_lift_hi;
uniform float water_lake_depth_lo;
uniform float water_lake_depth_span;
uniform float water_river_depth_lo;
uniform float water_river_depth_hi;
uniform float water_fresnel_exponent;
uniform float water_opacity_shallow;
uniform float water_opacity_deep;
uniform float water_roughness;
uniform float water_specular;
uniform vec3 water_shallow_color;
uniform vec3 water_deep_color;
uniform vec3 water_flow_shimmer_color;
uniform vec3 water_bed_color;
uniform float water_raster_steep_lo;
uniform float water_raster_steep_hi;
uniform vec3 water_riffle_color;
uniform float water_riffle_depth;
uniform vec3 water_foam_color;
uniform float water_foam_amount;
uniform float water_river_specular;
uniform float water_cloud_reflection;
uniform vec3 water_lake_color;
uniform vec3 water_bar_sand_color;
uniform vec3 water_bar_sand_wet_color;
uniform float water_bar_roughness;
uniform vec3 water_beach_dry_color;
uniform vec3 water_beach_wet_color;
uniform float water_beach_wet_height;
uniform float water_beach_height_hi;
uniform float water_beach_blend_height;
uniform float water_beach_edge_lo;
uniform float water_beach_edge_hi;

uniform bool relief_enabled = false;
uniform sampler2D relief_tex : filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D relief_prev_tex : filter_linear_mipmap_anisotropic, repeat_disable;
uniform float bake_blend = 1.0;
uniform float relief_height_code;
uniform float relief_slope_code;
uniform float relief_shade_dark;
uniform float relief_shade_light;
uniform float relief_detail_scale;
uniform float relief_detail_shade;
uniform float relief_detail_normal;
uniform float relief_geometry_age;
uniform float sim_year = 0.0;
uniform bool canopy_enabled = false;
uniform sampler2D forest_tex : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D forest_prev_tex : filter_linear, repeat_disable, hint_default_black;
uniform bool tree_instances = false;
uniform float canopy_cell;
uniform float canopy_height;
uniform float canopy_lift_lo;
uniform float canopy_lift_hi;
uniform float canopy_lift_smooth_texels;
uniform float canopy_cover_lo;
uniform float canopy_cover_hi;
uniform float canopy_gap_lo;
uniform float canopy_gap_hi;
uniform float canopy_crown_mid;
uniform float canopy_crown_spread;
uniform float canopy_crown_radius;
uniform float canopy_crown_radius_jitter;
uniform float canopy_detail_lo;
uniform float canopy_detail_hi;
uniform float canopy_meadow_lo;
uniform float canopy_meadow_hi;
uniform float canopy_meadow_share;
uniform float conifer_lo;
uniform float conifer_hi;
uniform float material_ridge_rock_gain;
uniform float material_gully_scree_share;
uniform float material_rock_relief_gain;
uniform float material_crevasse_spacing;
uniform float material_crevasse_slope_lo;
uniform float material_crevasse_slope_hi;
uniform float material_moraine_lo;
uniform float material_moraine_hi;
uniform float material_snow_cavity;
uniform float material_snow_slope_lo;
uniform float material_snow_slope_hi;
uniform float material_snow_breakup;
uniform float material_rock_fray;
uniform float material_redistribute_fade;
uniform float material_outcrop;
uniform float material_outcrop_slope_lo;
uniform float material_outcrop_slope_hi;
uniform float material_scree_streak;

varying float v_forest;
varying vec2 v_stand;

varying vec2 v_uv;
varying vec2 v_xz;

float calib_window(float lo, float hi, float x) {
	return smoothstep(lo, max(hi, lo + 1e-6), x);
}

float height_at(vec2 uv) {
	float h = texture(height_tex, uv).r;
	return height_blend < 1.0 ? mix(texture(height_prev_tex, uv).r, h, height_blend) : h;
}

float hf_at(vec2 uv) {
	float h = texture(hf_tex, uv).r;
	return overlay_blend < 1.0 ? mix(texture(hf_prev_tex, uv).r, h, overlay_blend) : h;
}

vec4 color_at(vec2 uv) {
	vec4 c = texture(color_tex, uv);
	return overlay_blend < 1.0 ? mix(texture(color_prev_tex, uv), c, overlay_blend) : c;
}

vec4 surface_at(vec2 uv) {
	vec4 m = texture(surface_tex, uv);
	return overlay_blend < 1.0 ? mix(texture(surface_prev_tex, uv), m, overlay_blend) : m;
}

vec4 cover_at(vec2 uv) {
	vec4 c = texture(cover_tex, uv);
	return overlay_blend < 1.0 ? mix(texture(cover_prev_tex, uv), c, overlay_blend) : c;
}

float flow_at(vec2 uv) {
	float f = texture(flow_tex, uv).r;
	return overlay_blend < 1.0 ? mix(texture(flow_prev_tex, uv).r, f, overlay_blend) : f;
}

vec4 water_at(vec2 uv) {
	vec4 w = texture(water_tex, uv);
	return overlay_blend < 1.0 ? mix(texture(water_prev_tex, uv), w, overlay_blend) : w;
}

vec2 world_uv(vec3 vert) {
	float n = max(grid_n, 2.0);
	return ((vert.xz / world_size + 0.5) * (n - 1.0) + 0.5) / n;
}

float pond_of(float hf_val, float h_val) {
	return max(hf_val - h_val, 0.0) * step(sea_level, hf_val);
}

float pond_at(vec2 uv, float h_val) {
	return pond_of(hf_at(uv), h_val);
}

float lake_gate_at(vec2 uv) {
	return calib_window(water_lake_gate_lo, water_lake_gate_hi, water_at(uv).g);
}

#include "res://shaders/erosion_filter.gdshaderinc"

vec4 erosion_detail(vec2 p, vec2 slope, float fade_target_in, out float out_mag) {
	return erosion_detail_at(p, slope, fade_target_in, max(relief_detail_scale, 1e-4), detail_strength, 2, out_mag);
}

#include "res://shaders/amplify.gdshaderinc"

vec4 relief_sample(vec2 uv, float lod) {
	vec4 cur = textureLod(relief_tex, uv, lod);
	if (bake_blend < 1.0) {
		cur = mix(textureLod(relief_prev_tex, uv, lod), cur, bake_blend);
	}
	return cur;
}

float relief_lift(vec2 uv) {
	if (!relief_enabled) {
		return 0.0;
	}
	return (relief_sample(uv, amplify_vertex_lod).r - 0.5) / max(relief_height_code, 1e-6)
	     * smoothstep(0.0, relief_geometry_age, sim_year);
}

vec4 relief_pixel(vec2 uv) {
	if (!relief_enabled) {
		return vec4(0.5);
	}
	vec4 cur = texture(relief_tex, uv);
	if (bake_blend < 1.0) {
		cur = mix(texture(relief_prev_tex, uv), cur, bake_blend);
	}
	return cur;
}

vec2 relief_slope(vec4 relief) {
	return (relief.gb - 0.5) / max(relief_slope_code, 1e-6);
}

float relief_cavity(vec4 relief) {
	return (relief.a - 0.5) * 2.0;
}

float vhash(vec2 c) {
	const vec2 k = vec2(0.3183099, 0.3678794);
	vec2 x = fract(c * k) * 17.0 + k.yx;
	return fract(16.0 * k.x * fract(x.x * x.y * (x.x + x.y))) * 2.0 - 1.0;
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = vhash(i);
	float b = vhash(i + vec2(1.0, 0.0));
	float c = vhash(i + vec2(0.0, 1.0));
	float d = vhash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 0.5 + 0.5;
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.55;
	for (int octave = 0; octave < 3; octave++) {
		value += vnoise(p) * amplitude;
		p = p * 2.03 + vec2(17.1, 9.2);
		amplitude *= 0.48;
	}
	return value;
}

float triplanar_fbm(vec3 p, vec3 n) {
	vec3 weight = pow(abs(n), vec3(4.0));
	weight /= max(weight.x + weight.y + weight.z, 0.0001);
	weight = max(weight - 0.02, 0.0);
	float sum = 0.0;
	if (weight.x > 0.0) { sum += fbm(p.yz) * weight.x; }
	if (weight.y > 0.0) { sum += fbm(p.xz) * weight.y; }
	if (weight.z > 0.0) { sum += fbm(p.xy) * weight.z; }
	return sum / max(weight.x + weight.y + weight.z, 1e-4);
}

float crevasses(vec2 p, vec2 fall, float px) {
	float s = max(material_crevasse_spacing, 1e-4);
	vec2 side = vec2(-fall.y, fall.x);
	float t = dot(p, fall) / s + (vnoise(vec2(dot(p, side) / (s * 3.0), 0.0)) - 0.5) * 1.6;
	float fw = px / s;
	float detail = 1.0 - smoothstep(0.3, 0.9, fw);
	float f = abs(fract(t) - 0.5) * 2.0;
	float open = vnoise(vec2(dot(p, side) / (s * 1.7), floor(t)));
	return smoothstep(0.82 - fw, 0.97, f) * smoothstep(0.35, 0.6, open) * detail;
}

vec4 crown_hash(vec2 c) {
	uvec3 v = uvec3(uvec2(ivec2(c) + ivec2(65536)), 152u);
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	uint w = v.x ^ v.y ^ v.z;
	return vec4(vec3(v), float(w)) * (2.0 / 4294967295.0) - 1.0;
}

void canopy(vec2 wp, float h, float px, vec2 f_grad, out vec3 col, out float amount,
            out vec2 tilt_n) {
	col = vec3(0.0);
	amount = 0.0;
	tilt_n = vec2(0.0);
	float f = v_forest;
	if (f <= 0.002) {
		return;
	}
	float detail = 1.0 - calib_window(canopy_detail_lo, canopy_detail_hi, px / max(canopy_cell, 1e-6));
	if (tree_instances) {
		detail = 0.0;
	}
	if (detail <= 0.0 && f <= canopy_cover_lo) {
		return;
	}
	float stand = v_stand.x;
	float region = v_stand.y;
	float alt_share = clamp((h - conifer_lo) / max(conifer_hi - conifer_lo, 1e-6), 0.0, 1.0);
	float conifer_share = clamp(alt_share * 0.9 + (region - 0.5) * 1.4 + (stand - 0.5) * 0.6 + 0.1,
	                            0.05, 0.95);
	float best = 0.0;
	vec2 tilt = vec2(0.0);
	float tint = 0.0;
	float con = 0.0;
	if (detail > 0.0) {
		float shrink = mix(0.82, 1.0, smoothstep(0.3, 0.85, f));
		vec2 p = wp / max(canopy_cell, 1e-6);
		vec2 g = floor(p - 0.5);
		for (int j = 0; j <= 1; j++) {
			for (int i = 0; i <= 1; i++) {
				vec2 c = g + vec2(float(i), float(j));
				vec4 r = crown_hash(c);
				vec2 centre = c + 0.5 + r.xy * 0.28;
				float fc = f + dot(f_grad, centre * canopy_cell - wp);
				if (fc < canopy_crown_mid + canopy_crown_spread * (r.w * 0.3 + (0.5 - stand) * 2.4)) {
					continue;
				}
				vec2 d = p - centre;
				bool is_con = (r.x * 0.5 + 0.5) < conifer_share;
				float big = step(0.35, r.z);
				float rad = (canopy_crown_radius + canopy_crown_radius_jitter * r.z)
				          * mix(0.75, 0.97, big) * (is_con ? 0.88 : 1.0) * shrink;
				float dd = length(d);
				float dome = sqrt(max(rad * rad - dd * dd, 0.0));
				float hgt = is_con ? mix(dome, (rad - dd) * 1.7, 0.35) : dome;
				hgt += hgt > 0.0 ? big * 0.12 : 0.0;
				if (hgt > best) {
					best = hgt;
					tilt = d / max(dome, 0.15) * (is_con ? 1.0 : 0.85);
					tint = r.y * 0.5 + 0.5;
					con = is_con ? 1.0 : 0.0;
				}
			}
		}
	}
	float yellow = smoothstep(0.72, 0.86, stand) * (1.0 - conifer_share) * 0.6;
	vec3 decid = mix(vec3(0.070, 0.150, 0.036), vec3(0.135, 0.185, 0.035), yellow);
	vec3 conif = vec3(0.030, 0.072, 0.038);
	vec3 gap = vec3(0.012, 0.026, 0.012);
	vec3 avg = mix(mix(decid, conif, conifer_share) * 0.8, gap, 0.4);
	float fw = detail > 0.0 ? f + (vnoise(wp * 4.0 + vec2(1.3, 8.1)) - 0.5) * 0.3 * detail : f;
	float inside = calib_window(canopy_gap_lo, canopy_gap_hi, fw);
	vec3 crown = mix(decid * mix(0.7, 1.35, tint), conif * mix(0.75, 1.3, tint), con)
	           * mix(0.45, 1.05, clamp(best / 0.5, 0.0, 1.0));
	float covered = best > 0.0 ? 1.0 : inside;
	vec3 near_col = best > 0.0 ? crown : gap;
	col = mix(avg, near_col, detail);
	amount = mix(calib_window(canopy_cover_lo, canopy_cover_hi, fw), covered, detail);
	tilt_n = clamp(tilt, vec2(-2.0), vec2(2.0)) * 0.85 * detail;
}

#ifdef FLUSSTAL_STUDY
#include "res://studies/flusstal/landscape.gdshaderinc"
#endif
#include "res://shaders/clouds.gdshaderinc"
#include "res://shaders/scan_material.gdshaderinc"

void vertex() {
	vec2 uv = world_uv(VERTEX);
	v_uv = uv;
	v_xz = VERTEX.xz;
	float hraw = height_at(uv);
	float hfv = hf_at(uv);
	float pond = pond_of(hfv, hraw);
	float lift = calib_window(water_geometry_lift_lo, water_geometry_lift_hi, pond) * lake_gate_at(uv);
	VERTEX.y = mix(hraw, hfv, lift) * hscale + relief_lift(uv) * (1.0 - lift);
	v_forest = 0.0;
	if (canopy_enabled) {
		v_forest = textureLod(forest_tex, uv, 0.0).r;
		if (overlay_blend < 1.0) {
			v_forest = mix(textureLod(forest_prev_tex, uv, 0.0).r, v_forest, overlay_blend);
		}
	}
	v_stand = vec2(0.5);
	if (v_forest > 0.002) {
		vec2 swp = VERTEX.xz + world_size * 0.5;
		v_stand = vec2(vnoise(swp * 0.55 + vec2(3.7, 11.3)), vnoise(swp * 0.13 + vec2(19.1, 5.4)));
	}
	float lift_f = v_forest;
	if (canopy_enabled && v_forest > canopy_lift_lo) {
		vec2 o = vec2(canopy_lift_smooth_texels / grid_n);
		float sm = textureLod(forest_tex, uv + o, 0.0).r + textureLod(forest_tex, uv - o, 0.0).r
		         + textureLod(forest_tex, uv + vec2(o.x, -o.y), 0.0).r
		         + textureLod(forest_tex, uv + vec2(-o.x, o.y), 0.0).r;
		if (overlay_blend < 1.0) {
			float sp = textureLod(forest_prev_tex, uv + o, 0.0).r + textureLod(forest_prev_tex, uv - o, 0.0).r
			         + textureLod(forest_prev_tex, uv + vec2(o.x, -o.y), 0.0).r
			         + textureLod(forest_prev_tex, uv + vec2(-o.x, o.y), 0.0).r;
			sm = mix(sp, sm, overlay_blend);
		}
		lift_f = min(v_forest, sm * 0.25);
	}
	float v_lift = calib_window(canopy_lift_lo, canopy_lift_hi, lift_f);
	if (tree_instances) {
		v_lift = 0.0;
	}
	VERTEX.y += v_lift * canopy_height;
	float texel = 1.0 / grid_n;
	float hL = height_at(uv - vec2(texel, 0.0));
	float hR = height_at(uv + vec2(texel, 0.0));
	float hD = height_at(uv - vec2(0.0, texel));
	float hU = height_at(uv + vec2(0.0, texel));
	float sw = world_size / (grid_n - 1.0);
	NORMAL = normalize(vec3(-(hR - hL) * hscale, 2.0 * sw, -(hU - hD) * hscale));
}

void fragment() {
	vec4 macro_rgba = color_at(v_uv);
	vec3 macro_color = macro_rgba.rgb;
	vec4 surface = surface_at(v_uv);
	float hval = height_at(v_uv);
	vec2 wp = v_xz + world_size * 0.5;
	vec3 material_pos = vec3(wp.x - world_size * 0.5, hval * hscale,
	                         wp.y - world_size * 0.5);
	float px_wp = length(fwidth(wp));
	float px_mat = length(fwidth(material_pos));
	vec3 dpdx = dFdx(material_pos);
	vec3 dpdy = dFdy(material_pos);
	mat2 dw = mat2(vec2(dFdx(wp).x, dFdy(wp).x), vec2(dFdx(wp).y, dFdy(wp).y));
	float dw_det = determinant(dw);
	vec2 f_grad = abs(dw_det) > 1e-12
	            ? inverse(dw) * vec2(dFdx(v_forest), dFdy(v_forest)) : vec2(0.0);
	vec3 canopy_col;
	float canopy_amount;
	vec2 canopy_tilt;
	canopy(wp, hval, px_wp, f_grad, canopy_col, canopy_amount, canopy_tilt);
	vec4 relief = relief_pixel(v_uv);
	vec4 amp_maps = amplify_maps(v_uv, bake_blend);

	float texel = 1.0 / grid_n;
	float hL = height_at(v_uv - vec2(texel, 0.0));
	float hR = height_at(v_uv + vec2(texel, 0.0));
	float hD = height_at(v_uv - vec2(0.0, texel));
	float hU = height_at(v_uv + vec2(0.0, texel));
	vec2 coarse_slope = vec2(hR - hL, hU - hD) * 0.5 * grid_n;
	coarse_slope += relief_slope(relief);
	float world_slope = length(coarse_slope) * hscale / world_size;

	float ws = world_size / 100.0;
	float view_dist = length(VERTEX);
	float dfade = (1.0 - smoothstep(110.0 * ws, 280.0 * ws, view_dist))
	            * smoothstep(sea_level + 0.005, sea_level + 0.045, hval);
	vec2 det_slope = vec2(0.0);
	float det_shade = 0.0;
	float det_ridge = 0.0;
	if (detail_enabled && !debug_difference && dfade > 0.002 && canopy_amount < 0.9999) {
		float fade_target = clamp((hval - sea_level) / 0.6 * 2.0 - 1.0, -1.0, 1.0);
		float det_mag;
		vec4 det = erosion_detail(v_uv, coarse_slope, fade_target, det_mag);
		float flow_gain = mix(0.3, 1.8, flow_at(v_uv));
		flow_gain *= mix(1.0, material_rock_relief_gain, clamp(surface.g, 0.0, 1.0));
		flow_gain *= 1.0 - 0.75 * smoothstep(1.2, 2.4, world_slope);
		det_slope = det.yz * dfade * relief_detail_normal * flow_gain;
		det_shade = det.x / det_mag * dfade * flow_gain;
		det_ridge = det.w * dfade;
	}

	vec2 s_uv = coarse_slope + det_slope;
	vec3 n_ws = normalize(vec3(-s_uv.x * hscale / world_size, 1.0, -s_uv.y * hscale / world_size));

	vec4 cover = cover_at(v_uv);
	vec3 macro_n = n_ws;
	vec3 terr = vec3(0.0);
	float land_roughness = 0.92;
	bool canopy_full = canopy_amount >= 0.9999;
	float breakup = vnoise(wp * 0.9) * 0.6 + vnoise(wp * 3.7) * 0.4;
	if (!canopy_full) {
		float vegetation = clamp(surface.r, 0.0, 1.0);
		float rock = clamp(surface.g, 0.0, 1.0);
		float cold = clamp(surface.b, 0.0, 1.0);
		float lith = surface.a * 2.0 - 1.0;
		float scree = clamp(cover.r, 0.0, 1.0);
		float ice_share = clamp(cover.g, 0.0, 1.0);
		float raw = clamp(cover.b, 0.0, 1.0);
		float valley = clamp(cover.a, 0.0, 1.0);
		float cavity = hval > sea_level + 0.012 ? relief_cavity(relief) : 0.0;
		float slid = rock * clamp(-cavity, 0.0, 1.0) * material_gully_scree_share;
		rock -= slid;
		scree += slid;
		float bare_rest = max(0.0, 1.0 - (vegetation + rock + cold + scree + raw));
		rock += min(bare_rest, rock * clamp(cavity, 0.0, 1.0) * material_ridge_rock_gain);
		float rock_cell = rock;
		float scree_cell = scree;
		float n_mix = (breakup - 0.5) * 1.8;
		if (cold > 0.002) {
			float lie = cold * 1.45 + n_mix * material_snow_breakup - cavity * material_snow_cavity
			          - calib_window(material_snow_slope_lo, material_snow_slope_hi, world_slope);
			float ice_part = cold * ice_share;
			float snow_part = cold - ice_part;
			float snow_lie = mix(snow_part, smoothstep(0.30, 0.62, lie) * (1.0 - ice_share),
			                     calib_window(0.002, material_redistribute_fade, cold));
			rock += max(snow_part - snow_lie, 0.0);
			cold = ice_part + snow_lie;
			ice_share = cold > 1e-4 ? ice_part / cold : ice_share;
		}
		float pair = rock + vegetation;
		if (rock > 0.005) {
			float t = rock / pair + (n_mix + cavity * 0.5) * material_rock_fray;
			float rock_fray = mix(rock, pair * smoothstep(0.25, 0.75, t),
			                      calib_window(0.005, material_redistribute_fade, rock));
			vegetation = pair - rock_fray;
			rock = rock_fray;
		}
		float steep_g = calib_window(material_outcrop_slope_lo, material_outcrop_slope_hi, world_slope);
		if (steep_g > 0.0) {
			float free_g = max(0.0, 1.0 - (vegetation + rock + cold + scree + raw));
			float crag = steep_g * material_outcrop * smoothstep(0.15, 0.55, cavity + n_mix * 0.35);
			float streak = steep_g * material_scree_streak * smoothstep(0.25, 0.7, -cavity + n_mix * 0.2);
			rock += (vegetation + free_g) * crag;
			vegetation *= 1.0 - crag;
			scree += vegetation * streak;
			vegetation *= 1.0 - streak;
		}
		if (amplify_enabled) {
			amplify_material(amp_maps, steep_g, vegetation, rock, scree);
		}

		float material_fade = material_enabled
		                    ? 1.0 - smoothstep(65.0 * ws, 210.0 * ws, view_dist)
		                    : 0.0;
		float tri_large = 0.5;
		float top_large = 0.5;
		float top_grain = 0.5;
		float wind_snow = 0.5;
		if (material_enabled) {
			tri_large = triplanar_fbm(material_pos * 0.19, n_ws);
			top_large = fbm(wp * 0.16);
			if (material_fade > 0.002) {
				top_grain = fbm(wp * 0.72 + vec2(31.0, 11.0));
				wind_snow = fbm(wp * vec2(0.25, 0.55) + vec2(4.0, 19.0));
			}
		}

		vec3 soil_color = vec3(0.25, 0.20, 0.14)
		                * mix(0.82, 1.12, top_large)
		                * mix(0.93, 1.07, top_grain * material_fade);
		vec3 lush_color = vec3(0.17, 0.35, 0.06)
		                * mix(0.85, 1.10, top_large)
		                * mix(0.92, 1.08, top_grain * material_fade);
		vec3 vegetation_color = vec3(0.08, 0.23, 0.06)
		                      * mix(0.76, 1.15, top_large)
		                      * mix(0.90, 1.08, top_grain * material_fade);
		vegetation_color = mix(vegetation_color, lush_color * 0.85, valley * 0.6);
		vec3 dry_grass = vec3(0.17, 0.23, 0.08)
		               * mix(0.82, 1.12, top_large)
		               * mix(0.92, 1.08, top_grain * material_fade);
		vec3 stony = vec3(0.17, 0.167, 0.16)
		           * mix(0.86, 1.10, tri_large)
		           * mix(0.90, 1.10, mix(0.5, top_grain, material_fade));
		vec3 ground_color = mix(dry_grass, stony, smoothstep(veg_alt_lo, veg_alt_hi, hval));
		ground_color = mix(ground_color, lush_color, valley * 0.7);

		float lith_contrast = mix(1.09, 0.82, lith * 0.5 + 0.5);
		vec3 rock_bump = vec3(0.0);
		vec3 rock_scan = vec3(1.0);
		float rock_rough = 0.68;
		float rock_h = 0.5;
		vec3 sw = scan_weights(n_ws);
		if (material_enabled && rock_cell > 0.01) {
			ScanSample big = scan_triplanar(SCAN_ROCK_BEDDED, material_pos, sw, dpdx, dpdy, SCAN_ROCK_TILE);
			rock_scan = big.albedo;
			rock_bump = big.bump;
			rock_rough = big.rough;
			rock_h = big.height;
			float detail_w = (1.0 - smoothstep(0.004, 0.012, px_mat)) * (0.55 - 0.25 * lith);
			if (detail_w > 0.02) {
				ScanSample fine = scan_triplanar(SCAN_ROCK_JOINTED, material_pos, sw, dpdx, dpdy, SCAN_ROCK_DETAIL_TILE);
				rock_scan *= mix(vec3(1.0), fine.albedo, detail_w);
				rock_bump += fine.bump * detail_w;
				rock_h = mix(rock_h, fine.height, detail_w * 0.5);
			}
			float wall = 1.0 - sw.y;
			float bed_joint;
			float strata = scan_strata(material_pos, lith, px_mat, bed_joint) * wall;
			bed_joint *= wall;
			rock_scan *= (1.0 + strata * SCAN_STRATA_TONE) * (1.0 - bed_joint * 0.35);
			rock_bump = rock_bump * SCAN_ROCK_NORMAL + vec3(0.0, -bed_joint * 0.8, 0.0);
			rock_bump -= n_ws * dot(rock_bump, n_ws);
		}
		vec3 rock_color = mix(vec3(0.06, 0.064, 0.072), vec3(0.16, 0.158, 0.155), smoothstep(0.30, 0.70, tri_large))
		                * mix(1.0, lith_contrast, 0.5 * rock)
		                * rock_scan;
		vec3 scree_scan = vec3(1.0);
		vec3 scree_bump = vec3(0.0);
		if (material_enabled && scree_cell > 0.01) {
			ScanSample sc = scan_triplanar(SCAN_SCREE, material_pos, sw, dpdx, dpdy, SCAN_SCREE_TILE);
			scree_scan = sc.albedo;
			scree_bump = sc.bump * SCAN_GROUND_NORMAL;
			scree_bump -= n_ws * dot(scree_bump, n_ws);
			float rs = rock + scree;
			if (rock > 0.01 && rs > 0.02) {
				float t = scan_height_blend(rock_h, sc.height, scree / rs, 3.0);
				rock = rs * (1.0 - t);
				scree = rs * t;
			}
		}
		vec3 scree_color = vec3(0.22, 0.215, 0.20) * mix(0.90, 1.06, tri_large) * scree_scan;

		vec3 snow_color = vec3(0.79, 0.84, 0.89)
		                * mix(0.91, 1.05, wind_snow * material_fade);
		vec3 ice_color = vec3(0.56, 0.70, 0.80) * mix(0.94, 1.04, tri_large);
		vec3 cold_color = mix(snow_color, ice_color, ice_share);
		float ice_w = cold * ice_share;
		if (material_enabled && ice_w > 0.01) {
			vec2 fall = length(coarse_slope) > 1e-5 ? -normalize(coarse_slope) : vec2(0.0, 1.0);
			float crack = crevasses(wp, fall, px_wp)
			            * calib_window(material_crevasse_slope_lo, material_crevasse_slope_hi, world_slope);
			cold_color = mix(cold_color, vec3(0.16, 0.26, 0.38), crack * ice_share * 0.85);
			float margin = calib_window(0.0, material_moraine_lo, cold)
			             * (1.0 - calib_window(material_moraine_lo, material_moraine_hi, cold));
			vec2 side = vec2(-fall.y, fall.x);
			float medial = smoothstep(0.62, 0.80, vnoise(vec2(dot(wp, side) * 1.3, dot(wp, fall) * 0.12)));
			float moraine = clamp(margin + medial * 0.6, 0.0, 1.0) * ice_share;
			cold_color = mix(cold_color, vec3(0.30, 0.29, 0.27) * mix(0.85, 1.1, top_grain), moraine * 0.85);
		}

		float cover_w = vegetation + rock + cold + scree + raw;
		float soil_w = max(0.0, 1.0 - cover_w);
		float meadow_w = calib_window(canopy_meadow_lo, canopy_meadow_hi, vegetation)
		               * canopy_meadow_share * soil_w;
		vec3 meadow_color = vec3(0.13, 0.26, 0.06)
		                  * mix(0.82, 1.12, top_large)
		                  * mix(0.92, 1.08, top_grain * material_fade);
		meadow_color = mix(meadow_color, lush_color, valley);
		terr = (ground_color * (soil_w - meadow_w) + meadow_color * meadow_w
		          + soil_color * raw + rock_color * rock + scree_color * scree
		          + vegetation_color * vegetation + cold_color * cold)
		          / max(0.001, soil_w + cover_w);
		terr = mix(terr, macro_color, 0.28 * (1.0 - 0.6 * rock));
		float salt_hint = smoothstep(0.48, 0.72, macro_color.r)
		                * smoothstep(0.04, 0.12, macro_color.r - macro_color.b)
		                * (1.0 - cold) * (1.0 - vegetation);
		terr = mix(terr, macro_color, salt_hint * 0.72);
		if (hval <= sea_level) {
			terr = macro_color;
		}
		n_ws = normalize(n_ws + rock_bump * rock + scree_bump * scree);
		if (material_fade > 0.002 && hval > sea_level + 0.012) {
			vec3 micro_pos = material_pos * 2.8;
			vec3 micro = vec3(vnoise(micro_pos.xy + vec2(5.0, 17.0)),
			                  vnoise(micro_pos.yz + vec2(23.0, 3.0)),
			                  vnoise(micro_pos.xz + vec2(13.0, 31.0))) - vec3(0.5);
			micro -= n_ws * dot(micro, n_ws);
			float micro_strength = mix(0.055, 0.02, rock + scree) * mix(1.0, 0.45, cold);
			n_ws = normalize(n_ws + micro * micro_strength * material_fade);
		}
		terr *= 1.0 + min(det_shade, 0.0) * relief_detail_shade
		      + max(det_shade, 0.0) * relief_detail_shade * 0.3;
		float crease = clamp(-det_ridge, 0.0, 1.0);
		float moist = crease * (1.0 - smoothstep(veg_alt_lo, veg_alt_hi, hval));
		terr = mix(terr, terr * vec3(0.60, 0.70, 0.58) + vec3(0.0, 0.02, 0.0),
		           moist * 0.32);
		terr *= 0.96 + 0.08 * breakup;
		terr *= 1.0 + (cavity < 0.0 ? cavity * relief_shade_dark : cavity * relief_shade_light);
		float green_w = (1.0 - rock - scree) * (1.0 - cold);
		terr = mix(terr, terr * vec3(1.16, 1.10, 0.78), clamp(cavity, 0.0, 1.0) * 0.8 * green_w);
		terr = mix(terr, terr * vec3(0.72, 0.88, 0.66), clamp(-cavity, 0.0, 1.0) * 0.8 * green_w);
		terr *= 1.0 + cavity * 0.45 * rock;

		land_roughness = mix(0.90, rock_rough, rock);
		land_roughness = mix(land_roughness, 0.95, scree);
		land_roughness = mix(land_roughness, 0.84, vegetation);
		land_roughness = mix(land_roughness, 0.78, cold);
		land_roughness = mix(land_roughness, 0.34, ice_w);
		land_roughness += (top_grain - 0.5) * 0.08 * material_fade;
		float sand = macro_rgba.a;
		if (sand > 0.002) {
			float shore = hval - sea_level;
			vec3 sand_col = mix(water_bar_sand_wet_color, water_bar_sand_color, breakup);
			float beach = 1.0 - calib_window(water_beach_height_hi - water_beach_blend_height,
			                                 water_beach_height_hi, shore);
			if (beach > 0.0) {
				float dry = smoothstep(water_beach_wet_height, 2.0 * water_beach_wet_height + 1e-6, shore);
				float beach_sand = mix(calib_window(0.0, water_beach_edge_lo, sand),
				                       calib_window(water_beach_edge_lo, water_beach_edge_hi, sand),
				                       dry);
				sand = mix(sand, beach_sand, beach);
				sand_col = mix(sand_col, mix(water_beach_wet_color, water_beach_dry_color, dry), beach);
			}
			ScanSample sa;
			sa.albedo = vec3(1.0); sa.bump = vec3(0.0); sa.rough = 0.0; sa.height = 0.5;
			if (material_enabled) {
				sa = scan_top(SCAN_SAND, wp, dpdx, dpdy, SCAN_SAND_TILE);
			}
			if (material_enabled && beach < 0.98) {
				ScanSample gr = scan_top(SCAN_GRAVEL, wp, dpdx, dpdy, SCAN_GRAVEL_TILE);
				float t = scan_height_blend(gr.height, sa.height, beach, 3.0);
				sa.albedo = mix(gr.albedo, sa.albedo, t);
				sa.bump = mix(gr.bump, sa.bump, t);
			}
			sand_col *= sa.albedo;
			terr = mix(terr, sand_col, sand);
			land_roughness = mix(land_roughness, water_bar_roughness, sand);
			n_ws = normalize(n_ws + (sa.bump - n_ws * dot(sa.bump, n_ws)) * SCAN_GROUND_NORMAL * sand);
		}
	}
	if (canopy_full) {
		terr = canopy_col;
		n_ws = normalize(macro_n + vec3(canopy_tilt.x, 0.0, canopy_tilt.y));
		land_roughness = 0.92;
	} else if (canopy_amount > 0.0) {
		terr = mix(terr, canopy_col, canopy_amount);
		n_ws = normalize(mix(n_ws, normalize(macro_n + vec3(canopy_tilt.x, 0.0, canopy_tilt.y)), canopy_amount));
		land_roughness = mix(land_roughness, 0.92, canopy_amount);
	}
#ifdef FLUSSTAL_STUDY
	study_debug_view(v_uv, v_forest, terr);
#endif
	NORMAL = normalize(mat3(VIEW_MATRIX) * n_ws);

	if (debug_difference) {
		terr = texture(debug_difference_tex, v_uv).rgb;
		land_roughness = 0.9;
	}

	vec4 w = water_at(v_uv);
	float stream = w.r * (1.0 - calib_window(water_wall_slope_lo, water_wall_slope_hi, world_slope));
	float lake_gate = w.g;
	float riverMask = calib_window(water_river_mask_lo, water_river_mask_hi, stream);
	float pond = pond_at(v_uv, hval);
	float lakeMask = calib_window(water_pond_contour_lo, water_pond_contour_hi, pond)
	               * calib_window(water_lake_gate_lo, water_lake_gate_hi, lake_gate);
	float wet = max(riverMask, lakeMask);

	float dry = 1.0 - calib_window(water_pond_contour_lo, water_pond_contour_hi, pond);
	float shore = calib_window(water_shore_lo, water_shore_hi, max(stream, lake_gate)) * (1.0 - wet) * dry;
	terr = mix(terr, vec3(0.045, 0.085, 0.035), shore * 0.8);
	land_roughness = mix(land_roughness, 0.36, shore * 0.55);

	float ripple_px = 1.0 - smoothstep(0.2, 0.8, px_wp * 3.1);
	vec3 albedo = terr;
	float roughness = land_roughness;
	float specular = 0.5;
	if (wet > 0.0) {
		vec2 dir = w.ba * 2.0 - 1.0;
		vec3 river_gravel = mix(vec3(0.33, 0.30, 0.26), vec3(0.46, 0.42, 0.36), breakup);
		river_gravel *= mix(0.85, 1.15, vnoise(wp * 4.5));
		terr = mix(terr, river_gravel, riverMask * 0.88);

		float lake_depth = clamp((pond - water_lake_depth_lo) / max(water_lake_depth_span, 1e-6), 0.0, 1.0) * lakeMask;
		float depth = clamp(max(lake_depth, calib_window(water_river_depth_lo, water_river_depth_hi, stream)), 0.0, 1.0);
		float flowing = riverMask >= lakeMask ? 1.0 : 0.0;
		float steep = calib_window(water_raster_steep_lo, water_raster_steep_hi, world_slope) * flowing;
		depth *= mix(1.0, water_riffle_depth, steep);
		float speed = mix(0.25, 1.0 + steep, flowing);
		vec2 d1 = normalize(length(dir) > 0.05 ? dir : vec2(0.7, 0.7));
		float ripple_fade = 1.0 - smoothstep(50.0 * ws, 160.0 * ws, view_dist);
		float flow_t = u_time * 0.35 * speed;
		float ph0 = fract(flow_t);
		float ph1 = fract(flow_t + 0.5);
		float w0 = 1.0 - abs(ph0 * 2.0 - 1.0);
		vec2 rp0 = wp * 3.1 - d1 * ph0 * 1.6;
		vec2 rp1 = wp * 3.1 - d1 * ph1 * 1.6 + vec2(5.2, 1.3);
		float re = 0.08;
		float r0 = vnoise(rp0), r1 = vnoise(rp1);
		vec2 g0 = vec2(vnoise(rp0 + vec2(re, 0.0)) - r0, vnoise(rp0 + vec2(0.0, re)) - r0) / re;
		vec2 g1 = vec2(vnoise(rp1 + vec2(re, 0.0)) - r1, vnoise(rp1 + vec2(0.0, re)) - r1) / re;
		float amp = mix(0.015, 0.05, max(depth, steep)) * ripple_fade * ripple_px;
		amp *= riverMask >= lakeMask ? 1.0 : 0.45;
		vec2 grad = (g0 * w0 + g1 * (1.0 - w0)) * amp * 2.0;
		vec3 water_n_ws = normalize(vec3(-grad.x, 1.0, -grad.y));
		vec3 water_n_vs = normalize(mat3(VIEW_MATRIX) * water_n_ws);
		NORMAL = normalize(mix(NORMAL, water_n_vs, wet));

		vec3 water = mix(water_shallow_color, water_deep_color, depth);
		water = mix(water, water_lake_color, (1.0 - flowing) * smoothstep(0.2, 0.9, depth));
		vec3 bed = mix(terr * 0.55, water_bed_color, 0.75 * wet);
		float opacity = mix(water_opacity_shallow, water_opacity_deep, depth);
		float ndv = clamp(dot(water_n_vs, VIEW), 0.0, 1.0);
		float fresnel = pow(1.0 - ndv, max(water_fresnel_exponent, 1e-6));

		if (riverMask >= lakeMask && length(dir) > 0.05) {
			float flow = (vnoise(rp0 * 0.45) * w0 + vnoise(rp1 * 0.45) * (1.0 - w0)) * 2.0 - 1.0;
			water += flow * water_flow_shimmer_color;
		}

		float foam_n = vnoise(wp * 4.0 - d1 * u_time * 1.5);
		float foam = smoothstep(1.0 - 0.55 * steep, 1.06 - 0.55 * steep, foam_n) * steep * water_foam_amount;
		water = mix(water, water_riffle_color, steep * smoothstep(0.3, 0.7, foam_n));
		vec3 water_final = mix(bed, water, opacity);
		water_final *= 1.0 - fresnel;
		water_final = mix(water_final, water_foam_color, foam);
		albedo = mix(terr, water_final, wet);
		roughness = mix(land_roughness, mix(water_roughness, 0.7, foam), wet);
		specular = mix(0.5, mix(water_specular, water_river_specular, flowing * (1.0 - foam)), wet);
		vec3 view_ws = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
		vec3 refl = reflect(-view_ws, water_n_ws);
		vec3 lake_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float cloud_w = water_cloud_reflection * lakeMask * (1.0 - flowing);
		float cloud_hit = clouds_enabled && cloud_w > 0.0 && refl.y > 0.05 && lake_pos.y < cloud_height
			? cloud_cover(lake_pos.xz + refl.xz * (cloud_height - lake_pos.y) / refl.y, u_time) : 0.0;
		EMISSION = vec3(0.9, 0.93, 0.97) * cloud_hit * cloud_w * (0.35 + 0.65 * fresnel);
	}
	ALBEDO = albedo;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = specular;
	if (amplify_debug > 0) {
		ALBEDO = amplify_debug_color(amp_maps, relief.r);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	}
	vec3 shadow_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ALBEDO *= cloud_light(shadow_pos, u_time);
}

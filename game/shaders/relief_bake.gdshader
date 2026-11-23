shader_type canvas_item;
render_mode blend_disabled;

#include "res://shaders/erosion_filter.gdshaderinc"

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D protect_tex : filter_linear, repeat_disable;
uniform float grid_n;
uniform float hscale;
uniform float sea_level;
uniform float relief_scale;
uniform float relief_strength;
uniform float relief_sharpen;
uniform float relief_sharpen_radius;
uniform float relief_height_code;
uniform float relief_slope_code;
uniform float relief_cavity_gully_gain;
uniform float relief_cavity_ridge_gain;
uniform float relief_ridge_cap;
uniform float world_size;
uniform float relief_rib_scale;
uniform float relief_rib_strength;
uniform float relief_rib_slope_lo;
uniform float relief_rib_slope_hi;
uniform float relief_rib_floor;
uniform float relief_cavity_rib_gain;
uniform float relief_bench_spacing;
uniform float relief_bench_relief;
uniform float relief_cavity_bench_gain;

#include "res://shaders/protect.gdshaderinc"

float ridge_at(vec2 uv) {
	float r = relief_sharpen_radius / grid_n;
	float d = r * 0.7071;
	float h = texture(height_tex, uv).r;
	float ring = texture(height_tex, uv + vec2(r, 0.0)).r + texture(height_tex, uv - vec2(r, 0.0)).r
	           + texture(height_tex, uv + vec2(0.0, r)).r + texture(height_tex, uv - vec2(0.0, r)).r
	           + texture(height_tex, uv + vec2(d, d)).r + texture(height_tex, uv - vec2(d, d)).r
	           + texture(height_tex, uv + vec2(d, -d)).r + texture(height_tex, uv - vec2(d, -d)).r;
	float cap = relief_ridge_cap / hscale;
	return cap * tanh(max(h - ring * 0.125, 0.0) * relief_sharpen / cap);
}

void fragment() {
	vec2 uv = UV;
	float h = texture(height_tex, uv).r;
	float texel = 1.0 / grid_n;
	vec2 slope = vec2(texture(height_tex, uv + vec2(texel, 0.0)).r - texture(height_tex, uv - vec2(texel, 0.0)).r,
	                  texture(height_tex, uv + vec2(0.0, texel)).r - texture(height_tex, uv - vec2(0.0, texel)).r)
	           * 0.5 * grid_n;
	float w = (1.0 - protect_at(uv)) * smoothstep(sea_level + 0.008, sea_level + 0.04, h);
	vec4 relief = vec4(0.0);
	if (w > 0.001) {
		float fade_target = clamp((h - sea_level) / 0.6 * 2.0 - 1.0, -1.0, 1.0);
		float mag;
		vec4 det = erosion_detail_at(uv, slope, fade_target, relief_scale,
		                             relief_strength, 3, mag);
		float e = texel;
		vec2 ridge_slope = vec2(ridge_at(uv + vec2(e, 0.0)) - ridge_at(uv - vec2(e, 0.0)),
		                        ridge_at(uv + vec2(0.0, e)) - ridge_at(uv - vec2(0.0, e)))
		                 / (2.0 * e);
		float ridge = ridge_at(uv);
		float wslope = length(slope) * hscale / max(world_size, 1e-6);
		float steep = mix(relief_rib_floor, 1.0,
		                  smoothstep(relief_rib_slope_lo, max(relief_rib_slope_hi, relief_rib_slope_lo + 1e-6), wslope));
		float rib_mag;
		vec4 rib = erosion_detail_at(uv + vec2(0.37, 0.61), slope, fade_target, relief_rib_scale,
		                             relief_rib_strength, 3, rib_mag);
		rib.xyz *= steep;
		float bench_w = clamp((steep - relief_rib_floor) / max(1.0 - relief_rib_floor, 1e-6), 0.0, 1.0);
		float bp = fract(h * hscale / max(relief_bench_spacing, 1e-6) + rib.x / rib_mag * 0.35
		                 + det.x / mag * 0.25);
		float riser = smoothstep(0.70, 0.86, bp) * (1.0 - smoothstep(0.94, 1.0, bp));
		vec2 bench_slope = slope * (riser * 4.0 - 0.75) * relief_bench_relief * bench_w;
		relief = vec4((det.x + rib.x + ridge) * hscale, det.yz + rib.yz + ridge_slope + bench_slope,
		              clamp(det.x / mag * relief_cavity_gully_gain + rib.x / rib_mag * relief_cavity_rib_gain
		                    + ridge * relief_cavity_ridge_gain - riser * bench_w * relief_cavity_bench_gain,
		                    -1.0, 1.0)) * w;
	}
	COLOR = vec4(relief.x * relief_height_code + 0.5, relief.yz * relief_slope_code + 0.5,
	             relief.w * 0.5 + 0.5);
}

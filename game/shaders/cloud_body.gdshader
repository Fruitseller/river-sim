shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

#include "res://shaders/clouds.gdshaderinc"

uniform float u_time = 0.0;
uniform sampler2D height_tex : filter_linear, repeat_disable, hint_default_black;
uniform float world_size;
uniform float grid_n;
uniform float hscale;
uniform float cloud_body_layer;
uniform float cloud_body_opacity;
uniform float cloud_body_lift;
uniform float cloud_body_self_shadow_dist;
uniform float cloud_body_self_shadow_gain;
uniform float cloud_body_ridge_lo;
uniform float cloud_body_ridge_hi;
uniform vec3 cloud_body_sun;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 xz = v_world.xz;
	float n = max(grid_n, 2.0);
	vec2 uv = ((xz / max(world_size, 1e-4) + 0.5) * (n - 1.0) + 0.5) / n;
	float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
	float ground = textureLod(height_tex, clamp(uv, vec2(0.0), vec2(1.0)), 0.0).r * hscale;
	float ridge = smoothstep(cloud_body_ridge_lo, max(cloud_body_ridge_hi, cloud_body_ridge_lo + 1e-4), ground)
	            * inside;
	if (ridge <= 0.0) {
		discard;
	}
	float density = cloud_density(xz, u_time);
	float lift = cloud_body_layer * cloud_body_lift;
	float cover = cloud_cover_at(xz, u_time, lift);
	float alpha = cover * ridge * cloud_body_opacity;
	if (alpha < 0.003) {
		discard;
	}
	vec2 sun_xz = length(cloud_body_sun.xz) > 1e-4 ? normalize(cloud_body_sun.xz) : vec2(0.0);
	float toward = cloud_density(xz + sun_xz * cloud_body_self_shadow_dist, u_time);
	float lit = clamp(0.75 + (density - toward) * cloud_body_self_shadow_gain
	                + cloud_body_layer * 0.2, 0.0, 1.0);
	ALBEDO = mix(vec3(0.60, 0.64, 0.70), vec3(1.0, 0.98, 0.95), lit);
	ALPHA = alpha;
}

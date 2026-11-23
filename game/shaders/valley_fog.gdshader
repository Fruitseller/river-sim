shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform sampler2D height_tex : filter_linear, repeat_disable, hint_default_black;
uniform float world_size;
uniform float grid_n;
uniform float hscale;
uniform float sea_y;
uniform float u_time;
uniform float fog_layer;
uniform float fog_strength;
uniform vec3 fog_color;
uniform float fog_ref_dist;

const float ABOVE_FLOOR = 1.2;
const float ABOVE_SEA = 0.55;
const float LAYER_STEP = 0.35;
const float THICK_FULL = 1.8;
const float SEA_OPACITY = 0.35;
const float LAND_OPACITY = 0.4;
const float SMOOTH_TEXELS = 11.0;

const float EDGE_FADE_LO = 0.55;
const float EDGE_FADE_HI = 0.78;

varying vec3 v_world;
varying float v_sea;

vec2 world_uv(vec2 xz) {
	float n = max(grid_n, 2.0);
	return ((xz / max(world_size, 1e-4) + 0.5) * (n - 1.0) + 0.5) / n;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
	           mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 uv = world_uv(w.xz);
	float lo = 1e9;
	float texel = SMOOTH_TEXELS / max(grid_n, 2.0);
	for (int j = -2; j <= 2; j++) {
		for (int i = -2; i <= 2; i++) {
			vec2 t = uv + vec2(float(i), float(j)) * texel;
			vec2 q = clamp(t, vec2(0.0), vec2(1.0));
			float in_map = step(0.0, t.x) * step(t.x, 1.0) * step(0.0, t.y) * step(t.y, 1.0);
			lo = min(lo, max(textureLod(height_tex, q, 0.0).r * hscale * in_map, sea_y));
		}
	}
	float land = smoothstep(sea_y + 0.05, sea_y + 0.6, lo);
	v_sea = 1.0 - land;
	float base = mix(sea_y + ABOVE_SEA, lo + ABOVE_FLOOR, land);
	w.y = base + fog_layer * LAYER_STEP;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(w, 1.0)).xyz;
	v_world = w;
}

void fragment() {
	if (fog_strength <= 0.001) {
		discard;
	}
	vec2 uv = world_uv(v_world.xz);
	float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
	float ground = max(textureLod(height_tex, clamp(uv, vec2(0.0), vec2(1.0)), 0.0).r * hscale * inside, sea_y);
	float thick = v_world.y - ground;
	float cover = smoothstep(0.0, THICK_FULL * (1.0 + fog_layer), thick);
	cover *= cover;
	if (cover <= 0.0) {
		discard;
	}
	vec2 p = v_world.xz * 0.12 + vec2(u_time * 0.004, u_time * 0.0025);
	float n = noise(p) * 0.65 + noise(p * 2.7 + 5.0) * 0.35;
	float wisps = smoothstep(0.32 + fog_layer * 0.2, 0.78 + fog_layer * 0.1, n);
	float opacity = mix(LAND_OPACITY, SEA_OPACITY, v_sea);
	float d = length(VERTEX);
	float near = smoothstep(6.0, 22.0, d);
	float ref = max(fog_ref_dist, 1.0);
	near *= mix(0.35, 1.0, smoothstep(ref * 0.75, ref * 1.35, d));
	float edge = max(abs(v_world.x), abs(v_world.z)) / max(world_size, 1e-4);
	near *= 1.0 - smoothstep(EDGE_FADE_LO, EDGE_FADE_HI, edge);
	ALPHA = cover * wisps * opacity * fog_strength * near;
	ALBEDO = fog_color;
}

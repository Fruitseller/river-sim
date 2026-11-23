uniform bool amplify_enabled = false;
uniform sampler2D amplify_tex : filter_linear_mipmap_anisotropic, repeat_disable, hint_default_black;
uniform sampler2D amplify_prev_tex : filter_linear_mipmap_anisotropic, repeat_disable, hint_default_black;
uniform float amplify_vertex_lod = 0.0;
uniform int amplify_debug = 0;

const float AMPLIFY_SCREE_FROM_ROCK = 0.75;
const float AMPLIFY_SCREE_FROM_GREEN = 0.45;
const float AMPLIFY_FAN_SHARE = 0.5;
const float AMPLIFY_CUT_ROCK = 0.9;

vec4 amplify_maps(vec2 uv, float blend) {
	if (!amplify_enabled) {
		return vec4(0.0);
	}
	vec4 cur = texture(amplify_tex, uv);
	if (blend < 1.0) {
		cur = mix(texture(amplify_prev_tex, uv), cur, blend);
	}
	return cur;
}

void amplify_material(vec4 maps, float steep, inout float vegetation, inout float rock,
		inout float scree) {
	float talus = clamp(maps.a + maps.g * AMPLIFY_FAN_SHARE, 0.0, 1.0);
	float from_rock = rock * talus * AMPLIFY_SCREE_FROM_ROCK;
	float from_green = vegetation * talus * AMPLIFY_SCREE_FROM_GREEN;
	rock -= from_rock;
	vegetation -= from_green;
	scree += from_rock + from_green;
	float cut = vegetation * maps.r * steep * AMPLIFY_CUT_ROCK;
	vegetation -= cut;
	rock += cut;
}

vec3 amplify_debug_color(vec4 maps, float lift_code) {
	if (amplify_debug == 1) {
		float v = (lift_code - 0.5) * 20.0;
		return vec3(0.5) + vec3(v, -abs(v) * 0.5, -v);
	}
	if (amplify_debug == 2) { return vec3(maps.r); }
	if (amplify_debug == 3) { return vec3(maps.g); }
	if (amplify_debug == 4) { return vec3(maps.b); }
	if (amplify_debug == 5) { return vec3(maps.a); }
	return vec3(maps.r, maps.g + maps.a * 0.5, maps.b);
}

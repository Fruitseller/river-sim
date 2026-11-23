uniform float px_scale = 1.0;

const vec3 HALO_COLOR = vec3(0.01, 0.02, 0.03);
const float HALO_ALPHA = 0.6;
const float CORE_GAIN = 1.6;
const float DEPTH_PULL = 4.0;

void vertex() {
	float half_px = (0.5 * UV.y + UV2.x) * px_scale;
	float pull = 1.0 - DEPTH_PULL * half_px / VIEWPORT_SIZE.y;
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec4 clip = PROJECTION_MATRIX * vec4(view.xyz * pull, 1.0);
	vec4 other = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(CUSTOM0.xyz, 1.0));
	vec2 a = clip.xy / max(clip.w, 1e-4) * VIEWPORT_SIZE;
	vec2 b = other.xy / max(other.w, 1e-4) * VIEWPORT_SIZE;
	vec2 dir = b - a;
	dir = length(dir) > 1e-3 ? normalize(dir) : vec2(1.0, 0.0);
	vec2 side = vec2(-dir.y, dir.x) * UV.x * CUSTOM0.w;
	clip.xy += side * half_px * 2.0 / VIEWPORT_SIZE * clip.w;
	POSITION = clip;
}

void fragment() {
	float x = abs(UV.x);
	float core = 0.5 * UV.y / (0.5 * UV.y + UV2.x);
	float aa = fwidth(UV.x);
	float in_core = 1.0 - smoothstep(core - aa, core + aa, x);
	float in_band = 1.0 - smoothstep(1.0 - aa, 1.0, x);
	ALBEDO = mix(HALO_COLOR, COLOR.rgb * CORE_GAIN, in_core);
	ALPHA = mix(HALO_ALPHA, 1.0, in_core) * COLOR.a * in_band * PASS_ALPHA;
}

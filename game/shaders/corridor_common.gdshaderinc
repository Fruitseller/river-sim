uniform float corridor_hscale = 24.0;
uniform vec3 corridor_sun_dir = vec3(0.0, 1.0, 0.0);
uniform float corridor_viewport_h = 1080.0;

const float CORRIDOR_MIN_WATER_PX = 5.0;
const float CORRIDOR_MAX_WIDEN = 3.5;
const float CORRIDOR_DEPTH_KEEP = 0.08;
const float CORRIDOR_DEPTH_KEEP_MAX = 0.008;
const float CORRIDOR_LID_REACH = 3.0;
const float CORRIDOR_LID_CLEAR = 0.02;

vec2 corridor_grid_uv(vec2 xz) {
	float n = max(grid_n, 2.0);
	return ((xz / world_size + 0.5) * (n - 1.0) + 0.5) / n;
}

float corridor_terrain_y(vec2 xz) {
	vec2 uv = corridor_grid_uv(xz);
	float h = textureLod(height_tex, uv, 0.0).r;
	if (height_blend < 1.0) {
		h = mix(textureLod(height_prev_tex, uv, 0.0).r, h, height_blend);
	}
	return h * corridor_hscale;
}

float corridor_widen(vec3 p, float water_half, float presence, vec3 cam, mat4 proj) {
	float dist = length(cam - p);
	float px = 2.0 * dist / max(abs(proj[1][1]) * corridor_viewport_h, 1e-4);
	float f = clamp(CORRIDOR_MIN_WATER_PX * px / max(2.0 * water_half, 1e-4), 1.0, CORRIDOR_MAX_WIDEN);
	return mix(1.0, f, smoothstep(0.1, 0.5, presence));
}

float corridor_widened_offset(float off, float water_half, float f) {
	return off + sign(off) * min(abs(off), water_half) * (f - 1.0);
}

vec3 corridor_lid_point(vec3 p, float lid, vec3 cam) {
	vec3 d = p - cam;
	if (cam.y > lid && p.y < lid && abs(d.y) > 1e-6) {
		float t = (lid - cam.y) / d.y;
		float reach = CORRIDOR_LID_REACH * (lid - p.y) / max(length(d), 1e-6);
		return cam + d * max(t, 1.0 - reach);
	}
	return p;
}

vec4 corridor_clip(vec3 p, float lid, vec3 cam, mat4 view, mat4 proj) {
	vec4 clip = proj * (view * vec4(p, 1.0));
	vec3 pl = corridor_lid_point(p, lid, cam);
	float below = max(pl.y - p.y, 1e-6);
	float off = CORRIDOR_DEPTH_KEEP_MAX * (1.0 - exp(-CORRIDOR_DEPTH_KEEP * below / CORRIDOR_DEPTH_KEEP_MAX));
	vec3 q = mix(pl, p, off / below);
	vec4 lid_clip = proj * (view * vec4(q, 1.0));
	return vec4(clip.xy, lid_clip.z / lid_clip.w * clip.w, clip.w);
}

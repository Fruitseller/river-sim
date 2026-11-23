uniform bool clouds_enabled;
uniform float cloud_strength;
uniform float cloud_scale;
uniform float cloud_height;
uniform vec2 cloud_sun_shift;
uniform float cloud_base_fade;

float cloud_hash(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	p += dot(p, p + 19.19);
	return fract(p.x * p.y);
}

float cloud_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(cloud_hash(i), cloud_hash(i + vec2(1.0, 0.0)), u.x),
	           mix(cloud_hash(i + vec2(0.0, 1.0)), cloud_hash(i + vec2(1.0)), u.x), u.y);
}

float cloud_density(vec2 world_xz, float t) {
	vec2 q = world_xz * cloud_scale + vec2(t * 0.010, t * 0.004);
	return cloud_noise(q) * 0.55 + cloud_noise(q * 2.1 + 7.3) * 0.3
	     + cloud_noise(q * 4.7 + 3.1) * 0.15;
}

const float CLOUD_COVER_LO = 0.56;
const float CLOUD_COVER_HI = 0.70;

float cloud_cover_at(vec2 world_xz, float t, float lift) {
	return smoothstep(CLOUD_COVER_LO + lift, CLOUD_COVER_HI + lift, cloud_density(world_xz, t));
}

float cloud_cover(vec2 world_xz, float t) {
	return cloud_cover_at(world_xz, t, 0.0);
}

float cloud_light(vec3 world_pos, float t) {
	if (!clouds_enabled || world_pos.y >= cloud_height) {
		return 1.0;
	}
	float fade = 1.0 - smoothstep(cloud_height - cloud_base_fade, cloud_height, world_pos.y);
	vec2 at = world_pos.xz + cloud_sun_shift * (cloud_height - world_pos.y);
	return 1.0 - cloud_cover(at, t) * cloud_strength * fade;
}

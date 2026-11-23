uniform sampler2DArray scan_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray scan_normal : filter_linear_mipmap_anisotropic, repeat_enable;

const float SCAN_ROCK_BEDDED = 0.0;
const float SCAN_ROCK_JOINTED = 1.0;
const float SCAN_SCREE = 2.0;
const float SCAN_GRAVEL = 3.0;
const float SCAN_SAND = 4.0;
const float SCAN_ALBEDO_MEAN = 0.18;

const float SCAN_ROCK_TILE = 1.6;
const float SCAN_ROCK_DETAIL_TILE = 0.28;
const float SCAN_SCREE_TILE = 0.55;
const float SCAN_GRAVEL_TILE = 0.30;
const float SCAN_SAND_TILE = 0.45;
const float SCAN_ROCK_NORMAL = 2.2;
const float SCAN_GROUND_NORMAL = 0.7;

const float SCAN_STRATA_SPACING = 0.35;
const float SCAN_STRATA_WARP = 0.25;
const float SCAN_STRATA_TONE = 0.45;

struct ScanSample {
	vec3 albedo;
	vec3 bump;
	float rough;
	float height;
};

vec3 scan_weights(vec3 n) {
	vec3 w = pow(abs(n), vec3(6.0));
	w /= max(w.x + w.y + w.z, 1e-4);
	w = max(w - 0.03, 0.0);
	return w / max(w.x + w.y + w.z, 1e-4);
}

void scan_fetch(float layer, vec2 uv, vec2 gx, vec2 gy, float w, inout vec4 alb, inout vec4 nrm) {
	alb += textureGrad(scan_albedo, vec3(uv, layer), gx, gy) * w;
	nrm += textureGrad(scan_normal, vec3(uv, layer), gx, gy) * w;
}

ScanSample scan_triplanar(float layer, vec3 p, vec3 w, vec3 dpdx, vec3 dpdy, float tile) {
	float s = 1.0 / tile;
	vec4 a = vec4(0.0);
	vec3 bump = vec3(0.0);
	float rough = 0.0;
	if (w.x > 0.0) {
		vec4 al = vec4(0.0), nr = vec4(0.0);
		vec2 f = vec2(1.0, -1.0) * s;
		scan_fetch(layer, p.zy * f, dpdx.zy * f, dpdy.zy * f, 1.0, al, nr);
		vec2 t = nr.rg * 2.0 - 1.0;
		a += al * w.x; bump += vec3(0.0, t.y, t.x) * w.x; rough += nr.b * w.x;
	}
	if (w.z > 0.0) {
		vec4 al = vec4(0.0), nr = vec4(0.0);
		vec2 f = vec2(1.0, -1.0) * s;
		scan_fetch(layer, p.xy * f, dpdx.xy * f, dpdy.xy * f, 1.0, al, nr);
		vec2 t = nr.rg * 2.0 - 1.0;
		a += al * w.z; bump += vec3(t.x, t.y, 0.0) * w.z; rough += nr.b * w.z;
	}
	if (w.y > 0.0) {
		vec4 al = vec4(0.0), nr = vec4(0.0);
		scan_fetch(layer, p.xz * s, dpdx.xz * s, dpdy.xz * s, 1.0, al, nr);
		vec2 t = nr.rg * 2.0 - 1.0;
		a += al * w.y; bump += vec3(t.x, 0.0, -t.y) * w.y; rough += nr.b * w.y;
	}
	ScanSample r;
	r.albedo = a.rgb / SCAN_ALBEDO_MEAN;
	r.height = a.a;
	r.bump = bump;
	r.rough = rough;
	return r;
}

ScanSample scan_top(float layer, vec2 xz, vec3 dpdx, vec3 dpdy, float tile) {
	float s = 1.0 / tile;
	vec4 al = vec4(0.0), nr = vec4(0.0);
	scan_fetch(layer, xz * s, dpdx.xz * s, dpdy.xz * s, 1.0, al, nr);
	vec2 t = nr.rg * 2.0 - 1.0;
	ScanSample r;
	r.albedo = al.rgb / SCAN_ALBEDO_MEAN;
	r.height = al.a;
	r.bump = vec3(t.x, 0.0, -t.y);
	r.rough = nr.b;
	return r;
}

float scan_height_blend(float ha, float hb, float t, float contrast) {
	float shift = (hb - ha) * 2.0 * t * (1.0 - t);
	return clamp((t - 0.5 + shift) * contrast + 0.5, 0.0, 1.0);
}

float scan_strata(vec3 p, float lith, float px, out float joint) {
	float warp = (vnoise(p.xz * 0.45 + vec2(3.0, 11.0)) - 0.5) * SCAN_STRATA_WARP
	           + (vnoise(p.xz * 1.9 + vec2(7.0, 1.0)) - 0.5) * SCAN_STRATA_WARP * 0.25;
	float b = (p.y + warp) / (SCAN_STRATA_SPACING * (1.0 + 0.25 * lith));
	float id = floor(b);
	float f = b - id;
	float fw = px / SCAN_STRATA_SPACING;
	float detail = 1.0 - smoothstep(0.25, 0.7, fw);
	float tone = vhash(vec2(id, 17.0)) * 0.7 + (mod(id, 2.0) - 0.5) * 0.6;
	float gate = smoothstep(0.55, 0.75, vnoise(vec2(p.x * 1.7 + p.z * 1.1, id * 3.1)));
	joint = smoothstep(1.0 - 0.06 - fw, 1.0, f) * gate * detail;
	return tone * detail;
}

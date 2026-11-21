#[compute]
#version 450
// Platzierung der Einzelbäume (#236), jedes Bild auf der GPU. Schreibt nur
// die Bäume, die gerade stehen und im Bild (oder im Schattenbereich) liegen,
// in vier indirekte MultiMeshes (game/scripts/ForestTrees.gd):
//   conifer — Nadelbaum in voller Form, im Bild, näher als `lod_dist`
//   broad   — Laubbaum in voller Form, ebenso
//   far     — grobe Mischform, im Bild, weiter weg
//   shadow  — grobe Mischform, nur Schatten, näher als `shadow_range`
// Je Baum: Standort auf einem festen, verwackelten Gitter je Stufe; Höhe und
// Verschiebung wie das Gelände (terrain.gdshader, vertex()); Kartensymbol
// k(d) und Ausdünnung nach Rang; Waldmaske unter der ganzen Krone; Art nach
// Höhe und Bestands-Rauschen. Was hier nicht steht, rechnet nichts: die CPU
// schreibt keinen Transform, sie startet nur diesen Pass.
//
// Ein Durchlauf je Stufe (push constant `level` ≥ 0) über das Fenster der
// Stufe um die Kamera; danach EIN Faden mit `level` < 0, der die Zähler in
// die Kommando-Puffer der MultiMeshes schreibt (gedeckelt auf die Kapazität).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D height_tex;
layout(set = 0, binding = 1) uniform sampler2D height_prev_tex;
layout(set = 0, binding = 2) uniform sampler2D forest_tex;
layout(set = 0, binding = 3) uniform sampler2D forest_prev_tex;
layout(set = 0, binding = 4) uniform sampler2D relief_tex;
layout(set = 0, binding = 5) uniform sampler2D relief_prev_tex;
layout(set = 0, binding = 6, std430) restrict writeonly buffer ConBuf { vec4 v[]; } con_buf;
layout(set = 0, binding = 7, std430) restrict writeonly buffer BroadBuf { vec4 v[]; } broad_buf;
layout(set = 0, binding = 8, std430) restrict writeonly buffer FarBuf { vec4 v[]; } far_buf;
layout(set = 0, binding = 9, std430) restrict writeonly buffer ShadowBuf { vec4 v[]; } shadow_buf;
layout(set = 0, binding = 10, std430) restrict buffer Counts { uint n[4]; } counts;
layout(set = 0, binding = 11, std430) restrict buffer ConCmd { uint c[5]; } con_cmd;
layout(set = 0, binding = 12, std430) restrict buffer BroadCmd { uint c[5]; } broad_cmd;
layout(set = 0, binding = 13, std430) restrict buffer FarCmd { uint c[5]; } far_cmd;
layout(set = 0, binding = 14, std430) restrict buffer ShadowCmd { uint c[5]; } shadow_cmd;
layout(set = 0, binding = 15, std140) uniform Params {
	vec4 view;     // xyz Auge, w hscale
	vec4 blends;   // height_blend, overlay_blend, bake_blend, relief an (1/0)
	vec4 relief;   // relief_height_code, relief_geometry_age, sim_year, world_size
	vec4 grid;     // grid_n, conifer_lo, conifer_hi, –
	vec4 symbol;   // k_near, d_near, k_exp, k_max
	vec4 tree;     // thin_exp, tree_height, crown_reach, mask_lo
	vec4 tree2;    // mask_spread, lod_dist, shadow_range, shadow_margin
	vec4 caps;     // conifer, broad, far, shadow (Instanzen)
	vec4 planes[6]; // Frustum, Normale nach außen: xyz·p − w > 0 heißt außen
} p;

layout(push_constant, std430) uniform Level {
	ivec2 origin;  // erste Gitterzelle des Fensters
	ivec2 size;    // Fenstergröße in Zellen
	float spacing;
	float rank_lo;
	float rank_hi;
	int level;     // < 0: Zähler abschließen
} lv;

vec2 world_uv(vec2 xz) {
	float n = max(p.grid.x, 2.0);
	return ((xz / p.relief.w + 0.5) * (n - 1.0) + 0.5) / n;
}

float height_at(vec2 uv) {
	float h = textureLod(height_tex, uv, 0.0).r;
	return p.blends.x < 1.0 ? mix(textureLod(height_prev_tex, uv, 0.0).r, h, p.blends.x) : h;
}

float forest_at(vec2 uv) {
	float f = textureLod(forest_tex, uv, 0.0).r;
	return p.blends.y < 1.0 ? mix(textureLod(forest_prev_tex, uv, 0.0).r, f, p.blends.y) : f;
}

// Wie terrain.gdshader `relief_lift`.
float relief_lift(vec2 uv) {
	if (p.blends.w < 0.5) {
		return 0.0;
	}
	vec4 cur = textureLod(relief_tex, uv, 0.0);
	if (p.blends.z < 1.0) {
		cur = mix(textureLod(relief_prev_tex, uv, 0.0), cur, p.blends.z);
	}
	return (cur.r - 0.5) / max(p.relief.x, 1e-6) * smoothstep(0.0, p.relief.y, p.relief.z);
}

// pcg3d (Jarzynski & Olano 2020), vier Werte 0 … 1.
vec4 hash4(ivec2 c, uint salt) {
	uvec3 v = uvec3(uvec2(c + ivec2(65536)), salt);
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	uint w = v.x ^ v.y ^ v.z;
	return vec4(vec3(v), float(w)) / 4294967295.0;
}

// Wertrauschen wie im Terrain-Shader (`vnoise`), für Bestände.
float vhash(vec2 c) {
	const vec2 k = vec2(0.3183099, 0.3678794);
	vec2 x = fract(c * k) * 17.0 + k.yx;
	return fract(16.0 * k.x * fract(x.x * x.y * (x.x + x.y))) * 2.0 - 1.0;
}

float vnoise(vec2 q) {
	vec2 i = floor(q);
	vec2 f = fract(q);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = vhash(i);
	float b = vhash(i + vec2(1.0, 0.0));
	float c = vhash(i + vec2(0.0, 1.0));
	float d = vhash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 0.5 + 0.5;
}

// Kugel gegen das Frustum, `grow` weitet es (Schattenwerfer außerhalb).
bool in_frustum(vec3 c, float r, float grow) {
	for (int i = 0; i < 6; i++) {
		if (dot(p.planes[i].xyz, c) - p.planes[i].w > r + grow) {
			return false;
		}
	}
	return true;
}

// Instanz: 3×4-Transform zeilenweise (Godots MultiMesh-Format), dann
// INSTANCE_CUSTOM (Nadelbaum-Anteil, Laubfarbe).
void write_con(uint i, vec4 r0, vec4 r1, vec4 r2, vec4 cu) {
	con_buf.v[i * 4u] = r0; con_buf.v[i * 4u + 1u] = r1;
	con_buf.v[i * 4u + 2u] = r2; con_buf.v[i * 4u + 3u] = cu;
}
void write_broad(uint i, vec4 r0, vec4 r1, vec4 r2, vec4 cu) {
	broad_buf.v[i * 4u] = r0; broad_buf.v[i * 4u + 1u] = r1;
	broad_buf.v[i * 4u + 2u] = r2; broad_buf.v[i * 4u + 3u] = cu;
}
void write_far(uint i, vec4 r0, vec4 r1, vec4 r2, vec4 cu) {
	far_buf.v[i * 4u] = r0; far_buf.v[i * 4u + 1u] = r1;
	far_buf.v[i * 4u + 2u] = r2; far_buf.v[i * 4u + 3u] = cu;
}
void write_shadow(uint i, vec4 r0, vec4 r1, vec4 r2, vec4 cu) {
	shadow_buf.v[i * 4u] = r0; shadow_buf.v[i * 4u + 1u] = r1;
	shadow_buf.v[i * 4u + 2u] = r2; shadow_buf.v[i * 4u + 3u] = cu;
}

void main() {
	if (lv.level < 0) {
		if (gl_LocalInvocationIndex != 0u) {
			return;
		}
		con_cmd.c[1] = min(counts.n[0], uint(p.caps.x));
		broad_cmd.c[1] = min(counts.n[1], uint(p.caps.y));
		far_cmd.c[1] = min(counts.n[2], uint(p.caps.z));
		shadow_cmd.c[1] = min(counts.n[3], uint(p.caps.w));
		return;
	}
	ivec2 cell = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(cell, lv.size))) {
		return;
	}
	ivec2 g = lv.origin + cell;
	uint salt = uint(lv.level) * 7919u + 236u;
	vec4 r = hash4(g, salt);
	float world = p.relief.w;
	vec2 xz = (vec2(g) + 0.15 + r.xy * 0.7) * lv.spacing - world * 0.5;
	vec2 uv = world_uv(xz);
	if (any(lessThanEqual(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) {
		return;
	}
	// Billige Abbrüche zuerst: Rang (eine Höhe), dann die Maske in der Mitte.
	float hraw = height_at(uv);
	vec3 base = vec3(xz.x, hraw * p.view.w, xz.y);
	float d = max(distance(p.view.xyz, base), 1e-3);
	float k = clamp(p.symbol.x * pow(d / p.symbol.y, p.symbol.z), 1.0, p.symbol.w);
	float rank = mix(lv.rank_lo, lv.rank_hi, r.z);
	float vis = 1.0 - smoothstep(0.7, 1.0, rank * pow(k, p.tree.x));
	if (vis <= 0.0) {
		return;
	}
	float thr = p.tree.w + p.tree2.x * r.w;
	float f = forest_at(uv);
	if (f <= thr) {
		return;
	}
	vec4 r2 = hash4(g, salt + 1u);
	float s = mix(0.75, 1.2, r2.x);
	// Maske unter der ganzen Krone: Mitte, acht Punkte am Rand und vier auf
	// halbem Weg. Die halben fangen schmale Flüsse und Wände, über die ein
	// großer Baum mit Rand-Abgriffen allein hinwegreichte; die diagonalen
	// Ecken von Schnee- und Fels-Zellen, in die die bilineare Maske sonst
	// hineinläuft.
	float reach = p.tree.z * k * s / world;
	const vec2 dirs[8] = vec2[8](vec2(1.0, 0.0), vec2(-1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, -1.0),
		vec2(0.7071, 0.7071), vec2(-0.7071, 0.7071), vec2(0.7071, -0.7071), vec2(-0.7071, -0.7071));
	for (int i = 0; i < 8; i++) {
		f = min(f, forest_at(uv + dirs[i] * reach));
	}
	for (int i = 0; i < 4; i++) {
		f = min(f, forest_at(uv + dirs[i] * reach * 0.5));
	}
	float size = s * vis * smoothstep(thr, thr + 0.15, f);
	if (size <= 0.01) {
		return;
	}
	base.y += relief_lift(uv);

	// Nadelbaum-Anteil wie im Kronendach (`canopy()`), mit mehr Nadelbäumen
	// (Vorbild f, e): Höhe plus zwei Bestands-Rauschskalen.
	vec2 swp = xz + world * 0.5;
	float stand = vnoise(swp * 0.55 + vec2(3.7, 11.3));
	float region = vnoise(swp * 0.13 + vec2(19.1, 5.4));
	float alt = clamp((hraw - p.grid.y) / max(p.grid.z - p.grid.y, 1e-6), 0.0, 1.0);
	float share = clamp(alt * 0.9 + (region - 0.5) * 1.4 + (stand - 0.5) * 0.6 + 0.3, 0.05, 0.95);
	float con = 1.0 - smoothstep(share - 0.04, share + 0.04, r2.y);
	float yellow = smoothstep(0.72, 0.86, stand) * (1.0 - share) * 0.6;
	vec3 decid = mix(vec3(0.048, 0.112, 0.028), vec3(0.100, 0.132, 0.028), yellow);
	vec3 conif = vec3(0.024, 0.058, 0.034);
	vec3 tint = mix(decid, conif, con) * mix(0.75, 1.25, r2.w);

	// Nadelbäume schlanker und höher, Breite je Baum gestreut.
	float h = p.tree.y * size * k * mix(1.0, 1.15, con);
	float w = h * mix(0.85, 1.15, fract(r.w * 7.0)) * mix(1.0, 0.85, con);
	float a = r2.z * 6.2831853;
	float ca = cos(a);
	float sa = sin(a);
	vec4 row0 = vec4(ca * w, 0.0, -sa * w, base.x);
	vec4 row1 = vec4(0.0, h, 0.0, base.y);
	vec4 row2 = vec4(sa * w, 0.0, ca * w, base.z);
	vec4 cu = vec4(con, tint);

	vec3 centre = base + vec3(0.0, h * 0.5, 0.0);
	float radius = h * 0.7;
	if (in_frustum(centre, radius, 0.0)) {
		// Formwechsel je Baum gestreut, keine Kante im Bild.
		// Nah die eigene Form je Art (die Mischform nur für Grob und
		// Schatten); der Formwechsel je Baum gestreut, keine Kante im Bild.
		if (d < p.tree2.y * mix(0.85, 1.15, fract(r.z * 13.0))) {
			if (con >= 0.5) {
				uint i = atomicAdd(counts.n[0], 1u);
				if (i < uint(p.caps.x)) {
					write_con(i, row0, row1, row2, cu);
				}
			} else {
				uint i = atomicAdd(counts.n[1], 1u);
				if (i < uint(p.caps.y)) {
					write_broad(i, row0, row1, row2, cu);
				}
			}
		} else {
			uint i = atomicAdd(counts.n[2], 1u);
			if (i < uint(p.caps.z)) {
				write_far(i, row0, row1, row2, cu);
			}
		}
	}
	if (d < p.tree2.z && in_frustum(centre, radius, p.tree2.w)) {
		uint i = atomicAdd(counts.n[3], 1u);
		if (i < uint(p.caps.w)) {
			write_shadow(i, row0, row1, row2, cu);
		}
	}
}

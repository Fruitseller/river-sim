// Textur-Displacement-Terrain: ein statisches Gitter wird in der GPU nach dem
// Höhenfeld (height_tex, R32F) verschoben; Normalen aus Nachbar-Texeln; Farbe
// aus color_tex. Wasser (Flüsse/Seen/Altarme) kommt als GLATTES Feld-Overlay aus
// water_tex (R=Fluss-Intensität, G=Seetiefe, BA=Fließrichtung) — kein blockiges
// Pro-Zell-Wasser, sondern linear gefiltert und geshadet (nasser Glanz).
//
// DETAIL-LAYER (runevision-Erosionsfilter, Shadertoy wXcfWn, MPL-2.0): pro Pixel
// werden Sub-Grid-Erosionsrinnen auf die Sim-Heightmap gerechnet (Phacelle-Noise
// entlang des lokalen Gefälles, „stacked faded gullies") → Normal-Perturbation +
// Rinnen-Schattierung + Ridge-Map (feuchte Kerben). Rein kosmetisch, die Physik
// bleibt in SimCore; mit der Kameradistanz ausgeblendet (Aliasing + Kosten).
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D color_tex : filter_linear, repeat_disable;
uniform sampler2D water_tex : filter_linear, repeat_disable;
uniform float hscale = 26.0;
uniform float world_size = 100.0;
uniform float grid_n = 256.0;
uniform float u_time = 0.0;
uniform float sea_level = 0.15;

// Detail-Erosion: Skala in UV (0.006 ≈ 4 Sim-Zellen Wellenlänge der größten
// Rinnen), Stärke = Höhenamplitude relativ zur Skala (wie im Original).
uniform float detail_scale = 0.006;
uniform float detail_strength = 0.30;
uniform float detail_shade = 0.20;     // Albedo-Abdunkelung in Rinnenböden
uniform float detail_normal = 1.0;     // Anteil der Normal-Perturbation
uniform bool detail_enabled = true;

varying vec2 v_uv;

// UV aus der Weltposition ableiten (statt Mesh-UV) → deckungsgleich mit der
// Zellindizierung des Sim-Kerns und damit mit Flüssen/Wasser.
vec2 world_uv(vec3 vert) {
	return (vert.xz + world_size * 0.5) / world_size;
}

// ---------------------------------------------------------------------------
// Phacelle-Noise + Erosionsfilter — portiert aus „Advanced Terrain Erosion
// Filter", Copyright (c) 2025 Rune Skovbo Johansen, Mozilla Public License 2.0
// (https://mozilla.org/MPL/2.0/). Referenz: docs/references/runevision-erosion/.
// ---------------------------------------------------------------------------

vec2 ehash(vec2 x) {
	const vec2 k = vec2(0.3183099, 0.3678794);
	x = x * k + k.yx;
	return -1.0 + 2.0 * fract(16.0 * k * fract(x.x * x.y * (x.x + x.y)));
}

float ease_out(float t) {
	float v = 1.0 - clamp(t, 0.0, 1.0);
	return 1.0 - v * v;
}

float smooth_start(float t, float smoothing) {
	if (t >= smoothing) { return t - 0.5 * smoothing; }
	return smoothing <= 0.0 ? t : 0.5 * t * t / smoothing;
}

float pow_inv(float t, float power) {
	return 1.0 - pow(1.0 - clamp(t, 0.0, 1.0), power);
}

// Streifenmuster entlang normDir: cos/sin-Paare aus 4×4 zufällig versetzten
// Zellen interpoliert + normalisiert. Rückgabe: (cos, sin, sideDir).
vec4 phacelle_noise(vec2 p, vec2 norm_dir, float freq, float offset, float normalization) {
	vec2 side_dir = norm_dir.yx * vec2(-1.0, 1.0) * freq * 6.2831853;
	offset *= 6.2831853;
	vec2 p_int = floor(p);
	vec2 p_frac = fract(p);
	vec2 phase_dir = vec2(0.0);
	float weight_sum = 1e-9;
	for (int i = -1; i <= 2; i++) {
		for (int j = -1; j <= 2; j++) {
			vec2 grid_offset = vec2(float(i), float(j));
			vec2 v = p_frac - grid_offset - ehash(p_int + grid_offset) * 0.5;
			float w = max(0.0, exp(-dot(v, v) * 2.0) - 0.01111);
			weight_sum += w;
			float wave = dot(v, side_dir) + offset;
			phase_dir += vec2(cos(wave), sin(wave)) * w;
		}
	}
	vec2 interp = phase_dir / weight_sum;
	float mag = max(1.0 - normalization, length(interp));
	return vec4(interp / mag, side_dir);
}

// Erosions-Detail: 3 Oktaven „stacked faded gullies" auf dem Sim-Höhenfeld.
// slope = dh/duv des groben Felds. Rückgabe: (dh, dsx, dsy, ridgeMap); die
// Magnitude landet in out_mag (zum Normieren der Schattierung).
vec4 erosion_detail(vec2 p, vec2 slope, float fade_target_in, out float out_mag) {
	const float GULLY_WEIGHT = 0.5;
	const float DETAIL = 1.5;
	const vec4 ROUNDING = vec4(0.1, 0.0, 0.15, 2.0);
	const vec4 ONSET = vec4(1.25, 1.25, 2.8, 1.5);
	const vec2 ASSUMED_SLOPE = vec2(0.7, 1.0);
	const float CELL_SCALE = 0.7;
	const float NORMALIZATION = 0.5;
	const int OCTAVES = 3;

	float strength = detail_strength * detail_scale;
	float fade_target = clamp(fade_target_in, -1.0, 1.0);
	vec3 hs = vec3(0.0); // Delta-Akkumulator (Höhe, Steigung)
	float freq = 1.0 / (detail_scale * CELL_SCALE);
	float slope_len = max(length(slope), 1e-10);
	float magnitude = 1e-9;
	float rounding_mult = 1.0;

	float rounding_input = mix(ROUNDING.y, ROUNDING.x, clamp(fade_target + 0.5, 0.0, 1.0)) * ROUNDING.z;
	float combi_mask = ease_out(smooth_start(slope_len * ONSET.x, rounding_input * ONSET.x));
	float ridge_mask = ease_out(slope_len * ONSET.z);
	float ridge_fade = fade_target;
	vec2 gully_slope = mix(slope, slope / slope_len * ASSUMED_SLOPE.x, ASSUMED_SLOPE.y);

	for (int i = 0; i < OCTAVES; i++) {
		vec4 ph = phacelle_noise(p * freq, normalize(gully_slope), CELL_SCALE, 0.25, NORMALIZATION);
		ph.zw *= -freq;
		float sloping = abs(ph.y);
		gully_slope += sign(ph.y) * ph.zw * strength * GULLY_WEIGHT;

		vec3 gullies = vec3(ph.x, ph.y * ph.zw);
		vec3 faded = mix(vec3(fade_target, 0.0, 0.0), gullies * GULLY_WEIGHT, combi_mask);
		hs += faded * strength;
		magnitude += strength;
		fade_target = faded.x;

		float rounding_oct = mix(ROUNDING.y, ROUNDING.x, clamp(ph.x + 0.5, 0.0, 1.0)) * rounding_mult;
		float new_mask = ease_out(smooth_start(sloping * ONSET.y, rounding_oct * ONSET.y));
		combi_mask = pow_inv(combi_mask, DETAIL) * new_mask;

		ridge_fade = mix(ridge_fade, gullies.x, ridge_mask);
		ridge_mask *= ease_out(sloping * ONSET.w);

		strength *= 0.5;
		freq *= 2.0;
		rounding_mult *= ROUNDING.w;
	}
	out_mag = magnitude;
	return vec4(hs, ridge_fade * (1.0 - ridge_mask));
}

// Billiges Value-Noise (2 Oktaven) für Breakup/Schaum — de-uniformiert Flächen.
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = ehash(i).x;
	float b = ehash(i + vec2(1.0, 0.0)).x;
	float c = ehash(i + vec2(0.0, 1.0)).x;
	float d = ehash(i + vec2(1.0, 1.0)).x;
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 0.5 + 0.5;
}

void vertex() {
	vec2 uv = world_uv(VERTEX);
	v_uv = uv;
	VERTEX.y = texture(height_tex, uv).r * hscale;
	float texel = 1.0 / grid_n;
	float hL = texture(height_tex, uv - vec2(texel, 0.0)).r;
	float hR = texture(height_tex, uv + vec2(texel, 0.0)).r;
	float hD = texture(height_tex, uv - vec2(0.0, texel)).r;
	float hU = texture(height_tex, uv + vec2(0.0, texel)).r;
	float sw = world_size / (grid_n - 1.0);
	NORMAL = normalize(vec3(-(hR - hL) * hscale, 2.0 * sw, -(hD - hU) * hscale));
}

void fragment() {
	vec3 terr = texture(color_tex, v_uv).rgb;
	float hval = texture(height_tex, v_uv).r;

	// grobe Steigung (dh/duv) aus Nachbar-Texeln — Eingang für den Detail-Filter
	// und für die per-Pixel-Normale (glatter als die Vertex-Normale).
	float texel = 1.0 / grid_n;
	float hL = texture(height_tex, v_uv - vec2(texel, 0.0)).r;
	float hR = texture(height_tex, v_uv + vec2(texel, 0.0)).r;
	float hD = texture(height_tex, v_uv - vec2(0.0, texel)).r;
	float hU = texture(height_tex, v_uv + vec2(0.0, texel)).r;
	vec2 coarse_slope = vec2(hR - hL, hU - hD) * 0.5 * grid_n;

	// --- Detail-Erosion (Sub-Grid-Rinnen) ---
	// Mit der Kameradistanz UND unterm Meer ausblenden; jenseits des Fades den
	// Filter ganz überspringen (Kosten). fade_target aus der Höhenlage:
	// Täler → −1 (Kerben verschmelzen), Gipfel → +1 (Grate bleiben spitz).
	// Fade-Distanzen skalieren mit der Weltgröße (kalibriert auf world=100).
	float ws = world_size / 100.0;
	float view_dist = length(VERTEX);
	float dfade = (1.0 - smoothstep(110.0 * ws, 280.0 * ws, view_dist))
	            * smoothstep(sea_level + 0.005, sea_level + 0.045, hval);
	vec2 det_slope = vec2(0.0);
	float det_shade = 0.0;
	float det_ridge = 0.0;
	if (detail_enabled && dfade > 0.002) {
		float fade_target = clamp((hval - sea_level) / 0.6 * 2.0 - 1.0, -1.0, 1.0);
		float det_mag;
		vec4 det = erosion_detail(v_uv, coarse_slope, fade_target, det_mag);
		det_slope = det.yz * dfade * detail_normal;
		det_shade = det.x / det_mag * dfade;   // −1 Rinnenboden … 1 Grat
		det_ridge = det.w * dfade;             // −1 Kerbe (Drainage) … 1 Grat
	}

	// per-Pixel-Normale aus grober + Detail-Steigung (Welt → View).
	vec2 s_uv = coarse_slope + det_slope;
	vec3 n_ws = normalize(vec3(-s_uv.x * hscale / world_size, 1.0, -s_uv.y * hscale / world_size));
	NORMAL = normalize(mat3(VIEW_MATRIX) * n_ws);

	// --- Land-Shading: Rinnen-Licht, feuchte Kerben, Breakup ---
	vec2 wp = v_uv * world_size;
	float breakup = vnoise(wp * 0.9) * 0.6 + vnoise(wp * 3.7) * 0.4;
	// Rinnenböden abdunkeln, Grate nur MINIMAL aufhellen (asymmetrisch — das
	// Terrain ist sonnenseitig schon hell genug; symmetrisch kippte alles ins
	// Kalk-Weiß) → die Erosion "liest" sich auch bei flach stehender Normale.
	terr *= 1.0 + min(det_shade, 0.0) * detail_shade + max(det_shade, 0.0) * detail_shade * 0.3;
	// Feuchte Kerben (Ridge-Map < 0): dunkler, entsättigt-grünlich — die
	// dendritischen Zubringer der Flüsse (Drainage-Optik aus dem Original).
	float crease = clamp(-det_ridge, 0.0, 1.0);
	float moist = crease * (1.0 - smoothstep(0.45, 0.72, hval));
	terr = mix(terr, terr * vec3(0.60, 0.70, 0.58) + vec3(0.0, 0.02, 0.0), moist * 0.45);
	// Breakup: großflächige Albedo-Variation gegen die Uniformität.
	terr *= 0.94 + 0.12 * breakup;

	vec4 w = texture(water_tex, v_uv);
	float stream = w.r;
	float lake = w.g;
	vec2 dir = w.ba * 2.0 - 1.0;

	// weiche Masken → glatte Ufer statt harter Kanten (linear-Filter + smoothstep)
	// lakeMask höher angesetzt: seichte Verlandungs-Pfützen (basinFill) sollen NICHT
	// als pastell-teal Fläche übermalen — nur echte Seen zeigen Wasser.
	float riverMask = smoothstep(0.16, 0.45, stream);
	float lakeMask = smoothstep(0.16, 0.36, lake);
	float wet = max(riverMask, lakeMask);

	// --- Ufer-Saum (Punkt „Shading-Tricks"): der Blur-Halo des Wasserfelds
	// (unterhalb der Sichtbarkeits-Schwelle) wird als nasser Sand-/Kies-Streifen
	// getönt → Flüsse und Seen bekommen ein Ufer statt einer harten Farbkante.
	float shore = smoothstep(0.09, 0.16, max(stream, lake)) * (1.0 - wet);
	vec3 shore_col = vec3(0.50, 0.46, 0.38) * (0.85 + 0.3 * breakup);
	terr = mix(terr, shore_col, shore * 0.35);
	terr *= 1.0 - shore * 0.22; // feuchtes Ufer ist dunkler

	// Tiefe skaliert mit dem Abfluss (stream-Intensität) → Hauptflüsse tief-blau,
	// Bäche seicht-teal. Erzeugt die sichtbare Fluss-Hierarchie.
	float depth = clamp(max(lake * 2.5, stream), 0.0, 1.0);

	// --- „Echtes Wasser" statt angemalter Erde ---
	// (1) Wasser hat eine EIGENE Oberfläche: flache Welt-Normale mit animierten
	// Kräusel-Wellen — nicht die Fels-Normale des Flussbetts darunter. Erst dadurch
	// fängt es Sonne/Himmel wie eine Wasserfläche (Glints), statt wie nasser Stein.
	float speed = riverMask >= lakeMask ? 1.0 : 0.25;      // Seen kräuseln nur träge
	vec2 d1 = normalize(length(dir) > 0.05 ? dir : vec2(0.7, 0.7));
	vec2 d2 = vec2(-d1.y, d1.x);                            // quer zur Fließrichtung
	// Wellen-Höhenfeld h = Σ aᵢ·sin(fᵢ·x − ωᵢ·t): Gradient analytisch → Normale.
	float p1 = dot(wp, d1) * 2.3 - u_time * 5.0 * speed;
	float p2 = dot(wp, d2) * 4.1 + dot(wp, d1) * 1.3 - u_time * 3.1 * speed;
	float p3 = dot(wp, d1 + d2) * 6.3 - u_time * 7.3 * speed + 1.7;
	// Kräuselung mit der Kameradistanz ausblenden: von weitem aliast die
	// Wellen-Normale sonst zu weißem Specular-Glitzer (Konfetti auf den Seen).
	float ripple_fade = 1.0 - smoothstep(50.0 * ws, 160.0 * ws, view_dist);
	float amp = mix(0.015, 0.05, depth) * ripple_fade;      // große Flüsse wellen stärker
	amp *= riverMask >= lakeMask ? 1.0 : 0.45;              // Seen: nur sanftes Kräuseln
	vec2 grad = d1 * (2.3 * cos(p1)) * amp
	          + (d2 * 4.1 + d1 * 1.3) * (0.6 * cos(p2)) * amp
	          + (d1 + d2) * (6.3 * cos(p3)) * (0.25 * amp);
	vec3 water_n_ws = normalize(vec3(-grad.x, 1.0, -grad.y));
	vec3 water_n_vs = normalize(mat3(VIEW_MATRIX) * water_n_ws);
	NORMAL = normalize(mix(NORMAL, water_n_vs, wet));

	// (2) Tiefen-Farbe + Transparenz: seichtes Wasser lässt das BETT durchscheinen
	// (grünlich getrübt), tiefes Wasser wird opak dunkelblau. Das Bett unterm
	// Wasser wird abgedunkelt (nass) → glaubwürdige Ufer-Übergänge.
	vec3 shallow = vec3(0.18, 0.37, 0.42);
	vec3 deep = vec3(0.03, 0.12, 0.26);
	vec3 water = mix(shallow, deep, depth);
	vec3 bed = terr * mix(1.0, 0.55, wet);                 // nasses, dunkles Bett
	float opacity = mix(0.55, 0.95, depth);                // seicht = durchscheinend

	// (3) Fresnel: flacher Blick → Himmel spiegelt, steiler Blick → ins Wasser.
	float ndv = clamp(dot(water_n_vs, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, 5.0);
	vec3 sky = vec3(0.62, 0.70, 0.76);                     // Himmels-Ton (wie Env)
	water = mix(water, sky, fresnel * 0.55);

	// (4) Strömungs-Schimmer entlang der Fließrichtung (dezent, Bewegung bleibt
	// im Zeitraffer ablesbar; die Glints machen die Hauptarbeit).
	if (riverMask >= lakeMask && length(dir) > 0.05) {
		float along = dot(wp, normalize(dir));
		float flow = sin(along * 1.4 - u_time * 4.0) * 0.5
			+ sin(along * 3.1 - u_time * 6.5 + 1.7) * 0.5;
		water += flow * vec3(0.012, 0.018, 0.025);
	}

	// (5) Schaum an der Wasserlinie: schmaler Streifen an der wet-Kante,
	// von Breakup-Noise aufgebrochen und mit der Strömung driftend — nur nah
	// (ripple_fade), von weitem würde er zu weißem Rauschen aliasen.
	float edge = wet * (1.0 - wet) * 4.0;                  // 1 an der Uferlinie
	float foam_n = vnoise(wp * 7.0 - dir * u_time * 2.5 + vec2(0.0, u_time * 0.4));
	float foam = smoothstep(0.55, 0.95, edge * (0.45 + 0.75 * foam_n)) * ripple_fade;

	vec3 water_final = mix(bed, water, opacity);
	water_final = mix(water_final, vec3(0.88, 0.92, 0.94), foam * 0.45);
	ALBEDO = mix(terr, water_final, wet);
	// nasser Glanz: bei STEILEM Blick matter (sonst spiegelt der graue Himmel die
	// Farbe milchig-weg), erst bei flachem Winkel (Fresnel) glasklar spiegelnd.
	ROUGHNESS = mix(0.95, mix(0.34, 0.08, fresnel), wet);
	METALLIC = 0.0;
	SPECULAR = mix(0.5, mix(0.55, 1.0, fresnel), wet);
}

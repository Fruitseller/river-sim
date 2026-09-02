// Textur-Displacement-Terrain: ein statisches Gitter wird in der GPU nach dem
// Höhenfeld (height_tex, R32F) verschoben; Normalen aus Nachbar-Texeln; Farbe
// aus color_tex. Wasser (Flüsse/Seen/Altarme) kommt als GLATTES Feld-Overlay aus
// water_tex (R=Fluss-Intensität, G=See-GATE + Altarm-Deckkraft, BA=Fließrichtung)
// — kein blockiges Pro-Zell-Wasser, sondern linear gefiltert und geshadet (nasser
// Glanz). Der G-Kanal trägt seit Issue #32 KEINE Tiefe mehr: er sagt nur noch WO
// ein See sichtbar ist, die FORM der Uferlinie und die Tiefe rechnet dieser
// Shader per Pixel aus der Wassersäule (pond_at).
//
// Alle Schwellen, mit denen dieser Shader die Wasser-Kanäle liest, und die
// Wasser-OPTIK (Farben, Fresnel, Rauheit/Specular, Strömungs-Schimmer) kommen
// als water_*-Uniforms über die Brücke (SimCore/WaterRender.swift →
// SimRender.WaterUniforms → SimNode → Main.gd, Issues #91/#92) — hier steht
// keine dieser Zahlen mehr. Die Optik ist mit game/shaders/water.gdshader
// identisch (dieselben Uniforms), damit Raster-Wasser und Band-Geometrie als
// EIN Wasser lesen; welcher Ausdruck welche Uniform liest, pinnt
// SimCoreTests/WaterRenderTests.swift als Struktur-Vertrag.
//
// DETAIL-LAYER (runevision-Erosionsfilter, Shadertoy wXcfWn, MPL-2.0): pro Pixel
// werden Sub-Grid-Erosionsrinnen auf die Sim-Heightmap gerechnet (Phacelle-Noise
// entlang des lokalen Gefälles, „stacked faded gullies") → Normal-Perturbation +
// Rinnen-Schattierung + Ridge-Map (feuchte Kerben). Rein kosmetisch, die Physik
// bleibt in SimCore; mit der Kameradistanz ausgeblendet (Aliasing + Kosten).
//
// MATERIAL-LAYER (davon UNABHÄNGIG): aus surface_tex werden Boden, Vegetation,
// Fels und Schnee/Eis in Weltkoordinaten prozedural aufgebaut (Körnung,
// Gesteinsschichten, Windverfrachtung, Mikro-Normale). Eigener Schalter
// `material_enabled` — wer `detail_enabled` abschaltet, um die Erosionsrinnen
// zu isolieren, behält damit die Materialien.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D hf_tex : filter_linear, repeat_disable; // gefüllte Oberfläche (Seespiegel)
uniform sampler2D color_tex : filter_linear, repeat_disable;
uniform sampler2D surface_tex : filter_linear, repeat_disable; // R Vegetation, G Fels, B Schnee/Eis, A Lithologie
uniform sampler2D debug_difference_tex : filter_linear, repeat_disable;
uniform sampler2D water_tex : filter_linear, repeat_disable;
// Default == Main.gd HSCALE == RenderContract.heightScale (Issue #51). Im Spiel
// setzt Main.gd den Uniform ohnehin; der Default zählt, wo das Material OHNE
// SimNode läuft (Editor-Vorschau) — er stand auf 26.0 und zeigte dort ein 8 %
// zu hohes Terrain. Wächter: SimCoreTests/RenderContractTests.swift.
// Bewusst MIT Literal-Default trotz #92 (das die water_*-Defaults abgeschafft
// hat): ohne ihn wäre die Editor-Vorschau ein flaches Brett, während
// unkalibriertes Wasser dort nur falsch getönt ist — der Wächter hält die Kopie.
uniform float hscale = 24.0;
uniform float world_size = 100.0;
uniform float grid_n = 256.0;
uniform float u_time = 0.0;
uniform float sea_level = 0.15;
// Höhenband der Vegetation (Issue #4): kommt aus dem Sim-Kern (Perzentile der
// aktuellen Landhöhen, SimNode.heightBands) — die feuchten Kerben blenden
// zwischen diesen beiden Höhen aus. Vorher standen hier absolute 0.45/0.72; die
// obere Grenze lag über dem höchsten je erreichten Punkt, der Ausblender kam
// also nie an. Die Defaults sind nur der Stand ohne SimNode-Update.
uniform float veg_alt_lo = 0.45;
uniform float veg_alt_hi = 0.72;

// Detail-Erosion: Skala in UV (0.006 ≈ 4 Sim-Zellen Wellenlänge der größten
// Rinnen), Stärke = Höhenamplitude relativ zur Skala (wie im Original).
uniform float detail_scale = 0.006;
uniform float detail_strength = 0.16; // Jahr-0-Default; Main.gd fährt bis 0.7 bei 100k hoch
uniform float detail_shade = 0.20;     // Albedo-Abdunkelung in Rinnenböden
uniform float detail_normal = 1.0;     // Anteil der Normal-Perturbation
uniform bool detail_enabled = true;
// Materialschicht: getrennt schaltbar vom Detail-Layer darüber, weil beides
// verschiedene Dinge sind (Erosionsrinnen vs. Gesteins- und Bodenmaterial).
// Main.gd hängt beide an `render_quality`; abgeschaltet entfällt der KOMPLETTE
// Noise-Aufwand dieser Schicht, nicht nur der ausgeblendete Teil.
uniform bool material_enabled = true;
uniform bool debug_difference = false;

// Wasser-Kalibrierung über die Brücke (Issues #91/#92): Main.gd setzt die
// Werte beim Aufbau aus SimRender.WaterUniforms. BEWUSST ohne Default — ein
// Literal-Default wäre wieder eine Kopie der Kalibrierung (die #92 abschafft);
// die Editor-Vorschau ohne SimNode ist damit unkalibriert (alles Null), aber
// TOTAL: calib_window unten sowie max() an Tiefen-Rampe und Fresnel-Exponent
// sichern gegen die Null-Uniforms ab (smoothstep mit edge0 >= edge1 und
// pow(0.0, 0.0) sind laut GLSL-Spec undefiniert, die Rampe wäre 0/0 —
// NaN bis in ALBEDO; Review zu #105).
// Wächter: SimCoreTests/WaterUniformsTests.swift (default-frei, gelesen),
// game/tests/water_uniforms.gd (End-to-End: jede Uniform wird gesetzt).
uniform float water_lake_gate_lo;
uniform float water_lake_gate_hi;
uniform float water_river_mask_lo;
uniform float water_river_mask_hi;
uniform float water_shore_lo;
uniform float water_shore_hi;
uniform float water_pond_contour_lo;
uniform float water_pond_contour_hi;
uniform float water_geometry_lift_lo;
uniform float water_geometry_lift_hi;
uniform float water_lake_depth_lo;
uniform float water_lake_depth_span;
uniform float water_fresnel_exponent;
uniform float water_fresnel_sky_mix;
uniform float water_opacity_shallow;
uniform float water_opacity_deep;
uniform float water_roughness_steep;
uniform float water_roughness_grazing;
uniform float water_specular_steep;
uniform float water_specular_grazing;
uniform vec3 water_shallow_color;
uniform vec3 water_deep_color;
uniform vec3 water_sky_reflect_color;
uniform vec3 water_flow_shimmer_color;

varying vec2 v_uv;

// Kalibrier-Fenster, total auch mit Null-Uniforms (Editor-Vorschau ohne
// SimNode, s. Deklarationsblock oben): das Epsilon ist KEINE Kalibrier-Kopie,
// nur eine Mindest-Fensterbreite gegen GLSL-undefiniertes smoothstep; mit
// gesetzten Werten (hi > lo) ändert das max() nichts.
float calib_window(float lo, float hi, float x) {
	return smoothstep(lo, max(hi, lo + 1e-6), x);
}

// UV aus der Weltposition ableiten (statt Mesh-UV) → deckungsgleich mit der
// Zellindizierung des Sim-Kerns und damit mit Flüssen/Wasser.
vec2 world_uv(vec3 vert) {
	return (vert.xz + world_size * 0.5) / world_size;
}

// Wassersäule des ratenbegrenzten Seespiegels über dem Terrain (0 = trocken;
// das Meer hat seine eigene Wasserebene). height_tex/hf_tex sind das VOLLE
// Sim-Gitter, bilinear gefiltert — die Null-Linie dieses Felds ist damit eine
// glatte Kontur auf dem Sim-Gitter (Shader-Äquivalent von Marching Squares),
// nicht die Treppe des Render-Gitters (Issue #32). hf = waterLevel → die
// Kontur erbt das Anti-Sägezahn-Verhalten.
float pond_at(vec2 uv, float h_val) {
	float hf_val = texture(hf_tex, uv).r;
	return max(hf_val - h_val, 0.0) * step(sea_level, hf_val);
}

// Sichtbarkeits-Gate der Seen (water_tex.g: Komponenten-Fade, geblurt) — WO
// Wasser gemalt/gehoben wird; die FORM macht pond_at. Das Fenster lässt den
// Blur-Halo am Ufer durch und schaltet ab WaterRender.lakeGateHi voll
// (Kalibrier-Herleitung: WaterFieldRenderer, fadeLo/HiCells).
float lake_gate_at(vec2 uv) {
	return calib_window(water_lake_gate_lo, water_lake_gate_hi, texture(water_tex, uv).g);
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

// normalize() auf dem Null-Vektor ist undefiniert (GPU: NaN) — auf EXAKT flachem
// Terrain (Einebnen-Werkzeug, Floor-Clamp) wurde daraus eine schwarze Fläche.
// Degenerierte Richtungen bekommen einen festen Ersatz; die Detail-Masken blenden
// bei Steigung ≈ 0 ohnehin auf null, der Ersatzwert ist also unsichtbar.
vec2 safe_dir(vec2 v) {
	return dot(v, v) > 1e-14 ? v * inversesqrt(dot(v, v)) : vec2(0.7071, 0.7071);
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
		vec4 ph = phacelle_noise(p * freq, safe_dir(gully_slope), CELL_SCALE, 0.25, NORMALIZATION);
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

// Materialrauschen in Weltkoordinaten. Die triplanare Mischung hält die Körnung
// auf Steilwänden rund statt die Draufsicht senkrecht über den Fels zu ziehen.
float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.55;
	for (int octave = 0; octave < 3; octave++) {
		value += vnoise(p) * amplitude;
		p = p * 2.03 + vec2(17.1, 9.2);
		amplitude *= 0.48;
	}
	return value;
}

float triplanar_fbm(vec3 p, vec3 n) {
	vec3 weight = pow(abs(n), vec3(4.0));
	weight /= max(weight.x + weight.y + weight.z, 0.0001);
	return fbm(p.yz) * weight.x + fbm(p.xz) * weight.y + fbm(p.xy) * weight.z;
}

void vertex() {
	vec2 uv = world_uv(VERTEX);
	v_uv = uv;
	float hraw = texture(height_tex, uv).r;
	// Seen als ECHTE horizontale Flächen: unter Wasser stehende Zellen werden
	// auf den Seespiegel hf gehoben. Der weiche Einstieg glättet die Uferlinie.
	// MIT dem See-Gate multipliziert: eine Komponente, die das Gate (noch) nicht
	// sichtbar macht, darf auch nicht gehoben werden — sonst stünde eine
	// horizontale Fläche in Terrain-Farbe im Becken („trockener Wasserspiegel").
	// So faden kleine Seen als Ganzes ein: Geometrie und Farbe zusammen.
	float hfv = texture(hf_tex, uv).r;
	float pond = pond_at(uv, hraw);
	float lift = calib_window(water_geometry_lift_lo, water_geometry_lift_hi, pond) * lake_gate_at(uv);
	VERTEX.y = mix(hraw, hfv, lift) * hscale;
	float texel = 1.0 / grid_n;
	float hL = texture(height_tex, uv - vec2(texel, 0.0)).r;
	float hR = texture(height_tex, uv + vec2(texel, 0.0)).r;
	float hD = texture(height_tex, uv - vec2(0.0, texel)).r;
	float hU = texture(height_tex, uv + vec2(0.0, texel)).r;
	float sw = world_size / (grid_n - 1.0);
	NORMAL = normalize(vec3(-(hR - hL) * hscale, 2.0 * sw, -(hD - hU) * hscale));
}

void fragment() {
	vec3 macro_color = texture(color_tex, v_uv).rgb;
	vec4 surface = texture(surface_tex, v_uv);
	vec3 debug_color = texture(debug_difference_tex, v_uv).rgb;
	float hval = texture(height_tex, v_uv).r;

	// Grobe Steigung aus dem Sim-Gitter. Sie bestimmt die Form, während die
	// Material-Normale darunter nur Licht im Zentimetermaßstab bricht.
	float texel = 1.0 / grid_n;
	float hL = texture(height_tex, v_uv - vec2(texel, 0.0)).r;
	float hR = texture(height_tex, v_uv + vec2(texel, 0.0)).r;
	float hD = texture(height_tex, v_uv - vec2(0.0, texel)).r;
	float hU = texture(height_tex, v_uv + vec2(0.0, texel)).r;
	vec2 coarse_slope = vec2(hR - hL, hU - hD) * 0.5 * grid_n;

	float ws = world_size / 100.0;
	float view_dist = length(VERTEX);
	float dfade = (1.0 - smoothstep(110.0 * ws, 280.0 * ws, view_dist))
	            * smoothstep(sea_level + 0.005, sea_level + 0.045, hval);
	vec2 det_slope = vec2(0.0);
	float det_shade = 0.0;
	float det_ridge = 0.0;
	if (detail_enabled && !debug_difference && dfade > 0.002) {
		float fade_target = clamp((hval - sea_level) / 0.6 * 2.0 - 1.0, -1.0, 1.0);
		float det_mag;
		vec4 det = erosion_detail(v_uv, coarse_slope, fade_target, det_mag);
		det_slope = det.yz * dfade * detail_normal;
		det_shade = det.x / det_mag * dfade;
		det_ridge = det.w * dfade;
	}

	vec2 s_uv = coarse_slope + det_slope;
	vec3 n_ws = normalize(vec3(-s_uv.x * hscale / world_size, 1.0, -s_uv.y * hscale / world_size));
	vec2 wp = v_uv * world_size;
	vec3 material_pos = vec3(wp.x - world_size * 0.5, hval * hscale,
	                         wp.y - world_size * 0.5);

	// Vier physikalisch gebundene Grundmaterialien. Die CPU liefert nur ihre
	// Gewichte; Körnung, Schichten und Rauheit entstehen hier kontinuierlich in
	// Weltkoordinaten und bleiben damit unabhängig vom Render-Gitter.
	float vegetation = clamp(surface.r, 0.0, 1.0);
	float rock = clamp(surface.g, 0.0, 1.0);
	float cold = clamp(surface.b, 0.0, 1.0);
	float lith = surface.a * 2.0 - 1.0;
	// `material_fade` blendet NUR das Feingran aus: es aliast in der Distanz und
	// liegt dort unter einem Pixel. Die GROSSEN Terme (tri_large, top_large)
	// tragen die Makro-Variation der Grundfarben und laufen bis zum Horizont
	// weiter — sie am Fade-Ende abzuschalten ergäbe eine sichtbare Kante quer
	// durch die Landschaft. Gespart wird deshalb über `material_enabled`: ganze
	// Schicht aus, ohne Kante, weil global.
	float material_fade = material_enabled
	                    ? 1.0 - smoothstep(65.0 * ws, 210.0 * ws, view_dist)
	                    : 0.0;
	float tri_large = 0.5;
	float top_large = 0.5;
	float tri_grain = 0.5;
	float top_grain = 0.5;
	float wind_snow = 0.5;
	if (material_enabled) {
		tri_large = triplanar_fbm(material_pos * 0.19, n_ws);
		top_large = fbm(wp * 0.16);
		if (material_fade > 0.002) {
			tri_grain = triplanar_fbm(material_pos * 0.82 + vec3(7.0, 13.0, 3.0), n_ws);
			top_grain = fbm(wp * 0.72 + vec2(31.0, 11.0));
			wind_snow = fbm(wp * vec2(0.25, 0.55) + vec2(4.0, 19.0));
		}
	}

	vec3 soil_color = vec3(0.25, 0.20, 0.14)
	                * mix(0.82, 1.12, top_large)
	                * mix(0.93, 1.07, top_grain * material_fade);
	vec3 vegetation_color = vec3(0.10, 0.24, 0.075)
	                      * mix(0.76, 1.15, top_large)
	                      * mix(0.90, 1.08, top_grain * material_fade);

	// Die echte Lithologie steuert die Helligkeit der Schichtflächen. Harte
	// Bänder sind dunkler, feinkörniger und rauer; weiche Bänder verwittern hell. Das
	// Korn wird über `material_fade` auf seinen neutralen Mittelwert 0.5 gezogen,
	// nicht am Gate hart auf ihn gesetzt: sonst stünde am Fade-Ende eine Kante
	// von bis zu 11 % Helligkeit quer durch die Felsflächen.
	float strata_phase = abs(fract(material_pos.y * 1.65 + tri_large * 1.8) - 0.5) * 2.0;
	float strata_edge = smoothstep(0.72, 0.96, strata_phase);
	float lith_contrast = mix(1.09, 0.82, lith * 0.5 + 0.5);
	vec3 rock_color = mix(vec3(0.28, 0.29, 0.30), vec3(0.37, 0.35, 0.32),
	                      tri_large * 0.55)
	                * mix(0.86, 1.08, mix(0.5, tri_grain, material_fade))
	                * mix(1.0, lith_contrast, strata_edge * rock);

	vec3 cold_color = vec3(0.79, 0.84, 0.89)
	                * mix(0.91, 1.05, wind_snow * material_fade);

	// Die CPU liefert die Gewichte schon hierarchisch abgeschwächt
	// (TerrainColorRenderer: Kälte voll, Vegetation × (1−Kälte), Fels ×
	// (1−Vegetation)(1−Kälte)); sie summieren sich damit auf höchstens 1, der
	// Rest ist Boden. Als mix-KETTE gerechnet dämpfte jedes spätere Material das
	// frühere ein ZWEITES Mal — auf einem bewaldeten Hang (veg 0.6, rock 0.2)
	// blieben von der Felsfarbe 8 % statt 20 %, und das Ergebnis hing an der
	// Blend-Reihenfolge. Als Gewichtssumme ist es reihenfolge-unabhängig und
	// jedes Material genau mit seinem Anteil sichtbar. Normiert wird, weil die
	// Byte-Quantisierung der Gewichte die Summe knapp über 1 heben kann.
	float cover_w = vegetation + rock + cold;
	float soil_w = max(0.0, 1.0 - cover_w);
	vec3 terr = (soil_color * soil_w + rock_color * rock
	          + vegetation_color * vegetation + cold_color * cold)
	          / max(0.001, soil_w + cover_w);
	// Die Makrokarte bewahrt Salzkrusten, Gletschereis und Biom-Farbverschiebung,
	// ohne wieder als alleinige, weichgefilterte Oberfläche sichtbar zu werden.
	terr = mix(terr, macro_color, 0.28);
	float salt_hint = smoothstep(0.48, 0.72, macro_color.r)
	                * smoothstep(0.04, 0.12, macro_color.r - macro_color.b)
	                * (1.0 - cold) * (1.0 - vegetation);
	terr = mix(terr, macro_color, salt_hint * 0.72);
	if (hval <= sea_level + 0.012) {
		terr = macro_color;
	}

	// Mikro-Normale aus drei Weltachsen. Ein einfacher Noise-Sample pro Achse
	// genügt hier; drei weitere vollständige triplanare FBMs kosteten pro Pixel
	// 27 unnötige Noise-Auswertungen.
	if (material_fade > 0.002 && hval > sea_level + 0.012) {
		vec3 micro_pos = material_pos * 2.8;
		vec3 micro = vec3(vnoise(micro_pos.xy + vec2(5.0, 17.0)),
		                  vnoise(micro_pos.yz + vec2(23.0, 3.0)),
		                  vnoise(micro_pos.xz + vec2(13.0, 31.0))) - vec3(0.5);
		micro -= n_ws * dot(micro, n_ws);
		float micro_strength = mix(0.055, 0.13, rock) * mix(1.0, 0.45, cold);
		n_ws = normalize(n_ws + micro * micro_strength * material_fade);
	}
	NORMAL = normalize(mat3(VIEW_MATRIX) * n_ws);

	float breakup = vnoise(wp * 0.9) * 0.6 + vnoise(wp * 3.7) * 0.4;
	terr *= 1.0 + min(det_shade, 0.0) * detail_shade
	      + max(det_shade, 0.0) * detail_shade * 0.3;
	float crease = clamp(-det_ridge, 0.0, 1.0);
	float moist = crease * (1.0 - smoothstep(veg_alt_lo, veg_alt_hi, hval));
	terr = mix(terr, terr * vec3(0.60, 0.70, 0.58) + vec3(0.0, 0.02, 0.0),
	           moist * 0.32);
	terr *= 0.96 + 0.08 * breakup;

	float ice_hint = smoothstep(0.04, 0.16, macro_color.b - macro_color.r) * cold;
	float land_roughness = mix(0.90, 0.68, rock);
	land_roughness = mix(land_roughness, 0.84, vegetation);
	land_roughness = mix(land_roughness, 0.78, cold);
	land_roughness = mix(land_roughness, 0.34, ice_hint);
	land_roughness += (tri_grain - 0.5) * 0.08 * material_fade;

	if (debug_difference) {
		terr = debug_color;
		land_roughness = 0.9;
	}

	vec4 w = texture(water_tex, v_uv);
	float stream = w.r;
	float lake_gate = w.g;
	vec2 dir = w.ba * 2.0 - 1.0;
	float riverMask = calib_window(water_river_mask_lo, water_river_mask_hi, stream);
	float pond = pond_at(v_uv, hval);
	float lakeMask = calib_window(water_pond_contour_lo, water_pond_contour_hi, pond) * lake_gate_at(v_uv);
	float wet = max(riverMask, lakeMask);

	float dry = 1.0 - calib_window(water_pond_contour_lo, water_pond_contour_hi, pond);
	float shore = calib_window(water_shore_lo, water_shore_hi, max(stream, lake_gate)) * (1.0 - wet) * dry;
	vec3 shore_col = vec3(0.42, 0.37, 0.29) * (0.85 + 0.3 * breakup);
	terr = mix(terr, shore_col, shore * 0.35);
	terr *= 1.0 - shore * 0.22;

	float lake_depth = clamp((pond - water_lake_depth_lo) / max(water_lake_depth_span, 1e-6), 0.0, 1.0) * lakeMask;
	float depth = clamp(max(lake_depth, stream), 0.0, 1.0);
	float speed = riverMask >= lakeMask ? 1.0 : 0.25;
	vec2 d1 = normalize(length(dir) > 0.05 ? dir : vec2(0.7, 0.7));
	vec2 d2 = vec2(-d1.y, d1.x);
	float p1 = dot(wp, d1) * 2.3 - u_time * 5.0 * speed;
	float p2 = dot(wp, d2) * 4.1 + dot(wp, d1) * 1.3 - u_time * 3.1 * speed;
	float p3_wave = dot(wp, d1 + d2) * 6.3 - u_time * 7.3 * speed + 1.7;
	float ripple_fade = 1.0 - smoothstep(50.0 * ws, 160.0 * ws, view_dist);
	// Amplituden-Fenster der Kräusel: eigene Optik-Zahl dieses Shaders —
	// numerisch zufällig gleich dem geometry_lift-Fenster, KEINE
	// WaterRender-Konstante (das Band nutzt ein anderes Fenster, 0.02..0.05).
	float amp = mix(0.015, 0.05, depth) * ripple_fade;
	amp *= riverMask >= lakeMask ? 1.0 : 0.45;
	vec2 grad = d1 * (2.3 * cos(p1)) * amp
	          + (d2 * 4.1 + d1 * 1.3) * (0.6 * cos(p2)) * amp
	          + (d1 + d2) * (6.3 * cos(p3_wave)) * (0.25 * amp);
	vec3 water_n_ws = normalize(vec3(-grad.x, 1.0, -grad.y));
	vec3 water_n_vs = normalize(mat3(VIEW_MATRIX) * water_n_ws);
	NORMAL = normalize(mix(NORMAL, water_n_vs, wet));

	vec3 water = mix(water_shallow_color, water_deep_color, depth);
	vec3 bed = terr * mix(1.0, 0.55, wet);
	float opacity = mix(water_opacity_shallow, water_opacity_deep, depth);
	float ndv = clamp(dot(water_n_vs, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, max(water_fresnel_exponent, 1e-6));
	water = mix(water, water_sky_reflect_color, fresnel * water_fresnel_sky_mix);

	if (riverMask >= lakeMask && length(dir) > 0.05) {
		float along = dot(wp, normalize(dir));
		float flow = sin(along * 1.4 - u_time * 4.0) * 0.5
			+ sin(along * 3.1 - u_time * 6.5 + 1.7) * 0.5;
		water += flow * water_flow_shimmer_color;
	}

	float edge = wet * (1.0 - wet) * 4.0;
	float foam_n = vnoise(wp * 7.0 - dir * u_time * 2.5 + vec2(0.0, u_time * 0.4));
	// Schaum-Schwellen: eigene Optik-Zahl — numerisch zufällig gleich dem
	// Deckkraft-Paar (water_opacity_*), KEINE WaterRender-Konstante.
	float foam = smoothstep(0.55, 0.95, edge * (0.45 + 0.75 * foam_n)) * ripple_fade;
	vec3 water_final = mix(bed, water, opacity);
	water_final = mix(water_final, vec3(0.88, 0.92, 0.94), foam * 0.45);
	ALBEDO = mix(terr, water_final, wet);
	ROUGHNESS = mix(land_roughness, mix(water_roughness_steep, water_roughness_grazing, fresnel), wet);
	METALLIC = 0.0;
	SPECULAR = mix(0.5, mix(water_specular_steep, water_specular_grazing, fresnel), wet);
}

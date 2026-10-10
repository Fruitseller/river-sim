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
// RENDER-VERSCHIEBUNG (#153): grobe Erosionsrinnen (~2,5 km Wellenlänge) und
// einseitig geschärfte Grate als ECHTE Verschiebung mit Silhouette und
// Schattenwurf. Gerechnet einmal je Terrain-Update in relief_bake.gdshader
// (dieselbe runevision-Funktion wie das feine Detail, nur gröber); hier wird
// nur gelesen: die Vertex-Stufe die Höhe, die Pixel-Stufe Steigung und
// Rinnen-Schattierung. An Wasser ist sie per Schutzmaske null, Seen bleiben
// flach auf ihrem Spiegel. Die Physik bleibt unberührt.
//
// KRONENDACH (#152): Wald als angehobenes Dach (~20 m) mit Einzelkronen von
// ~11 m (Laubbaum als Kuppel, Nadelbaum als Kegel), dunklen Lücken und
// Selbstschatten zum Kronenrand. WO Wald steht, sagt allein forest_tex
// (SimRender.ForestCanopyMask, endet an der Schutzmaske); hier entstehen nur
// Anhebung und Kronen. In der Entfernung geht das Muster in seinen Mittelwert
// über.
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
// Abfluss-Dichte fürs Erosions-Detail (R8, WaterFieldRenderer.flowDetailField):
// log-normierte MFD-Abflussdichte unterhalb der Wasser-Sichtbarkeitsschwelle.
// Bündelt die kosmetischen Rinnen in echten Abflussbahnen — ohne die Bindung
// degeneriert der Layer auf gealterten, gleichförmig flachen Hängen zu einem
// uniformen Tapeten-Muster (PR #106). Kalibrierung: WaterRender (SimCore).
uniform sampler2D flow_tex : filter_linear, repeat_disable;
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
uniform float detail_strength = 0.16; // Jahr-0-Default; Main.gd fährt bis 0.42 bei 100k hoch
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

// Render-Verschiebung (#153). Der Schalter ist keine Kalibrier-Zahl: ohne
// SimNode (Editor-Vorschau) ist keine Backtextur gebunden, und eine schwarze
// Textur dekodierte zu −2 Einheiten Höhe.
uniform bool relief_enabled = false;
uniform sampler2D relief_tex : filter_linear, repeat_disable;
// Vorheriger Back-Stand und Blende dorthin (`bake_blend`, Main.gd `_bake_relief`): im
// Zeitraffer gleitet die Verschiebung über einen Sim-Takt, statt zu springen.
// Die Kodierung ist linear, gemischt wird also direkt auf den Kanälen.
uniform sampler2D relief_prev_tex : filter_linear, repeat_disable;
uniform float bake_blend = 1.0;
// Kalibrierung über die Brücke (SimCore.ReliefRender), default-frei.
uniform float relief_height_code;
uniform float relief_slope_code;
uniform float relief_shade_dark;
uniform float relief_shade_light;
// Echte Verformung blendet mit dem Geländealter ein (ReliefRender.geometryAgeYears);
// Main.gd setzt `sim_year` bei jedem Höhen-Upload.
uniform float relief_geometry_age;
uniform float sim_year = 0.0;
// Kronendach (#152). Der Schalter ist keine Kalibrier-Zahl: ohne SimNode
// (Editor-Vorschau) ist keine Waldmaske gebunden.
uniform bool canopy_enabled = false;
// Schwarz, solange nichts gebunden ist: kein Wald statt einer weißen Fläche.
uniform sampler2D forest_tex : filter_linear, repeat_disable, hint_default_black;
// Vorheriger Stand und Blende dorthin wie bei der Verschiebung (`bake_blend`):
// im Zeitraffer gleitet der Wald über einen Sim-Takt, statt kronenweise zu
// springen.
uniform sampler2D forest_prev_tex : filter_linear, repeat_disable, hint_default_black;
// Kalibrierung über die Brücke (SimCore.CanopyRender), default-frei.
uniform float canopy_cell;
uniform float canopy_height;
uniform float canopy_lift_lo;
uniform float canopy_lift_hi;
uniform float canopy_cover_lo;
uniform float canopy_cover_hi;
uniform float canopy_gap_lo;
uniform float canopy_gap_hi;
uniform float canopy_crown_mid;
uniform float canopy_crown_spread;
uniform float canopy_crown_radius;
uniform float canopy_crown_radius_jitter;
uniform float canopy_detail_lo;
uniform float canopy_detail_hi;
// Nadelbaum-Anteil nach Höhenband (HeightBands.coniferShare, über
// SimNode.heightBands, gesetzt mit jedem Overlay-Upload).
uniform float conifer_lo;
uniform float conifer_hi;

varying float v_forest;

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

// Phacelle-Noise + Erosionsfilter (runevision, MPL-2.0): erosion_filter.gdshaderinc.
#include "res://shaders/erosion_filter.gdshaderinc"

// Produktions-Detail: feine Rinnen mit den Uniform-Werten. Die Skala ist ein
// Parameter, damit die Flusstal-Studie dieselbe Funktion grob als echte
// Verschiebung nutzen kann, statt den MPL-Code zu kopieren.
vec4 erosion_detail(vec2 p, vec2 slope, float fade_target_in, out float out_mag) {
	return erosion_detail_at(p, slope, fade_target_in, detail_scale, detail_strength, out_mag);
}

// Render-Verschiebung aus der Backtextur (Kodierung: relief_bake.gdshader).
vec4 relief_sample(vec2 uv) {
	vec4 cur = textureLod(relief_tex, uv, 0.0);
	if (bake_blend < 1.0) {
		cur = mix(textureLod(relief_prev_tex, uv, 0.0), cur, bake_blend);
	}
	return cur;
}

// Höhenzuschlag in Welteinheiten, mit dem Alter eingeblendet (gleiche Formel
// wie Main.gd `relief_geometry_fade`) …
float relief_lift(vec2 uv) {
	if (!relief_enabled) {
		return 0.0;
	}
	return (relief_sample(uv).r - 0.5) / max(relief_height_code, 1e-6)
	     * smoothstep(0.0, relief_geometry_age, sim_year);
}

// … Steigungszuschlag dh/duv je Pixel (Detail unabhängig von der Mesh-Dichte) …
vec2 relief_slope(vec2 uv) {
	if (!relief_enabled) {
		return vec2(0.0);
	}
	return (relief_sample(uv).gb - 0.5) / max(relief_slope_code, 1e-6);
}

// … und Rinnen (−1) bis Rippen (+1).
float relief_cavity(vec2 uv) {
	if (!relief_enabled) {
		return 0.0;
	}
	return (relief_sample(uv).a - 0.5) * 2.0;
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

// Kronendach je Pixel (#152, aus der Flusstal-Studie übernommen): Voronoi-
// Kronen, je Zelle eine mit Zufallsversatz und -radius. Die Farben, Radien und
// Neigungen hier sind Optik dieses Shaders wie die Ufer- und Kiesfarben unten,
// keine Kalibrierung; die Schwellen kommen über die Brücke.
void canopy(vec2 wp, float h, vec3 macro_n, inout vec3 color, inout vec3 n,
            inout float rough) {
	float f = v_forest;
	if (f <= 0.002) {
		return;
	}
	float conifer_share = clamp((h - conifer_lo) / max(conifer_hi - conifer_lo, 1e-6), 0.1, 0.9);
	vec2 p = wp / max(canopy_cell, 1e-6);
	vec2 g = floor(p);
	float best = 0.0;
	vec2 tilt = vec2(0.0);
	float tint = 0.0;
	float con = 0.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 c = g + vec2(float(i), float(j));
			vec2 r1 = ehash(c);
			vec2 r2 = ehash(c + vec2(17.3, 5.1));
			// Krone steht nur, wo die Waldmaske ihre eigene Schwelle
			// übertrifft: am Rand dünnt der Wald so kronenweise aus.
			if (f < canopy_crown_mid + canopy_crown_spread * r2.y) {
				continue;
			}
			vec2 d = p - (c + 0.5 + r1 * 0.30);
			float rad = canopy_crown_radius + canopy_crown_radius_jitter * r2.x;
			float dd = length(d);
			bool is_con = (r1.x * 0.5 + 0.5) < conifer_share;
			float hgt = is_con ? (rad - dd) * 1.7 : sqrt(max(rad * rad - dd * dd, 0.0));
			if (hgt > best) {
				best = hgt;
				tilt = is_con ? d / max(dd, 1e-4) * 1.7 : d / max(hgt, 0.12);
				tint = r1.y * 0.5 + 0.5;
				con = is_con ? 1.0 : 0.0;
			}
		}
	}
	vec3 decid = vec3(0.105, 0.175, 0.055) * mix(0.75, 1.25, tint);
	vec3 conif = vec3(0.050, 0.098, 0.060) * mix(0.8, 1.2, tint);
	vec3 crown = mix(decid, conif, con) * mix(0.55, 1.0, clamp(best / 0.6, 0.0, 1.0));
	vec3 gap = vec3(0.022, 0.034, 0.020);
	float inside = calib_window(canopy_gap_lo, canopy_gap_hi, f); // Lücken nur im Bestand dunkel
	vec3 avg = mix(mix(decid, conif, conifer_share) * 0.8, gap, 0.3);
	// Ab etwa einer Krone je Pixel nur noch der Mittelwert: kein Flimmern.
	float detail = 1.0 - calib_window(canopy_detail_lo, canopy_detail_hi, length(fwidth(p)));
	float covered = best > 0.0 ? 1.0 : inside;
	vec3 near_col = best > 0.0 ? crown : gap;
	vec3 col = mix(avg, near_col, detail);
	float amount = mix(calib_window(canopy_cover_lo, canopy_cover_hi, f), covered, detail);
	color = mix(color, col, amount);
	vec3 t = vec3(clamp(tilt.x, -2.0, 2.0), 0.0, clamp(tilt.y, -2.0, 2.0)) * 0.85 * detail;
	n = normalize(mix(n, normalize(macro_n + t), amount));
	rough = mix(rough, 0.92, amount);
}

// Studien-Schichten: nur im FLUSSTAL_STUDY-Build eingebunden (Präprozessor).
// Der normale Spiel-Shader überspringt Includes UND Aufrufe komplett — keine
// Studien-Uniforms in Produktion, und `studies/` darf verschoben werden, ohne
// den Hauptshader zu brechen (Review zu #121). Flusstal.gd setzt das Define
// zur Laufzeit vor diese Quelle (Godot 4.7 erlaubt #define vor shader_type).
// Die Includes stehen HIER, weil die Studie die Höhenfelder und Noise-Helfer
// darüber mitbenutzt.
#ifdef FLUSSTAL_STUDY
#include "res://studies/flusstal/materials.gdshaderinc"
#include "res://studies/flusstal/landscape.gdshaderinc"
#endif
// Wolkenschatten (#151): gemeinsame Funktion mit Ozean und Bändern.
#include "res://shaders/clouds.gdshaderinc"

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
	// Seen hebt die Zeile selbst auf den Spiegel; dort keine Verschiebung.
	VERTEX.y = mix(hraw, hfv, lift) * hscale + relief_lift(uv) * (1.0 - lift);
	// Kronendach: Waldkanten werfen Schatten. An Wasser ist die Maske null.
	v_forest = 0.0;
	if (canopy_enabled) {
		v_forest = textureLod(forest_tex, uv, 0.0).r;
		if (bake_blend < 1.0) {
			v_forest = mix(textureLod(forest_prev_tex, uv, 0.0).r, v_forest, bake_blend);
		}
	}
	VERTEX.y += calib_window(canopy_lift_lo, canopy_lift_hi, v_forest) * canopy_height;
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
	coarse_slope += relief_slope(v_uv);

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
		// Stärke folgt dem echten Abfluss (WaterRender.flowDetailGainLo/Hi):
		// Rinnen bündeln sich in Abflussbahnen, abseits davon beruhigt sich
		// der Layer unter den früheren Uniform-Look.
		float flow_gain = mix(0.3, 1.8, texture(flow_tex, v_uv).r);
		det_slope = det.yz * dfade * detail_normal * flow_gain;
		det_shade = det.x / det_mag * dfade * flow_gain;
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
	// UNGESTÖRTE Makro-Normale sichern, bevor die Mikro-Normale sie verändert:
	// die Studien-Materialfunktion braucht sie für Triplanar-Gewichte und
	// Vorzeichenkorrektur ohne Mikro-Rauschen (Review zu #121).
	vec3 macro_n = n_ws;
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
	// Rinnenböden dunkler, Rippen heller (grobe Verschiebung, #153).
	if (hval > sea_level + 0.012) {
		float cavity = relief_cavity(v_uv);
		terr *= 1.0 + (cavity < 0.0 ? cavity * relief_shade_dark : cavity * relief_shade_light);
	}

	float ice_hint = smoothstep(0.04, 0.16, macro_color.b - macro_color.r) * cold;
	float land_roughness = mix(0.90, 0.68, rock);
	land_roughness = mix(land_roughness, 0.84, vegetation);
	land_roughness = mix(land_roughness, 0.78, cold);
	land_roughness = mix(land_roughness, 0.34, ice_hint);
	land_roughness += (tri_grain - 0.5) * 0.08 * material_fade;
	// Studien-Material nur im FLUSSTAL_STUDY-Build (Flusstal.gd setzt das
	// Define zur Laufzeit) und NUR über Wasser: unterhalb der
	// Meeresspiegel-Grenze bleibt das Flussbett bei der Standard-Optik, der
	// helle mineralische FlussRAND über der Wasserlinie (Soča-Referenz,
	// docs/graphics-quality.md) bleibt erhalten. Gate wie bei der Mikro-Normale.
#ifdef FLUSSTAL_STUDY
	if (study_enabled && hval > sea_level + 0.012) {
		study_material(material_pos, cold, rock, vegetation, soil_w, macro_n,
		               terr, n_ws, land_roughness);
	}
#endif
	// Ufersaum, Wasser und Meer trägt die Waldmaske schon nicht.
	canopy(wp, hval, macro_n, terr, n_ws, land_roughness);
#ifdef FLUSSTAL_STUDY
	study_debug_view(v_uv, v_forest, terr);
#endif
	NORMAL = normalize(mat3(VIEW_MATRIX) * n_ws);

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
	vec3 shore_col = mix(vec3(0.38, 0.34, 0.28), vec3(0.48, 0.42, 0.34), breakup);
	terr = mix(terr, shore_col, shore * 0.55);
	terr *= 1.0 - shore * 0.28;
	land_roughness = mix(land_roughness, 0.36, shore * 0.55);

	// Flussbett: Geröll, Kiesel und Schwemmsand statt Wiese unter dem Wasser
	vec3 river_gravel = mix(vec3(0.33, 0.30, 0.26), vec3(0.46, 0.42, 0.36), breakup);
	river_gravel *= mix(0.85, 1.15, vnoise(wp * 4.5));
	terr = mix(terr, river_gravel, riverMask * 0.88);

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
	ALBEDO *= cloud_light(wp - world_size * 0.5, u_time);
}

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
// SimRender.CalibrationRegistry → SimNode → Main.gd, Issues #91/#92) — hier steht
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
// MATERIAL-LAYER (davon UNABHÄNGIG): aus surface_tex und cover_tex werden
// Grund, Vegetation, Fels, Schutthalden, Schnee, Gletschereis und Rohboden in
// Weltkoordinaten prozedural aufgebaut (Körnung, Klüftung, Gesteinsschichten,
// Spalten, Moränen, Windverfrachtung, Mikro-Normale). WO welches Material
// liegt, rechnet SimRender.TerrainColorRenderer (Kalibrierung
// SimCore.MaterialRender, Issue #174 D); hier entsteht nur, WIE es aussieht.
// Eigener Schalter `material_enabled` — wer `detail_enabled` abschaltet, um
// die Erosionsrinnen zu isolieren, behält damit die Materialien.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D hf_tex : filter_linear, repeat_disable; // gefüllte Oberfläche (Seespiegel)
uniform sampler2D color_tex : filter_linear, repeat_disable; // RGB Makrofarbe, A Sandgewicht max(Strand, Bank) (#174 C/C2)
uniform sampler2D surface_tex : filter_linear, repeat_disable; // R Vegetation, G Fels, B Schnee/Eis, A Lithologie
// Bodenbedeckung (#174 D): R Schutthalde, G blankes Gletschereis (Anteil an B
// von surface_tex), B Rohboden (frisch gestört), A Talboden-Wiese. Schwarz,
// solange nichts gebunden ist (Editor-Vorschau): keine dieser Schichten.
uniform sampler2D cover_tex : filter_linear, repeat_disable, hint_default_black;
// Zeitraffer-Überblenden (#172, Main.gd `Crossfade`): der Vorgängerstand je
// Textur und zwei Blenden, jede im Takt IHRES Uploads. `height_blend` folgt
// dem Sim-Takt (Höhe), `overlay_blend` der Overlay-Drossel (Farbe, Material,
// Rinnen-Detail, Seespiegel, Wald, Raster-Wasser). Gelesen wird nur über die
// `*_at`-Helfer unten, damit Form, Normalen und Farbe denselben Zwischenstand
// zeigen.
uniform sampler2D height_prev_tex : filter_linear, repeat_disable;
uniform sampler2D hf_prev_tex : filter_linear, repeat_disable;
uniform sampler2D color_prev_tex : filter_linear, repeat_disable;
uniform sampler2D surface_prev_tex : filter_linear, repeat_disable;
uniform sampler2D cover_prev_tex : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D flow_prev_tex : filter_linear, repeat_disable;
uniform sampler2D water_prev_tex : filter_linear, repeat_disable;
uniform float height_blend = 1.0;
uniform float overlay_blend = 1.0;
uniform sampler2D debug_difference_tex : filter_linear, repeat_disable;
uniform sampler2D water_tex : filter_linear, repeat_disable;
// Abfluss-Dichte fürs Erosions-Detail (R8, WaterFieldRenderer.flowDetailField):
// log-normierte MFD-Abflussdichte unterhalb der Wasser-Sichtbarkeitsschwelle.
// Bündelt die kosmetischen Rinnen in echten Abflussbahnen — ohne die Bindung
// degeneriert der Layer auf gealterten, gleichförmig flachen Hängen zu einem
// uniformen Tapeten-Muster (PR #106). Kalibrierung: WaterRender (SimCore).
uniform sampler2D flow_tex : filter_linear, repeat_disable;
// Default == RenderContract.heightScale (Issue #51). Im Spiel setzt Main.gd
// den Uniform mit dem Wert aus der Brücke (Gruppe `contract`, Issue #213); der Default zählt, wo das Material OHNE
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

// Detail-Erosion: Stärke = Höhenamplitude relativ zur Skala (wie im
// Original). Skala, Schattierung und Normalen-Anteil kommen default-frei aus
// SimCore.ReliefRender (relief_detail_*, Uniform-Weg wie die Verschiebung).
uniform float detail_strength = 0.16; // Jahr-0-Default; Main.gd fährt bis 0.42 bei 100k hoch
uniform bool detail_enabled = true;
// Materialschicht: getrennt schaltbar vom Detail-Layer darüber, weil beides
// verschiedene Dinge sind (Erosionsrinnen vs. Gesteins- und Bodenmaterial).
// Main.gd hängt beide an `render_quality`; abgeschaltet entfällt der KOMPLETTE
// Noise-Aufwand dieser Schicht, nicht nur der ausgeblendete Teil.
uniform bool material_enabled = true;
uniform bool debug_difference = false;

// Wasser-Kalibrierung über die Brücke (Issues #91/#92): Main.gd setzt die
// Werte beim Aufbau aus SimRender.CalibrationRegistry. BEWUSST ohne Default — ein
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
uniform float water_wall_slope_lo;
uniform float water_wall_slope_hi;
uniform float water_shore_lo;
uniform float water_shore_hi;
uniform float water_pond_contour_lo;
uniform float water_pond_contour_hi;
uniform float water_geometry_lift_lo;
uniform float water_geometry_lift_hi;
uniform float water_lake_depth_lo;
uniform float water_lake_depth_span;
uniform float water_river_depth_lo;
uniform float water_river_depth_hi;
uniform float water_fresnel_exponent;
uniform float water_opacity_shallow;
uniform float water_opacity_deep;
uniform float water_roughness;
uniform float water_specular;
uniform vec3 water_shallow_color;
uniform vec3 water_deep_color;
uniform vec3 water_flow_shimmer_color;
uniform vec3 water_bed_color;
// Lauf-Wechsel des Raster-Wassers (Look-Iteration 14, wie CUSTOM0 der
// Bänder): Riffel und Weißwasser aus dem Längsgefälle der Rinnensohle
// (`world_slope`), Seen spiegeln die Wolken.
uniform float water_raster_steep_lo;
uniform float water_raster_steep_hi;
uniform vec3 water_riffle_color;
uniform float water_riffle_depth;
uniform vec3 water_foam_color;
uniform float water_foam_amount;
uniform float water_river_specular;
uniform float water_cloud_reflection;
uniform vec3 water_lake_color;
// Sand-Material (Issue #174 C2, auch Strand aus C): WO Sand liegt, sagen
// SimRender.BarMaterial und CoastMaterial (A-Kanal von color_tex, max beider);
// wie er aussieht, diese Werte.
uniform vec3 water_bar_sand_color;
uniform vec3 water_bar_sand_wet_color;
uniform float water_bar_roughness;
// Meeresstrand (Hill-Climber Nr. 8): nasser Sand an der Wasserlinie, heller
// trockener dahinter, klare Rückkante. Gilt nur bis water_beach_height_hi
// über dem Meer; Bänke im Binnenland behalten die Farben oben.
uniform vec3 water_beach_dry_color;
uniform vec3 water_beach_wet_color;
uniform float water_beach_wet_height;
uniform float water_beach_height_hi;
uniform float water_beach_blend_height;
uniform float water_beach_edge_lo;
uniform float water_beach_edge_hi;

// Render-Verschiebung (#153). Der Schalter ist keine Kalibrier-Zahl: ohne
// SimNode (Editor-Vorschau) ist keine Backtextur gebunden, und eine schwarze
// Textur dekodierte zu −2 Einheiten Höhe.
uniform bool relief_enabled = false;
uniform sampler2D relief_tex : filter_linear_mipmap_anisotropic, repeat_disable;
// Vorheriger Back-Stand und Blende dorthin (`bake_blend`, Main.gd `_bake_relief`): im
// Zeitraffer gleitet die Verschiebung über einen Sim-Takt, statt zu springen.
// Die Kodierung ist linear, gemischt wird also direkt auf den Kanälen.
uniform sampler2D relief_prev_tex : filter_linear_mipmap_anisotropic, repeat_disable;
uniform float bake_blend = 1.0;
// Kalibrierung über die Brücke (SimCore.ReliefRender), default-frei.
uniform float relief_height_code;
uniform float relief_slope_code;
uniform float relief_shade_dark;
uniform float relief_shade_light;
uniform float relief_detail_scale;
uniform float relief_detail_shade;
uniform float relief_detail_normal;
// Echte Verformung blendet mit dem Geländealter ein (ReliefRender.geometryAgeYears);
// Main.gd setzt `sim_year` bei jedem Höhen-Upload.
uniform float relief_geometry_age;
uniform float sim_year = 0.0;
// Kronendach (#152). Der Schalter ist keine Kalibrier-Zahl: ohne SimNode
// (Editor-Vorschau) ist keine Waldmaske gebunden.
uniform bool canopy_enabled = false;
// Schwarz, solange nichts gebunden ist: kein Wald statt einer weißen Fläche.
uniform sampler2D forest_tex : filter_linear, repeat_disable, hint_default_black;
// Vorheriger Stand: im Zeitraffer gleitet der Wald mit `overlay_blend` wie
// Farbe und Material, statt kronenweise zu springen. NICHT `bake_blend`: die
// Verschiebung backt jeden Sim-Takt, die Waldmaske kommt nur mit den
// gedrosselten Overlays; geteilt sprang der Wald an jedem Takt ohne neue Maske
// auf den alten Stand zurück und glitt wieder vor (#170).
uniform sampler2D forest_prev_tex : filter_linear, repeat_disable, hint_default_black;
// Kalibrierung über die Brücke (SimCore.CanopyRender), default-frei.
uniform float canopy_cell;
uniform float canopy_height;
uniform float canopy_lift_lo;
uniform float canopy_lift_hi;
uniform float canopy_lift_smooth_texels;
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
uniform float canopy_meadow_lo;
uniform float canopy_meadow_hi;
uniform float canopy_meadow_share;
// Nadelbaum-Anteil nach Höhenband (HeightBands.coniferShare, über
// SimNode.heightBands, gesetzt mit jedem Overlay-Upload).
uniform float conifer_lo;
uniform float conifer_hi;
// Material-Kalibrierung über die Brücke (SimCore.MaterialRender, #174 D),
// default-frei. Mit Null-Uniforms (Editor-Vorschau) bleibt jede Schicht total:
// die Fenster laufen über calib_window, die Abstände über max().
uniform float material_ridge_rock_gain;
uniform float material_gully_scree_share;
uniform float material_joint_spacing;
uniform float material_joint_stretch;
uniform float material_joint_turn_cos;
uniform float material_joint_turn_sin;
uniform float material_joint_depth;
uniform float material_joint_gully_gain;
uniform float material_rock_relief_gain;
uniform float material_joint_relief;
uniform float material_scree_grain;
uniform float material_crevasse_spacing;
uniform float material_crevasse_slope_lo;
uniform float material_crevasse_slope_hi;
uniform float material_moraine_lo;
uniform float material_moraine_hi;
// Look-Iteration 7: Schnee nach der Form, ausfransende Felsgrenze, Felsköpfe.
uniform float material_snow_cavity;
uniform float material_snow_slope_lo;
uniform float material_snow_slope_hi;
uniform float material_snow_breakup;
uniform float material_rock_fray;
uniform float material_redistribute_fade;
uniform float material_outcrop;
uniform float material_outcrop_slope_lo;
uniform float material_outcrop_slope_hi;
uniform float material_scree_streak;

varying float v_forest;
// Bestands-Rauschen des Kronendachs (x ~180 m, y ~770 m): so grob, dass es
// je Vertex (~15 m) genügt; je Pixel kostete es messbar Bildzeit.
varying vec2 v_stand;

varying vec2 v_uv;
// Welt-xz des Vertex (das Terrain-Mesh liegt im Ursprung): Materialien und
// Wasser rechnen in Weltkoordinaten, die Texturen über `world_uv`.
varying vec2 v_xz;

// Kalibrier-Fenster, total auch mit Null-Uniforms (Editor-Vorschau ohne
// SimNode, s. Deklarationsblock oben): das Epsilon ist KEINE Kalibrier-Kopie,
// nur eine Mindest-Fensterbreite gegen GLSL-undefiniertes smoothstep; mit
// gesetzten Werten (hi > lo) ändert das max() nichts.
float calib_window(float lo, float hi, float x) {
	return smoothstep(lo, max(hi, lo + 1e-6), x);
}

// Lesezugriffe auf die überblendeten Felder (#172). Ohne laufende Blende
// genau ein Texturzugriff wie vorher.
float height_at(vec2 uv) {
	float h = texture(height_tex, uv).r;
	return height_blend < 1.0 ? mix(texture(height_prev_tex, uv).r, h, height_blend) : h;
}

float hf_at(vec2 uv) {
	float h = texture(hf_tex, uv).r;
	return overlay_blend < 1.0 ? mix(texture(hf_prev_tex, uv).r, h, overlay_blend) : h;
}

// RGB = Makrofarbe, A = Sandgewicht: max(Strand, frische Gleithang-Bank) (#174 C/C2).
vec4 color_at(vec2 uv) {
	vec4 c = texture(color_tex, uv);
	return overlay_blend < 1.0 ? mix(texture(color_prev_tex, uv), c, overlay_blend) : c;
}

vec4 surface_at(vec2 uv) {
	vec4 m = texture(surface_tex, uv);
	return overlay_blend < 1.0 ? mix(texture(surface_prev_tex, uv), m, overlay_blend) : m;
}

vec4 cover_at(vec2 uv) {
	vec4 c = texture(cover_tex, uv);
	return overlay_blend < 1.0 ? mix(texture(cover_prev_tex, uv), c, overlay_blend) : c;
}

float flow_at(vec2 uv) {
	float f = texture(flow_tex, uv).r;
	return overlay_blend < 1.0 ? mix(texture(flow_prev_tex, uv).r, f, overlay_blend) : f;
}

// Raster-Wasser (#174): die EWMA (`water_blend`) glättet nur von Upload zu
// Upload; dazwischen sprang das Feld je Overlay-Upload (gemessen bei 60 J/s:
// je Upload ~10 % der nassen Zellen um mehr als 0,1 Sichtbarkeit).
vec4 water_at(vec2 uv) {
	vec4 w = texture(water_tex, uv);
	return overlay_blend < 1.0 ? mix(texture(water_prev_tex, uv), w, overlay_blend) : w;
}

// UV aus der Weltposition ableiten (statt Mesh-UV) → deckungsgleich mit der
// Zellindizierung des Sim-Kerns und damit mit Flüssen/Wasser. Texelzentriert:
// Zelle k liegt bei −world_size/2 + k·world_size/(grid_n − 1) (Mesh, Main.gd
// `step`) und ist Texel k mit Mitte (k + ½)/grid_n. Bis zum Review zu #174
// stand hier (x + world_size/2)/world_size; das traf die Mitte, wich zum Rand
// hin aber um bis zu einen halben Texel ab (am Rand ~8 m).
vec2 world_uv(vec3 vert) {
	float n = max(grid_n, 2.0);
	return ((vert.xz / world_size + 0.5) * (n - 1.0) + 0.5) / n;
}

// Wassersäule des ratenbegrenzten Seespiegels über dem Terrain (0 = trocken;
// das Meer hat seine eigene Wasserebene). height_tex/hf_tex sind das VOLLE
// Sim-Gitter, bilinear gefiltert — die Null-Linie dieses Felds ist damit eine
// glatte Kontur auf dem Sim-Gitter (Shader-Äquivalent von Marching Squares),
// nicht die Treppe des Render-Gitters (Issue #32). hf = waterLevel → die
// Kontur erbt das Anti-Sägezahn-Verhalten.
float pond_of(float hf_val, float h_val) {
	return max(hf_val - h_val, 0.0) * step(sea_level, hf_val);
}

float pond_at(vec2 uv, float h_val) {
	return pond_of(hf_at(uv), h_val);
}

// Sichtbarkeits-Gate der Seen (water_tex.g: Komponenten-Fade, geblurt) — WO
// Wasser gemalt/gehoben wird; die FORM macht pond_at. Das Fenster lässt den
// Blur-Halo am Ufer durch und schaltet ab WaterRender.lakeGateHi voll
// (Kalibrier-Herleitung: WaterFieldRenderer, fadeLo/HiCells).
float lake_gate_at(vec2 uv) {
	return calib_window(water_lake_gate_lo, water_lake_gate_hi, water_at(uv).g);
}

// Phacelle-Noise + Erosionsfilter (runevision, MPL-2.0): erosion_filter.gdshaderinc.
#include "res://shaders/erosion_filter.gdshaderinc"

// Produktions-Detail: feine Rinnen mit den Uniform-Werten. Die Skala ist ein
// Parameter, damit die Flusstal-Studie dieselbe Funktion grob als echte
// Verschiebung nutzen kann, statt den MPL-Code zu kopieren. Das max() hält
// die Editor-Vorschau ohne SimNode (Null-Uniform) total, keine Kalibrierung.
vec4 erosion_detail(vec2 p, vec2 slope, float fade_target_in, out float out_mag) {
	// Zwei Oktaven statt drei (Look-Iteration 7): die feinste (~17 m) lag
	// unter den gebackenen Felsrippen und kostete je Pixel Bildzeit.
	return erosion_detail_at(p, slope, fade_target_in, max(relief_detail_scale, 1e-4), detail_strength, 2, out_mag);
}

#include "res://shaders/amplify.gdshaderinc"

// Render-Verschiebung aus der Backtextur (Kodierung: relief_bake.gdshader),
// auf fester Mip-Stufe. Die Backtextur des SubViewports hat nur Stufe 0, die
// Fläche der Gelände-Verfeinerung (#238) eine Kette.
vec4 relief_sample(vec2 uv, float lod) {
	vec4 cur = textureLod(relief_tex, uv, lod);
	if (bake_blend < 1.0) {
		cur = mix(textureLod(relief_prev_tex, uv, lod), cur, bake_blend);
	}
	return cur;
}

// Höhenzuschlag in Welteinheiten, mit dem Alter eingeblendet (gleiche Formel
// wie Main.gd `relief_geometry_fade`) …
float relief_lift(vec2 uv) {
	if (!relief_enabled) {
		return 0.0;
	}
	return (relief_sample(uv, amplify_vertex_lod).r - 0.5) / max(relief_height_code, 1e-6)
	     * smoothstep(0.0, relief_geometry_age, sim_year);
}

// Pixel-Stufe: EIN Abgriff der Backtextur je Pixel für Steigung und Rinnen
// (vorher zwei, Review zu #174). Ohne Verschiebung neutral (0.5 = kein Zuschlag).
// Mit impliziter Mip-Stufe: die 2880²-Fläche der Verfeinerung (#238) flimmerte
// in der Ferne sonst. Nur im gleichförmigen Kontrollfluss rufen.
vec4 relief_pixel(vec2 uv) {
	if (!relief_enabled) {
		return vec4(0.5);
	}
	vec4 cur = texture(relief_tex, uv);
	if (bake_blend < 1.0) {
		cur = mix(texture(relief_prev_tex, uv), cur, bake_blend);
	}
	return cur;
}

// … Steigungszuschlag dh/duv je Pixel (Detail unabhängig von der Mesh-Dichte) …
vec2 relief_slope(vec4 relief) {
	return (relief.gb - 0.5) / max(relief_slope_code, 1e-6);
}

// … und Rinnen (−1) bis Rippen (+1).
float relief_cavity(vec4 relief) {
	return (relief.a - 0.5) * 2.0;
}


// Zufallswert −1 … 1 je ganzzahliger Rauschzelle. Bis zum Review zu #174
// lief das Wertrauschen über `ehash` aus dem Erosionsfilter; dessen
// Float-Produkt x·y·(x+y) verliert in float32 ab einigen Dutzend Zellen vom
// Ursprung die Bits hinter dem Komma. Weit weg von der Kartenmitte erstarrte
// das Rauschen damit zu wenigen Werten: Schutt-Körnung und Klüfte glatt,
// Gletscherspalten und Wasser-Kräuselung als Gitter. Hier wird der Zellindex
// ZUERST auf [0, 17) gefaltet: das Produkt bleibt unter ~10⁴, float32 behält
// dort zehn Nachkommabits. Rein Float (wie vorher): ein Ganzzahl-Hash (pcg)
// kostete gemessen bis zu 4 ms je Bild (docs/zielbild-measurements.md).
float vhash(vec2 c) {
	const vec2 k = vec2(0.3183099, 0.3678794);
	vec2 x = fract(c * k) * 17.0 + k.yx;
	return fract(16.0 * k.x * fract(x.x * x.y * (x.x + x.y))) * 2.0 - 1.0;
}

// Billiges Value-Noise (2 Oktaven) für Breakup/Schaum — de-uniformiert Flächen.
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = vhash(i);
	float b = vhash(i + vec2(1.0, 0.0));
	float c = vhash(i + vec2(0.0, 1.0));
	float d = vhash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 0.5 + 0.5;
}

// Dasselbe Wertrauschen mit analytischer Ableitung: (Wert 0 … 1, d/dp.x,
// d/dp.y), aus denselben vier Zellwerten. Die Felsrunsen bekommen daraus ihre
// Normale, ohne das Rauschen ein zweites Mal abzufragen.
vec3 vnoise_d(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	vec2 du = 6.0 * f * (1.0 - f);
	float a = vhash(i);
	float b = vhash(i + vec2(1.0, 0.0));
	float c = vhash(i + vec2(0.0, 1.0));
	float d = vhash(i + vec2(1.0, 1.0));
	float k4 = a - b - c + d;
	float v = a + (b - a) * u.x + (c - a) * u.y + k4 * u.x * u.y;
	vec2 g = du * vec2(b - a + k4 * u.y, c - a + k4 * u.x);
	return vec3(v * 0.5 + 0.5, g * 0.5);
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

// Projektionen unter 2 % Gewicht entfallen (Review zu #174, wie in
// `rock_joints`): auf flachem und mäßig steilem Land rechnet so nur die
// Draufsicht, sechs der neun Rauschabfragen fallen weg. Die Gewichte werden
// um die Schwelle abgesenkt statt abgeschnitten und neu normiert, damit der
// Wert stetig bleibt, wenn eine Projektion zu- oder wegfällt.
float triplanar_fbm(vec3 p, vec3 n) {
	vec3 weight = pow(abs(n), vec3(4.0));
	weight /= max(weight.x + weight.y + weight.z, 0.0001);
	weight = max(weight - 0.02, 0.0);
	float sum = 0.0;
	if (weight.x > 0.0) { sum += fbm(p.yz) * weight.x; }
	if (weight.y > 0.0) { sum += fbm(p.xz) * weight.y; }
	if (weight.z > 0.0) { sum += fbm(p.xy) * weight.z; }
	return sum / max(weight.x + weight.y + weight.z, 1e-4);
}

// Klüftung einer Projektionsebene (#174 D, überarbeitet im Review zu PR #177).
// `q` in Kluftabständen, q.x quer zur Fallrichtung, q.y entlang; `k` streckt
// das Muster entlang q.y. Drei Anteile, alle aus Rauschen statt aus `fract`,
// damit kein Gitter entsteht (die erste Fassung legte zwei gerade
// Kluftscharen in die Waagerechte; auf Wänden standen sie als gleichmäßiges
// Rautennetz, das sich wie ein Drahtgitter las):
//  - Runsen: dunkle Tonstreifen in Fallrichtung, Breite aus dem Rauschen;
//  - Fugen: Isolinien eines verzerrten Rauschens, nur stellenweise offen,
//    Breite mit dem Blockton und mit `couple` (Rinne/Rippe) moduliert;
//  - Schichtfugen quer zur Fallrichtung, kurz und gestückelt.
// `crack_detail` blendet die feinen Fugen vor den breiteren Runsen aus.
// Die Formzahlen hier sind Optik wie die Farben unten; die Kalibrierung
// (Abstand, Streckung, Tiefe, Rinnen-Kopplung) kommt über die Brücke.
// `aa` ist die Fugenbreite eines Pixels im Linienmaß (analytisch statt
// fwidth: der Aufrufer verzweigt je Pixel, Ableitungen wären dort undefiniert).
float rock_joint_face(vec2 q, float k, float couple, float crack_detail, float aa,
                      out float tone, out vec2 grad) {
	float ay = q.y / k;
	float wx = q.x + (vnoise(vec2(q.x * 0.35, ay * 0.35 + 3.1)) - 0.5) * 1.6;
	vec3 s0 = vnoise_d(vec2(wx * 0.5 + 2.0, ay * 0.5));
	// Gekreuzte Oktaven statt paralleler Rauschachsen: die frühere fünffache
	// Streckung zog selbst triplanare Klüfte zu senkrechten Vorhängen. Die
	// Ableitung geht mit der transponierten Drehung zurück in die Wandebene.
	mat2 turn = mat2(vec2(material_joint_turn_cos, material_joint_turn_sin),
	                 vec2(-material_joint_turn_sin, material_joint_turn_cos));
	vec3 s1 = vnoise_d(turn * vec2(wx * 1.3 + 9.0, ay * 1.3));
	s1.yz = s1.yz * turn;
	float st = s0.x * 0.65 + s1.x * 0.35;
	float streak = smoothstep(0.48, 0.78, st);
	// Gefälle der Runsen in Kluftabständen (q.x, q.y), für die Normale: die
	// Verzerrung `wx` geht als Näherung nicht ein, sie verschiebt nur.
	float ts = clamp((st - 0.48) / 0.30, 0.0, 1.0);
	vec2 dst = s0.yz * (0.5 * 0.65) + s1.yz * (1.3 * 0.35);
	grad = 6.0 * ts * (1.0 - ts) / 0.30 * vec2(dst.x, dst.y / k);
	tone = vnoise(q * 0.5 + vec2(13.0, 7.0));
	float fine = 0.0;
	// Fugen und Schichtfugen nur, solange sie nicht ausgeblendet sind: fünf
	// der neun Rauschabfragen je Projektion (Review zu #174).
	if (crack_detail > 0.0) {
		// Feine Grate zwischen den Runsen (~9 m), nur als Form: scharf am
		// Kamm (Höhe ½·(1 − |2n − 1|), ein halber Runsen-Hub), damit die
		// Wand in Rippen und Kanten bricht.
		vec3 s2 = vnoise_d(turn * vec2(wx * 3.3 + 5.0, ay * 3.3));
		s2.yz = s2.yz * turn;
		grad += sign(s2.x - 0.5) * s2.yz * 3.3 * vec2(1.0, 1.0 / k) * crack_detail;
		float r = 1.0 - abs(vnoise(vec2(wx, ay)) * 2.0 - 1.0); // 1 auf der Fuge
		float width = (0.02 + 0.10 * smoothstep(0.3, 0.8, tone)) * couple;
		float gate = smoothstep(0.5, 0.7, vnoise(vec2(q.x * 0.4 + 3.3, ay * 1.5 + 8.0)));
		float crack = smoothstep(1.0 - width - aa, 1.0, r) * gate;
		float bx = q.x / k + (vnoise(q * 0.3 + vec2(7.7, 0.0)) - 0.5) * 0.8;
		float rb = 1.0 - abs(vnoise(vec2(bx, q.y * 0.8 + 11.0)) * 2.0 - 1.0);
		float bed = smoothstep(0.93 - aa, 1.0, rb) * smoothstep(0.45, 0.75, vnoise(q * 0.5 + vec2(1.3, 2.9)));
		fine = max(crack, bed * 0.7) * crack_detail;
	}
	tone = tone * 2.0 - 1.0;
	return streak * 0.6 + fine;
}

// Klüftung (#174 D): triplanar auf die Wände gelegt. Auf den beiden
// Wandebenen läuft q.y senkrecht, die Runsen stehen also in Fallrichtung und
// sind um `material_joint_stretch` gestreckt; die Draufsicht (flache
// Felsrippen) bleibt ungestreckt. `cavity` (Relief-Bake #153, −1 Rinne … +1
// Rippe) koppelt das Muster an die Form: in Rinnen breiter und tiefer, auf
// Rippen schwächer. Die Stärke schwankt zusätzlich großflächig, ganze
// Wandpartien bleiben fast glatt. Liefert die Abdunklung (0 … 1) und einen
// Blockton (−1 … 1); ab etwa einem Kluftabstand je Pixel gehen beide in ihren
// Mittelwert über, statt zu flimmern. `px` ist die Pixelgröße in
// Welteinheiten (`length(fwidth(material_pos))`, oben in fragment() bestimmt:
// hier, hinter der Felsverzweigung je Pixel, wären Ableitungen undefiniert).
// `bump` (Befund #174 „Fels glatt"): die Runsen sind auch FORM, nicht nur
// Ton — Rinnen der Tiefe `material_joint_relief` (in Kluftabständen) als
// tangentiale Neigung der Normale, aus der analytischen Ableitung des
// Runsen-Rauschens. Die Sonne zeichnet damit Grate hell und Rinnen dunkel.
float rock_joints(vec3 p, vec3 n, float cavity, float px, out float tone, out vec3 bump) {
	float spacing = max(material_joint_spacing, 1e-4);
	vec3 q = p / spacing;
	float k = max(material_joint_stretch, 1.0);
	float couple = clamp(1.0 - cavity * material_joint_gully_gain, 0.2, 2.0);
	float fw = px / spacing;
	float detail = 1.0 - smoothstep(0.5, 1.2, fw);
	float crack_detail = 1.0 - smoothstep(0.08, 0.3, fw);
	vec3 w = pow(abs(n), vec3(4.0));
	w /= max(w.x + w.y + w.z, 1e-4);
	float j = 0.0;
	tone = 0.0;
	// Rauschen steigt um höchstens ~1,5 je Einheit, die Fugen (1 − |2n − 1|)
	// also um ~3: so breit ist ein Pixel im Linienmaß.
	float aa = fw * 3.0;
	float t;
	vec2 g;
	bump = vec3(0.0);
	if (detail > 0.0) {
		// Projektionen unter 2 % Gewicht entfallen (Kosten nur auf Fels).
		// Das Gefälle jeder Ebene geht entlang ihrer beiden Achsen in die Welt.
		if (w.x > 0.02) {
			j += w.x * rock_joint_face(q.zy, k, couple, crack_detail, aa, t, g);
			tone += w.x * t; bump += w.x * vec3(0.0, g.y, g.x);
		}
		if (w.z > 0.02) {
			j += w.z * rock_joint_face(q.xy, k, couple, crack_detail, aa, t, g);
			tone += w.z * t; bump += w.z * vec3(g.x, g.y, 0.0);
		}
		if (w.y > 0.02) {
			j += w.y * rock_joint_face(q.xz, 1.0, couple, crack_detail, aa, t, g);
			tone += w.y * t; bump += w.y * vec3(g.x, 0.0, g.y);
		}
	}
	float strength = (0.35 + 0.65 * smoothstep(0.25, 0.75, vnoise(q.xz * 0.13 + vec2(19.0, 4.0))))
	               * min(couple, 1.4);
	tone *= detail;
	// Runsen sind Rinnen: die Normale kippt zur Runse hin (Höhe = −Runse).
	// Das Gefälle steht in Kluftabständen je Kluftabstand, also direkt als
	// Neigung; tangential gemacht, damit die Normale nur kippt.
	bump = (bump - n * dot(bump, n)) * material_joint_relief * strength * detail;
	// 0.11 ≈ Flächenmittel des Musters (bei cavity 0), damit die Ferne nicht
	// heller wird als die Nähe; die Rinnen-Kopplung bleibt dort erhalten.
	return mix(0.11 * min(couple, 1.4), min(j * strength, 1.0), detail);
}

// Körnung der Halden: Blöcke von `material_scree_grain`, zwei Oktaven,
// mit der Pixelgröße `px` (Welteinheiten, s. `rock_joints`) ausgeblendet
// (−1 … 1, Mittel 0).
float scree_grain(vec2 p, float px) {
	float grain = max(material_scree_grain, 1e-4);
	vec2 q = p / grain;
	float detail = 1.0 - smoothstep(0.3, 1.0, px / grain);
	return ((vnoise(q) - 0.5) * 1.4 + (vnoise(q * 2.7 + vec2(4.0, 1.0)) - 0.5) * 0.6) * detail;
}

// Gletscherspalten quer zur Fließrichtung `fall` (Einheitsvektor bergab),
// gewellt; 0 … 1, mit der Pixelgröße `px` (Welteinheiten) ausgeblendet. Die
// Wellung geht in die Fugenbreite nicht ein: sie streckt das Muster quer,
// die Pixelgröße längs `fall` bleibt die der Ebene.
float crevasses(vec2 p, vec2 fall, float px) {
	float s = max(material_crevasse_spacing, 1e-4);
	vec2 side = vec2(-fall.y, fall.x);
	float t = dot(p, fall) / s + (vnoise(vec2(dot(p, side) / (s * 3.0), 0.0)) - 0.5) * 1.6;
	float fw = px / s;
	float detail = 1.0 - smoothstep(0.3, 0.9, fw);
	float f = abs(fract(t) - 0.5) * 2.0;
	float open = vnoise(vec2(dot(p, side) / (s * 1.7), floor(t)));
	return smoothstep(0.82 - fw, 0.97, f) * smoothstep(0.35, 0.6, open) * detail;
}

// Vier Zufallswerte (−1 … 1) je Kronenzelle. Ganzzahl-Hash (pcg3d, Jarzynski &
// Olano 2020) statt `ehash`: dessen Float-Produkt x·y·(x+y) liegt bei
// Zellindizes um 1000 bei ~1e9, `fract` liefert dort nur noch 0, und alle
// Kronen stünden in einem regelmäßigen Raster (Projekteigner, Nahzoom).
vec4 crown_hash(vec2 c) {
	uvec3 v = uvec3(uvec2(ivec2(c) + ivec2(65536)), 152u);
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	uint w = v.x ^ v.y ^ v.z;
	return vec4(vec3(v), float(w)) * (2.0 / 4294967295.0) - 1.0;
}

// Kronendach je Pixel (#152, aus der Flusstal-Studie übernommen): Voronoi-
// Kronen, je Zelle eine mit Zufallsversatz und -radius. Die Farben, Radien und
// Neigungen hier sind Optik dieses Shaders wie die Ufer- und Kiesfarben unten,
// keine Kalibrierung; die Schwellen kommen über die Brücke. `px` ist die
// Pixelgröße in Welteinheiten (`length(fwidth(wp))` aus fragment(), vor dem
// frühen Return bestimmt: danach wären Ableitungen undefiniert).
//
// Liefert nur das Ergebnis (Farbe, Deckung `amount`, Kronenneigung); fragment()
// ruft es VOR dem Bodenmaterial auf und überspringt dieses dort, wo das Dach
// voll deckt (s. `canopy_full`).
void canopy(vec2 wp, float h, float px, vec2 f_grad, out vec3 col, out float amount,
            out vec2 tilt_n) {
	col = vec3(0.0);
	amount = 0.0;
	tilt_n = vec2(0.0);
	float f = v_forest;
	if (f <= 0.002) {
		return;
	}
	// Ab etwa einer Krone je Pixel nur noch der Mittelwert: kein Flimmern.
	float detail = 1.0 - calib_window(canopy_detail_lo, canopy_detail_hi, px / max(canopy_cell, 1e-6));
	// Nur Mittelwert und Maske unter dem Deckungs-Fenster: der Wald deckt
	// hier nichts (exakt, ohne Kronen ist `fw` gleich `f`). Der lichte Saum
	// ist seit Look-Iteration 6 breit, ohne den Ausstieg kostete er Bildzeit.
	if (detail <= 0.0 && f <= canopy_cover_lo) {
		return;
	}
	// Bestände (Look-Iteration 6): zwei grobe Rauschskalen (~180 m und
	// ~770 m) mischen Nadel- und Laubbestände unabhängig von der Höhe, setzen
	// gelbgrüne Laubinseln und tragen in der Übersicht die Farbvariation, die
	// dort die Einzelkronen nicht mehr zeigen. Die Höhe schiebt nur die
	// Mischung (Nadelwald zur Baumgrenze), statt sie allein zu bestimmen.
	float stand = v_stand.x;
	float region = v_stand.y;
	float alt_share = clamp((h - conifer_lo) / max(conifer_hi - conifer_lo, 1e-6), 0.0, 1.0);
	float conifer_share = clamp(alt_share * 0.9 + (region - 0.5) * 1.4 + (stand - 0.5) * 0.6 + 0.1,
	                            0.05, 0.95);
	// Die Kronenschleife hält bewusst nur ihr Ergebnis (Höhe, Neigung, Ton,
	// Art) über die Iterationen; alle Farben entstehen danach. Mit den Farben
	// davor kostete sie gemessen ~1 ms je Bild mehr (Registerdruck).
	float best = 0.0;
	vec2 tilt = vec2(0.0);
	float tint = 0.0;
	float con = 0.0;
	if (detail > 0.0) {
		// Zum Rand und zur Baumgrenze (dünne Maske) kleinere Kronen.
		float shrink = mix(0.82, 1.0, smoothstep(0.3, 0.85, f));
		vec2 p = wp / max(canopy_cell, 1e-6);
		// Nur die 2×2 Zellen, deren Mitten das Pixel einklammern: jede
		// andere Kronenmitte liegt ≥ 1 − 0,28 = 0,72 Zellen entfernt, und
		// kein Radius ist größer. Gegenüber 3×3 die Hälfte der Arbeit, mit
		// der verdoppelten Waldfläche sonst gemessen +1 ms je Bild.
		vec2 g = floor(p - 0.5);
		for (int j = 0; j <= 1; j++) {
			for (int i = 0; i <= 1; i++) {
				vec2 c = g + vec2(float(i), float(j));
				vec4 r = crown_hash(c);
				// Krone steht nur, wo die Waldmaske ihre eigene Schwelle
				// übertrifft: am Rand dünnt der Wald so kronenweise aus.
				// Gelesen an der KRONENMITTE, nicht je Pixel: sonst schnitt
				// die Schwelle Kronen am Rand mitten durch (eckige Splitter).
				vec2 centre = c + 0.5 + r.xy * 0.28;
				// Die Schwelle streut nur zum kleineren Teil je Krone, zum
				// größeren mit dem Bestands-Rauschen (~180 m): am Rand stehen
				// so geschlossene Baumgruppen statt verstreuter Einzelkronen.
				// Die Maske ist je Dreieck linear: ihr Wert an der Kronenmitte
				// folgt aus dem Wert am Pixel und ihrem Gradienten (`f_grad`),
				// ohne Texturabgriff je Krone (der kostete gemessen ~0,6 ms
				// je Bild auf der vergrößerten Waldfläche).
				float fc = f + dot(f_grad, centre * canopy_cell - wp);
				if (fc < canopy_crown_mid + canopy_crown_spread * (r.w * 0.3 + (0.5 - stand) * 2.4)) {
					continue;
				}
				vec2 d = p - centre;
				bool is_con = (r.x * 0.5 + 0.5) < conifer_share;
				// Zwei Größenklassen: etwa jede dritte Krone ist ein großer
				// Baum (Laub breiter als Nadel), der Rest kleiner Unterwuchs.
				float big = step(0.35, r.z);
				float rad = (canopy_crown_radius + canopy_crown_radius_jitter * r.z)
				          * mix(0.75, 0.97, big) * (is_con ? 0.88 : 1.0) * shrink;
				float dd = length(d);
				// Auch Nadelkronen als abgeflachte Kuppel statt Kegel: der
				// Kegel teilte jede Krone in eine helle und eine fast schwarze
				// Hälfte mit harter Kante (zackige Dreiecke in der Nahsicht).
				float dome = sqrt(max(rad * rad - dd * dd, 0.0));
				float hgt = is_con ? mix(dome, (rad - dd) * 1.7, 0.35) : dome;
				// Große Bäume ragen über den Unterwuchs (nur innerhalb der Krone).
				hgt += hgt > 0.0 ? big * 0.12 : 0.0;
				if (hgt > best) {
					best = hgt;
					tilt = d / max(dome, 0.15) * (is_con ? 1.0 : 0.85);
					tint = r.y * 0.5 + 0.5;
					con = is_con ? 1.0 : 0.0;
				}
			}
		}
	}
	float yellow = smoothstep(0.72, 0.86, stand) * (1.0 - conifer_share) * 0.6;
	// Dunkles Tannengrün (Referenz f). Heller (Look-Iteration 6, Versuch)
	// las sich der Wald in der Übersicht flach und gleichförmig; der
	// Bewerter zog die dunklen Kronenschatten vor.
	vec3 decid = mix(vec3(0.070, 0.150, 0.036), vec3(0.135, 0.185, 0.035), yellow);
	vec3 conif = vec3(0.030, 0.072, 0.038);
	// Zwischen den Kronen eines Bestands dunkler Unterwuchs, grünstichig
	// statt schwarz: Gruppen lesen sich geschlossen statt als Einzelnoppen.
	vec3 gap = vec3(0.012, 0.026, 0.012);
	// Fern-Mittelwert dunkler als die Kronen selbst: im Bestand fällt der
	// Großteil der Fläche in Kronenschatten und Lücken.
	vec3 avg = mix(mix(decid, conif, conifer_share) * 0.8, gap, 0.4);
	// Die Maske ist je Dreieck linear: Fenster darauf hätten gerade
	// Kanten. Ein feines Rauschen (~25 m) verwackelt sie zu Buchten; in der
	// Ferne (Kronen unter Pixelgröße) blendet es mit aus, sonst flimmert es.
	float fw = detail > 0.0 ? f + (vnoise(wp * 4.0 + vec2(1.3, 8.1)) - 0.5) * 0.3 * detail : f;
	float inside = calib_window(canopy_gap_lo, canopy_gap_hi, fw); // Lücken nur im Bestand dunkel
	// Kronenfuß im Schatten der Nachbarn, Kuppe im Licht.
	vec3 crown = mix(decid * mix(0.7, 1.35, tint), conif * mix(0.75, 1.3, tint), con)
	           * mix(0.45, 1.05, clamp(best / 0.5, 0.0, 1.0));
	float covered = best > 0.0 ? 1.0 : inside;
	vec3 near_col = best > 0.0 ? crown : gap;
	col = mix(avg, near_col, detail);
	amount = mix(calib_window(canopy_cover_lo, canopy_cover_hi, fw), covered, detail);
	tilt_n = clamp(tilt, vec2(-2.0), vec2(2.0)) * 0.85 * detail;
}

// Debug-Ansichten der Flusstal-Studie: nur im FLUSSTAL_STUDY-Build
// eingebunden (Präprozessor). Der normale Spiel-Shader überspringt Include UND
// Aufruf komplett — keine Studien-Uniforms in Produktion, und `studies/` darf
// verschoben werden, ohne den Hauptshader zu brechen (Review zu #121).
// Flusstal.gd setzt das Define zur Laufzeit vor diese Quelle (Godot 4.7
// erlaubt #define vor shader_type). Das Include steht HIER, weil die Studie
// die Helfer darüber mitbenutzt. Die PBR-Materialien der ersten Runde sind mit
// #174 D durch die prozedurale Materialverteilung ersetzt und entfernt.
#ifdef FLUSSTAL_STUDY
#include "res://studies/flusstal/landscape.gdshaderinc"
#endif
// Wolkenschatten (#151): gemeinsame Funktion mit Ozean und Bändern.
#include "res://shaders/clouds.gdshaderinc"

void vertex() {
	vec2 uv = world_uv(VERTEX);
	v_uv = uv;
	v_xz = VERTEX.xz;
	float hraw = height_at(uv);
	// Seen als ECHTE horizontale Flächen: unter Wasser stehende Zellen werden
	// auf den Seespiegel hf gehoben. Der weiche Einstieg glättet die Uferlinie.
	// MIT dem See-Gate multipliziert: eine Komponente, die das Gate (noch) nicht
	// sichtbar macht, darf auch nicht gehoben werden — sonst stünde eine
	// horizontale Fläche in Terrain-Farbe im Becken („trockener Wasserspiegel").
	// So faden kleine Seen als Ganzes ein: Geometrie und Farbe zusammen.
	float hfv = hf_at(uv);
	float pond = pond_of(hfv, hraw);
	float lift = calib_window(water_geometry_lift_lo, water_geometry_lift_hi, pond) * lake_gate_at(uv);
	// Seen hebt die Zeile selbst auf den Spiegel; dort keine Verschiebung.
	VERTEX.y = mix(hraw, hfv, lift) * hscale + relief_lift(uv) * (1.0 - lift);
	// Kronendach: Waldkanten werfen Schatten. An Wasser ist die Maske null.
	v_forest = 0.0;
	if (canopy_enabled) {
		v_forest = textureLod(forest_tex, uv, 0.0).r;
		if (overlay_blend < 1.0) {
			v_forest = mix(textureLod(forest_prev_tex, uv, 0.0).r, v_forest, overlay_blend);
		}
	}
	// Ohne Wald am Vertex neutral (0,5) statt gerauscht: spart die beiden
	// Rausch-Aufrufe auf dem Großteil des Netzes (auch in jedem Schatten-Pass).
	v_stand = vec2(0.5);
	if (v_forest > 0.002) {
		vec2 swp = VERTEX.xz + world_size * 0.5;
		v_stand = vec2(vnoise(swp * 0.55 + vec2(3.7, 11.3)), vnoise(swp * 0.13 + vec2(19.1, 5.4)));
	}
	// Das Dach hebt nach der GEGLÄTTETEN Maske an (vier bilineare Abgriffe
	// im Abstand von `canopy_lift_smooth_texels` (1,5) Texeln, also ein Mittel
	// über etwa 4×4 Zellen; `Main._forest_lift_at` rechnet es nach): je
	// Sim-Zelle angehoben zog es Zeltspitzen und steile Dreieckswände hoch,
	// die sich in der Nahsicht als schwarze Splitter lasen. Geglättet steigt
	// der Bestandsrand über mehrere Zellen sanft an, Einzelzellen heben kaum.
	float lift_f = v_forest;
	// Unter `canopy_lift_lo` hebt das Dach ohnehin nicht (das Minimum unten
	// kann nur kleiner werden): dort keine Abgriffe. Der Vertex-Shader läuft
	// auch in jedem Schatten-Pass, die Abgriffe kosteten sonst messbar.
	if (canopy_enabled && v_forest > canopy_lift_lo) {
		vec2 o = vec2(canopy_lift_smooth_texels / grid_n);
		float sm = textureLod(forest_tex, uv + o, 0.0).r + textureLod(forest_tex, uv - o, 0.0).r
		         + textureLod(forest_tex, uv + vec2(o.x, -o.y), 0.0).r
		         + textureLod(forest_tex, uv + vec2(-o.x, o.y), 0.0).r;
		if (overlay_blend < 1.0) {
			float sp = textureLod(forest_prev_tex, uv + o, 0.0).r + textureLod(forest_prev_tex, uv - o, 0.0).r
			         + textureLod(forest_prev_tex, uv + vec2(o.x, -o.y), 0.0).r
			         + textureLod(forest_prev_tex, uv + vec2(-o.x, o.y), 0.0).r;
			sm = mix(sp, sm, overlay_blend);
		}
		lift_f = min(v_forest, sm * 0.25);
	}
	float v_lift = calib_window(canopy_lift_lo, canopy_lift_hi, lift_f);
	VERTEX.y += v_lift * canopy_height;
	float texel = 1.0 / grid_n;
	float hL = height_at(uv - vec2(texel, 0.0));
	float hR = height_at(uv + vec2(texel, 0.0));
	float hD = height_at(uv - vec2(0.0, texel));
	float hU = height_at(uv + vec2(0.0, texel));
	float sw = world_size / (grid_n - 1.0);
	// Vorzeichen wie die Pixel-Normale (`n_ws` in fragment()): hU liegt bei +z.
	// Licht rechnet die Pixel-Normale, aber Godots Schatten-Normal-Bias liest
	// diese hier; mit `-(hD - hU)` zeigte sie an jedem ±z-Hang falsch herum
	// (Review zu #174).
	NORMAL = normalize(vec3(-(hR - hL) * hscale, 2.0 * sw, -(hU - hD) * hscale));
}

void fragment() {
	vec4 macro_rgba = color_at(v_uv);
	vec3 macro_color = macro_rgba.rgb;
	vec4 surface = surface_at(v_uv);
	float hval = height_at(v_uv);
	// Pixelgröße in Welteinheiten, EINMAL hier im gleichförmigen Kontrollfluss:
	// Klüftung, Körnung, Spalten und Kronen blenden darüber aus, laufen aber
	// hinter Verzweigungen je Pixel, wo `fwidth` undefiniert ist.
	vec2 wp = v_xz + world_size * 0.5;
	vec3 material_pos = vec3(wp.x - world_size * 0.5, hval * hscale,
	                         wp.y - world_size * 0.5);
	float px_wp = length(fwidth(wp));
	float px_mat = length(fwidth(material_pos));
	// Gradient der Waldmaske in Welt-xz, ebenfalls hier vor jeder
	// Verzweigung: aus den Bildschirm-Ableitungen von Maske und Position
	// (2×2-System). Das Kronendach schätzt damit die Maske an jeder
	// Kronenmitte; je Dreieck ist sie linear, die Schätzung also exakt.
	mat2 dw = mat2(vec2(dFdx(wp).x, dFdy(wp).x), vec2(dFdx(wp).y, dFdy(wp).y));
	float dw_det = determinant(dw);
	vec2 f_grad = abs(dw_det) > 1e-12
	            ? inverse(dw) * vec2(dFdx(v_forest), dFdy(v_forest)) : vec2(0.0);
	// Kronendach ZUERST (Look-Iteration 6, Bildzeit): wo es voll deckt,
	// überschreibt es Farbe, Normale und Rauheit des Bodens vollständig.
	// Bodenmaterial und Erosionsdetail darunter wären verworfene Arbeit und
	// laufen dort nicht (`canopy_full` unten). Das hält die in Iteration 6
	// verdoppelte Waldfläche ohne Bildzeit-Einbuße (Zeitraffer-A/B).
	vec3 canopy_col;
	float canopy_amount;
	vec2 canopy_tilt;
	canopy(wp, hval, px_wp, f_grad, canopy_col, canopy_amount, canopy_tilt);
	vec4 relief = relief_pixel(v_uv);
	vec4 amp_maps = amplify_maps(v_uv, bake_blend);

	// Grobe Steigung aus dem Sim-Gitter. Sie bestimmt die Form, während die
	// Material-Normale darunter nur Licht im Zentimetermaßstab bricht.
	float texel = 1.0 / grid_n;
	float hL = height_at(v_uv - vec2(texel, 0.0));
	float hR = height_at(v_uv + vec2(texel, 0.0));
	float hD = height_at(v_uv - vec2(0.0, texel));
	float hU = height_at(v_uv + vec2(0.0, texel));
	vec2 coarse_slope = vec2(hR - hL, hU - hD) * 0.5 * grid_n;
	coarse_slope += relief_slope(relief);
	// Dieselbe Steigung in sichtbarer Neigung (Welt-Y je Welt-Einheit):
	// Gletscherspalten (#174 D) und Raster-Wasser an Wänden lesen sie.
	float world_slope = length(coarse_slope) * hscale / world_size;

	float ws = world_size / 100.0;
	float view_dist = length(VERTEX);
	float dfade = (1.0 - smoothstep(110.0 * ws, 280.0 * ws, view_dist))
	            * smoothstep(sea_level + 0.005, sea_level + 0.045, hval);
	vec2 det_slope = vec2(0.0);
	float det_shade = 0.0;
	float det_ridge = 0.0;
	// Unter vollem Kronendach kein Erosionsdetail: es neigte dort nur noch die
	// Makro-Normale, gegen die die Kronen kippen; im Bild nicht zu sehen
	// (Aufnahmen nah/tal, Differenz unter dem Rauschen zweier Läufe), spart
	// gemessen ~0,4 ms je Bild in der Nahsicht.
	if (detail_enabled && !debug_difference && dfade > 0.002 && canopy_amount < 0.9999) {
		float fade_target = clamp((hval - sea_level) / 0.6 * 2.0 - 1.0, -1.0, 1.0);
		float det_mag;
		vec4 det = erosion_detail(v_uv, coarse_slope, fade_target, det_mag);
		// Stärke folgt dem echten Abfluss (WaterRender.flowDetailGainLo/Hi):
		// Rinnen bündeln sich in Abflussbahnen, abseits davon beruhigt sich
		// der Layer unter den früheren Uniform-Look.
		float flow_gain = mix(0.3, 1.8, flow_at(v_uv));
		// Fels trägt die Rinnen schärfer (MaterialRender.rockReliefGain):
		// Runsen und Rippen mit echtem Licht und dunklen Rinnenböden statt
		// einer glatt verputzten Wand (Befund #174).
		flow_gain *= mix(1.0, material_rock_relief_gain, clamp(surface.g, 0.0, 1.0));
		det_slope = det.yz * dfade * relief_detail_normal * flow_gain;
		det_shade = det.x / det_mag * dfade * flow_gain;
		det_ridge = det.w * dfade;
	}

	vec2 s_uv = coarse_slope + det_slope;
	vec3 n_ws = normalize(vec3(-s_uv.x * hscale / world_size, 1.0, -s_uv.y * hscale / world_size));

	// Physikalisch gebundene Grundmaterialien (#174 D). Die CPU liefert nur
	// ihre Gewichte (SimRender.TerrainColorRenderer, Kalibrierung
	// SimCore.MaterialRender); Körnung, Klüfte, Schichten und Rauheit entstehen
	// hier kontinuierlich in Weltkoordinaten und bleiben damit unabhängig vom
	// Render-Gitter.
	vec4 cover = cover_at(v_uv); // vor der Verzweigung: implizite Mip-Stufe
	// UNGESTÖRTE Makro-Normale sichern, bevor Runsen und Mikro-Normale sie
	// verändern: das Kronendach neigt seine Kronen gegen sie, ohne
	// Mikro-Rauschen (Review zu #121).
	vec3 macro_n = n_ws;
	vec3 terr = vec3(0.0);
	float land_roughness = 0.92;
	// Volle Deckung: das Dach ersetzt den Boden, das Material darunter entfällt.
	// Die Schwelle statt `== 1.0`, weil `mix` die 1 nicht immer exakt trifft;
	// der Rest (< 1e-4) liegt weit unter einer 8-Bit-Stufe.
	bool canopy_full = canopy_amount >= 0.9999;
	float breakup = vnoise(wp * 0.9) * 0.6 + vnoise(wp * 3.7) * 0.4;
	if (!canopy_full) {
		float vegetation = clamp(surface.r, 0.0, 1.0);
		float rock = clamp(surface.g, 0.0, 1.0);
		float cold = clamp(surface.b, 0.0, 1.0);
		float lith = surface.a * 2.0 - 1.0;
		float scree = clamp(cover.r, 0.0, 1.0);
		float ice_share = clamp(cover.g, 0.0, 1.0);
		float raw = clamp(cover.b, 0.0, 1.0);
		float valley = clamp(cover.a, 0.0, 1.0);
		// Feinverteilung an Rinnen und Rippen der Render-Verschiebung (#153): in
		// Rinnen rutscht Fels als Schutt nach, auf Rippen steht er auch dort, wo
		// das Sim-Gitter nur Grund sieht. Der Zuschlag nimmt nur vom Grund, die
		// Gewichtssumme bleibt damit höchstens 1.
		float cavity = hval > sea_level + 0.012 ? relief_cavity(relief) : 0.0;
		float slid = rock * clamp(-cavity, 0.0, 1.0) * material_gully_scree_share;
		rock -= slid;
		scree += slid;
		float bare_rest = max(0.0, 1.0 - (vegetation + rock + cold + scree + raw));
		rock += min(bare_rest, rock * clamp(cavity, 0.0, 1.0) * material_ridge_rock_gain);
		// Look-Iteration 7, EIN Block für drei Umverteilungen (gemeinsame
		// Rausch- und Formterme). Befund „glatte Knete", Schnee als Kappe:
		//  - Schnee folgt der Form. Er bleibt in Rinnen (`cavity` < 0) und auf
		//    flachen Schultern liegen, gleitet von Rippen, Graten und je Pixel
		//    steilen Flanken (Steigung samt Render-Verschiebung, also auch von
		//    den Felsrippen des Bakes) ab; die Grenze franst über zwei
		//    Rauschskalen aus und wird zur Kante geschärft statt als weicher
		//    Verlauf auszulaufen. Was der Schnee freigibt, ist aperer Fels.
		//  - Fels gegen Bewuchs franst aus (Rippen Fels, Rinnen Gras) und wird
		//    zur Kante geschärft, statt weich zu verlaufen. Summe unverändert.
		//  - Felsköpfe und Schuttstreifen auf steilen Grashängen (Referenz f):
		//    auf Rippen tritt Fels aus dem Gras, in den Rinnen ziehen kahle
		//    Schuttstreifen; beides nimmt nur vom Bewuchs und vom freien Grund.
		// Früh im Material, vor allen Rausch- und Farbtermen, und nur mit dem
		// schon vorhandenen `breakup` als Rauschen: später, wo die Farben
		// leben, kostete derselbe Block gemessen ~1 ms je Bild (Registerdruck),
		// auch unausgeführt. Klüftung und Körnung laufen weiter nur auf dem
		// Fels- und Schuttanteil der Zelle (`rock_cell`, `scree_cell`). Die
		// Felsbänke derselben Iteration rechnet der Relief-Bake.
		float rock_cell = rock;
		float scree_cell = scree;
		float n_mix = (breakup - 0.5) * 1.8;
		// Beide Umverteilungen blenden ab ihrer Schwelle über
		// `material_redistribute_fade` ein (SimCore.MaterialRender, Review
		// Neon Nr. 4: vorher harter Sprung an der Schwelle).
		if (cold > 0.002) {
			float lie = cold * 1.45 + n_mix * material_snow_breakup - cavity * material_snow_cavity
			          - calib_window(material_snow_slope_lo, material_snow_slope_hi, world_slope);
			// Nur der SCHNEE-Anteil rutscht: `cold` trägt Schnee und Eis. Der
			// Eisanteil (`cold * ice_share`, am Gletscherrand stetig zwischen
			// 0 und 1) wird vorher gesichert und `ice_share` danach daraus neu
			// gebildet; `ice_w`, Spalten und Moränen unten sehen so dieselbe
			// Eismenge wie ohne Umverteilung. Nur `ice_share` mitzugewichten
			// reicht nicht: die Aufteilung liefe proportional mit, und Eis
			// stünde anteilig als Fels da (PR-Review #232).
			float ice_part = cold * ice_share;
			float snow_part = cold - ice_part;
			float snow_lie = mix(snow_part, smoothstep(0.30, 0.62, lie) * (1.0 - ice_share),
			                     calib_window(0.002, material_redistribute_fade, cold));
			rock += max(snow_part - snow_lie, 0.0);
			cold = ice_part + snow_lie;
			ice_share = cold > 1e-4 ? ice_part / cold : ice_share;
		}
		float pair = rock + vegetation;
		if (rock > 0.005) {
			float t = rock / pair + (n_mix + cavity * 0.5) * material_rock_fray;
			float rock_fray = mix(rock, pair * smoothstep(0.25, 0.75, t),
			                      calib_window(0.005, material_redistribute_fade, rock));
			vegetation = pair - rock_fray;
			rock = rock_fray;
		}
		float steep_g = calib_window(material_outcrop_slope_lo, material_outcrop_slope_hi, world_slope);
		if (steep_g > 0.0) {
			float free_g = max(0.0, 1.0 - (vegetation + rock + cold + scree + raw));
			float crag = steep_g * material_outcrop * smoothstep(0.15, 0.55, cavity + n_mix * 0.35);
			float streak = steep_g * material_scree_streak * smoothstep(0.25, 0.7, -cavity + n_mix * 0.2);
			rock += (vegetation + free_g) * crag;
			vegetation *= 1.0 - crag;
			scree += vegetation * streak;
			vegetation *= 1.0 - streak;
		}
		// Karten der Gelände-Verfeinerung (#238): Schutt, frischer Fels.
		if (amplify_enabled) {
			amplify_material(amp_maps, steep_g, vegetation, rock, scree);
		}

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

		// Brauner Rohboden nur noch auf frisch gestörten Flächen (Gewicht `raw`
		// aus Terrain.disturb); bis #174 war er die Grundfarbe ganzer Hänge.
		vec3 soil_color = vec3(0.25, 0.20, 0.14)
		                * mix(0.82, 1.12, top_large)
		                * mix(0.93, 1.07, top_grain * material_fade);
		// Talboden hell und saftig, Hänge im Ton von #168. Look-Iteration 10:
		// alle Grüntöne mit weniger Blau und Rot (satter), weil sie unter der
		// warmen, tiefen Sonne sonst gelboliv lasen.
		vec3 lush_color = vec3(0.17, 0.35, 0.06)
		                * mix(0.85, 1.10, top_large)
		                * mix(0.92, 1.08, top_grain * material_fade);
		vec3 vegetation_color = vec3(0.08, 0.23, 0.06)
		                      * mix(0.76, 1.15, top_large)
		                      * mix(0.90, 1.08, top_grain * material_fade);
		vegetation_color = mix(vegetation_color, lush_color * 0.85, valley * 0.6);
		// Grund: weder bewachsen noch Fels, Schutt, Eis oder Rohboden. Unterhalb
		// der Vegetationsgrenze Trockenrasen, darüber steiniger Grund.
		vec3 dry_grass = vec3(0.17, 0.23, 0.08)
		               * mix(0.82, 1.12, top_large)
		               * mix(0.92, 1.08, top_grain * material_fade);
		vec3 stony = vec3(0.17, 0.167, 0.16)
		           * mix(0.86, 1.10, tri_large)
		           * mix(0.90, 1.10, mix(0.5, tri_grain, material_fade));
		vec3 ground_color = mix(dry_grass, stony, smoothstep(veg_alt_lo, veg_alt_hi, hval));
		ground_color = mix(ground_color, lush_color, valley * 0.7);

		// Die echte Lithologie steuert die Helligkeit des Felses: harte Bänder
		// dunkler, weiche verwittern hell. Bis Look-Iteration 7 nur an feinen,
		// stückweisen Schichtkanten (Abstand 0,6); die Schichtung tragen jetzt
		// die gröberen Felsbänke des Relief-Bakes, hier bleibt nur der Ton
		// (der Wegfall von Phase und Rauschen hält die Bildzeit). Das Korn wird
		// über `material_fade` auf seinen neutralen Mittelwert 0.5 gezogen,
		// nicht am Gate hart auf ihn gesetzt: sonst stünde am Fade-Ende eine
		// Kante von bis zu 11 % Helligkeit quer durch die Felsflächen.
		float lith_contrast = mix(1.09, 0.82, lith * 0.5 + 0.5);
		// Dunkelgrauer Fels mit Klüftung (#174 D): Runsen in Fallrichtung, Fugen,
		// Blockton. Im Review zu PR #177 dunkler und kontrastreicher gestellt
		// (0,20–0,33 statt 0,33–0,40): die Vorlagen A/B/C tragen dunkelgrauen,
		// schroffen Fels; der hellere las sich unter Himmelslicht beige. Kalkstein
		// mit 0,5–0,6 las sich in der Studie sogar als Schnee. Die Zahlen sind
		// LINEARE Albedo (Godot): 0,20–0,33 sind auf dem Bildschirm 0,48–0,61,
		// unter der warmen Sonne also hellbeige (Befund #174 „Fels zu hell").
		// Jetzt 0,07–0,15 (Bildschirm 0,29–0,42) und leicht kühl gegen die
		// warme Sonne; die Form tragen die Runsen (`rock_bump`).
		float tone = 0.0;
		float joints = 0.0;
		vec3 rock_bump = vec3(0.0);
		if (material_enabled && rock_cell > 0.01) {
			joints = rock_joints(material_pos, n_ws, cavity, px_mat, tone, rock_bump);
		}
		vec3 rock_color = mix(vec3(0.06, 0.064, 0.072), vec3(0.16, 0.158, 0.155), smoothstep(0.30, 0.70, tri_large))
		                * mix(0.82, 1.10, mix(0.5, tri_grain, material_fade))
		                * mix(1.0, lith_contrast, 0.5 * rock)
		                * (1.0 + tone * 0.10)
		                * (1.0 - joints * material_joint_depth);
		// Schutthalde: heller als die Wand, grob gekörnt.
		float grain = 0.0;
		if (material_enabled && scree_cell > 0.01) {
			grain = scree_grain(material_pos.xz, px_mat);
		}
		vec3 scree_color = vec3(0.22, 0.215, 0.20) * mix(0.90, 1.06, tri_large) * (1.0 + grain * 0.16);

		// Schnee und Gletscher: im Zehrgebiet blankes, bläuliches Eis mit Spalten
		// und Moränen, darüber Firn wie Schnee.
		vec3 snow_color = vec3(0.79, 0.84, 0.89)
		                * mix(0.91, 1.05, wind_snow * material_fade);
		vec3 ice_color = vec3(0.56, 0.70, 0.80) * mix(0.94, 1.04, tri_large);
		vec3 cold_color = mix(snow_color, ice_color, ice_share);
		float ice_w = cold * ice_share;
		if (material_enabled && ice_w > 0.01) {
			vec2 fall = length(coarse_slope) > 1e-5 ? -normalize(coarse_slope) : vec2(0.0, 1.0);
			float crack = crevasses(wp, fall, px_wp)
			            * calib_window(material_crevasse_slope_lo, material_crevasse_slope_hi, world_slope);
			cold_color = mix(cold_color, vec3(0.16, 0.26, 0.38), crack * ice_share * 0.85);
			// Seiten- und Endmoräne am Rand der Zunge, Mittelmoränen als Streifen
			// in Fließrichtung.
			float margin = calib_window(0.0, material_moraine_lo, cold)
			             * (1.0 - calib_window(material_moraine_lo, material_moraine_hi, cold));
			vec2 side = vec2(-fall.y, fall.x);
			float medial = smoothstep(0.62, 0.80, vnoise(vec2(dot(wp, side) * 1.3, dot(wp, fall) * 0.12)));
			float moraine = clamp(margin + medial * 0.6, 0.0, 1.0) * ice_share;
			cold_color = mix(cold_color, vec3(0.30, 0.29, 0.27) * mix(0.85, 1.1, tri_grain), moraine * 0.85);
		}

		// Die CPU liefert die Gewichte schon hierarchisch abgeschwächt
		// (TerrainColorRenderer: Kälte deckt alles, Fels und Schutt vor Rohboden
		// und Vegetation); sie summieren sich damit auf höchstens 1, der Rest ist
		// Grund. Als mix-KETTE gerechnet dämpfte jedes spätere Material das
		// frühere ein ZWEITES Mal — auf einem bewaldeten Hang (veg 0.6, rock 0.2)
		// blieben von der Felsfarbe 8 % statt 20 %, und das Ergebnis hing an der
		// Blend-Reihenfolge. Als Gewichtssumme ist es reihenfolge-unabhängig und
		// jedes Material genau mit seinem Anteil sichtbar. Normiert wird, weil die
		// Byte-Quantisierung der Gewichte die Summe knapp über 1 heben kann.
		float cover_w = vegetation + rock + cold + scree + raw;
		float soil_w = max(0.0, 1.0 - cover_w);
		// Wiese (#168): bewachsener Grund ohne Wald. Linear gemischt trug ein
		// Vegetationsgewicht von 0,3 nur 30 % Grün und las sich als Sand; ein
		// Teil des Grundanteils wird deshalb Gras. Fels und Schnee bleiben, wie
		// sie sind; die Schwellen stehen in SimCore.CanopyRender.
		float meadow_w = calib_window(canopy_meadow_lo, canopy_meadow_hi, vegetation)
		               * canopy_meadow_share * soil_w;
		vec3 meadow_color = vec3(0.13, 0.26, 0.06)
		                  * mix(0.82, 1.12, top_large)
		                  * mix(0.92, 1.08, top_grain * material_fade);
		meadow_color = mix(meadow_color, lush_color, valley);
		terr = (ground_color * (soil_w - meadow_w) + meadow_color * meadow_w
		          + soil_color * raw + rock_color * rock + scree_color * scree
		          + vegetation_color * vegetation + cold_color * cold)
		          / max(0.001, soil_w + cover_w);
		// Die Makrokarte bewahrt Salzkrusten, Gletschereis und Biom-Farbverschiebung,
		// ohne wieder als alleinige, weichgefilterte Oberfläche sichtbar zu werden.
		// Auf Fels nur halb so viel (Look-Iteration 7): die Makrokarte trägt
		// dort den weichgefilterten Zellton und verputzte Rippen und Bänke;
		// Felsköpfe auf Grashängen nahmen sonst deren Grün an.
		terr = mix(terr, macro_color, 0.28 * (1.0 - 0.6 * rock));
		float salt_hint = smoothstep(0.48, 0.72, macro_color.r)
		                * smoothstep(0.04, 0.12, macro_color.r - macro_color.b)
		                * (1.0 - cold) * (1.0 - vegetation);
		terr = mix(terr, macro_color, salt_hint * 0.72);
		// Meeresgrund (unter der opaken Ozean-Ebene) nur in der Makrofarbe. Die
		// Grenze liegt an der Wasserlinie wie die Farbrampe im
		// TerrainColorRenderer (#174 C): bei `sea_level + 0.012` lag auf jeder
		// flachen Küste ein grauer Streifen ohne Material, und Delta-Inseln
		// (Scheitel `deltaTopset` = 0,0015) hatten nie Bewuchs (#174, Punkt 26).
		if (hval <= sea_level) {
			terr = macro_color;
		}
		// Runsen als Form (s. `rock_joints`), mit dem Felsanteil.
		n_ws = normalize(n_ws + rock_bump * rock);
		// Mikro-Normale aus drei Weltachsen. Ein einfacher Noise-Sample pro Achse
		// genügt hier; drei weitere vollständige triplanare FBMs kosteten pro Pixel
		// 27 unnötige Noise-Auswertungen.
		if (material_fade > 0.002 && hval > sea_level + 0.012) {
			vec3 micro_pos = material_pos * 2.8;
			vec3 micro = vec3(vnoise(micro_pos.xy + vec2(5.0, 17.0)),
			                  vnoise(micro_pos.yz + vec2(23.0, 3.0)),
			                  vnoise(micro_pos.xz + vec2(13.0, 31.0))) - vec3(0.5);
			micro -= n_ws * dot(micro, n_ws);
			float micro_strength = mix(0.055, 0.13, rock + scree) * mix(1.0, 0.45, cold);
			n_ws = normalize(n_ws + micro * micro_strength * material_fade);
		}
		terr *= 1.0 + min(det_shade, 0.0) * relief_detail_shade
		      + max(det_shade, 0.0) * relief_detail_shade * 0.3;
		float crease = clamp(-det_ridge, 0.0, 1.0);
		float moist = crease * (1.0 - smoothstep(veg_alt_lo, veg_alt_hi, hval));
		terr = mix(terr, terr * vec3(0.60, 0.70, 0.58) + vec3(0.0, 0.02, 0.0),
		           moist * 0.32);
		terr *= 0.96 + 0.08 * breakup;
		// Rinnenböden dunkler, Rippen heller (grobe Verschiebung, #153).
		terr *= 1.0 + (cavity < 0.0 ? cavity * relief_shade_dark : cavity * relief_shade_light);
		// Ton nach der Form (Look-Iteration 7): auf Gras trockene, gelbliche
		// Rippen und satte, dunkle Rinnen statt eines gleichförmigen Tons; auf
		// Fels zusätzlicher Hell-Dunkel-Kontrast zwischen Rippe und Runse.
		float green_w = (1.0 - rock - scree) * (1.0 - cold);
		terr = mix(terr, terr * vec3(1.16, 1.10, 0.78), clamp(cavity, 0.0, 1.0) * 0.8 * green_w);
		terr = mix(terr, terr * vec3(0.72, 0.88, 0.66), clamp(-cavity, 0.0, 1.0) * 0.8 * green_w);
		terr *= 1.0 + cavity * 0.45 * rock;

		land_roughness = mix(0.90, 0.68, rock);
		land_roughness = mix(land_roughness, 0.95, scree);
		land_roughness = mix(land_roughness, 0.84, vegetation);
		land_roughness = mix(land_roughness, 0.78, cold);
		land_roughness = mix(land_roughness, 0.34, ice_w);
		land_roughness += (tri_grain - 0.5) * 0.08 * material_fade;
		// Sand (#174 C/C2), EIN Block für beide Quellen: Strand (flache Küste in
		// Reichweite der Brandung, bis an die Wasserlinie; SimRender.CoastMaterial)
		// und frische Gleithang-Bänke mit Scroll-Rippen (SimRender.BarMaterial).
		// Der A-Kanal trägt max(Strand, Bank); wo und wie viel, sagt allein
		// SimRender. Farbe und Rauheit reisen als water_bar_* über die Brücke
		// (SimCore.WaterRender).
		float sand = macro_rgba.a;
		if (sand > 0.002) {
			float shore = hval - sea_level;
			vec3 sand_col = mix(water_bar_sand_wet_color, water_bar_sand_color, breakup);
			// Strandband: unter `water_beach_height_hi`, die letzten
			// `water_beach_blend_height` stetig in die Bank-Behandlung (bis zum
			// Review Neon Nr. 3 ein hartes `if`, s. WaterRender.beachBlendHeight).
			float beach = 1.0 - calib_window(water_beach_height_hi - water_beach_blend_height,
			                                 water_beach_height_hi, shore);
			if (beach > 0.0) {
				// Rückkante scharf; an der Wasserlinie dagegen fällt das Gewicht
				// bilinear zur Meereszelle (A = 0) ab, dort bis ans Wasser voll.
				float dry = smoothstep(water_beach_wet_height, 2.0 * water_beach_wet_height + 1e-6, shore);
				float beach_sand = mix(calib_window(0.0, water_beach_edge_lo, sand),
				                       calib_window(water_beach_edge_lo, water_beach_edge_hi, sand),
				                       dry);
				sand = mix(sand, beach_sand, beach);
				sand_col = mix(sand_col, mix(water_beach_wet_color, water_beach_dry_color, dry), beach);
			}
			sand_col *= mix(0.94, 1.06, top_grain * material_fade);
			terr = mix(terr, sand_col, sand);
			land_roughness = mix(land_roughness, water_bar_roughness, sand);
		}
	}
	// Ufersaum, Wasser und Meer trägt die Waldmaske schon nicht.
	if (canopy_full) {
		terr = canopy_col;
		n_ws = normalize(macro_n + vec3(canopy_tilt.x, 0.0, canopy_tilt.y));
		land_roughness = 0.92;
	} else if (canopy_amount > 0.0) {
		terr = mix(terr, canopy_col, canopy_amount);
		n_ws = normalize(mix(n_ws, normalize(macro_n + vec3(canopy_tilt.x, 0.0, canopy_tilt.y)), canopy_amount));
		land_roughness = mix(land_roughness, 0.92, canopy_amount);
	}
#ifdef FLUSSTAL_STUDY
	study_debug_view(v_uv, v_forest, terr);
#endif
	NORMAL = normalize(mat3(VIEW_MATRIX) * n_ws);

	if (debug_difference) {
		// Nur hier gelesen: die Δ-Karte ist eine Diagnose-Ansicht.
		terr = texture(debug_difference_tex, v_uv).rgb;
		land_roughness = 0.9;
	}

	vec4 w = water_at(v_uv);
	// Wasser steigt keine Wand hoch (WaterRender.rasterWallSlopeLo/Hi): die
	// bilineare Kontur des Abfluss-Rasters reicht eine halbe Zelle über die
	// Rinne hinaus, an einer Wand also deren ganze Höhe hinauf — senkrechte
	// Wasserplatten mit Rauten in Schluchten und unter Abbruchkanten. Grobe
	// Steigung aus dem Sim-Gitter (`world_slope`, wie die Gletscherspalten);
	// auf der Rinnensohle misst sie nur das Längs-Gefälle. Am Abfluss-Kanal
	// selbst, damit Wasser UND nasser Ufersaum weichen.
	float stream = w.r * (1.0 - calib_window(water_wall_slope_lo, water_wall_slope_hi, world_slope));
	float lake_gate = w.g;
	float riverMask = calib_window(water_river_mask_lo, water_river_mask_hi, stream);
	float pond = pond_at(v_uv, hval);
	// See-Gate aus demselben Abgriff `w` (bis zum Review zu #174 las
	// `lake_gate_at` die Wasser-Textur hier ein zweites Mal).
	float lakeMask = calib_window(water_pond_contour_lo, water_pond_contour_hi, pond)
	               * calib_window(water_lake_gate_lo, water_lake_gate_hi, lake_gate);
	float wet = max(riverMask, lakeMask);

	float dry = 1.0 - calib_window(water_pond_contour_lo, water_pond_contour_hi, pond);
	float shore = calib_window(water_shore_lo, water_shore_hi, max(stream, lake_gate)) * (1.0 - wet) * dry;
	// Ufersaum feucht und beschattet statt beige (Look-Iteration 12): bis
	// hierher malte der Saum einen grau-beigen Streifen um jedes Band, der
	// Lauf las sich in der Totalen als Straße. Er dunkelt jetzt nur ab, wie
	// der Schatten der Ufergehölze, und liegt auch über dem Kronendach.
	terr = mix(terr, vec3(0.045, 0.085, 0.035), shore * 0.8);
	land_roughness = mix(land_roughness, 0.36, shore * 0.55);

	// Pixel-Ausblendung der Kräuselung wie im Ozean (unter Pixelgröße bleibt
	// die Fläche ruhig), aus der Pixelgröße oben: der Wasser-Block darunter
	// verzweigt je Pixel.
	float ripple_px = 1.0 - smoothstep(0.2, 0.8, px_wp * 3.1);
	vec3 albedo = terr;
	float roughness = land_roughness;
	float specular = 0.5;
	// Der Wasser-Block (Bett-Kies, Kräuselung, Schimmer, Schaum) läuft nur auf
	// nassen Pixeln. Bis zum Review zu #174 lief er auf jedem Landpixel mit
	// (zehn Rauschabfragen), obwohl er dort mit `wet` = 0 nichts beitrug.
	if (wet > 0.0) {
		vec2 dir = w.ba * 2.0 - 1.0;
		// Flussbett: Geröll, Kiesel und Schwemmsand statt Wiese unter dem Wasser
		vec3 river_gravel = mix(vec3(0.33, 0.30, 0.26), vec3(0.46, 0.42, 0.36), breakup);
		river_gravel *= mix(0.85, 1.15, vnoise(wp * 4.5));
		terr = mix(terr, river_gravel, riverMask * 0.88);

		float lake_depth = clamp((pond - water_lake_depth_lo) / max(water_lake_depth_span, 1e-6), 0.0, 1.0) * lakeMask;
		// Fluss-Tiefe aus der Abfluss-Intensität, früh gesättigt: die Intensität
		// springt zwischen Nachbarzellen (8-Bit-Feld, Korridor-Deckel), und linear
		// in die Farbe übernommen zeichnete das bilinear gefilterte Feld helle und
		// dunkle Zellblöcke in breite Läufe. Das Fenster liest R wie
		// `water_river_mask_*` und kommt deshalb wie dieses aus WaterRender.
		float depth = clamp(max(lake_depth, calib_window(water_river_depth_lo, water_river_depth_hi, stream)), 0.0, 1.0);
		float flowing = riverMask >= lakeMask ? 1.0 : 0.0;
		// Gefällestufe der Rinnensohle: dort seicht, hell und schäumend.
		float steep = calib_window(water_raster_steep_lo, water_raster_steep_hi, world_slope) * flowing;
		depth *= mix(1.0, water_riffle_depth, steep);
		float speed = mix(0.25, 1.0 + steep, flowing);
		vec2 d1 = normalize(length(dir) > 0.05 ? dir : vec2(0.7, 0.7));
		float ripple_fade = 1.0 - smoothstep(50.0 * ws, 160.0 * ws, view_dist);
		// Kräuselung als Rauschen mit Fließkarte (zwei Phasen, gegeneinander
		// versetzt überblendet): die Richtung verschiebt das Muster nur um höchstens
		// eine Rauschzelle. Vorher lief die Phase über dot(Weltposition, Richtung)
		// — die Richtung springt aber von Zelle zu Zelle (D8), und mit der langen
		// Weltposition multipliziert malte das Höhenlinien-Moiré, Ringe und
		// Zellblöcke auf jeden See und breiten Lauf (Befund #174). Frequenzen,
		// Phasen-Takt und Amplituden sind eigene Optik-Zahlen dieses Shaders —
		// das Raster-Wasser kräuselt mit 0.015..0.05, keine WaterRender-Konstanten.
		float flow_t = u_time * 0.35 * speed;
		float ph0 = fract(flow_t);
		float ph1 = fract(flow_t + 0.5);
		float w0 = 1.0 - abs(ph0 * 2.0 - 1.0);
		vec2 rp0 = wp * 3.1 - d1 * ph0 * 1.6;
		vec2 rp1 = wp * 3.1 - d1 * ph1 * 1.6 + vec2(5.2, 1.3);
		float re = 0.08;
		float r0 = vnoise(rp0), r1 = vnoise(rp1);
		vec2 g0 = vec2(vnoise(rp0 + vec2(re, 0.0)) - r0, vnoise(rp0 + vec2(0.0, re)) - r0) / re;
		vec2 g1 = vec2(vnoise(rp1 + vec2(re, 0.0)) - r1, vnoise(rp1 + vec2(0.0, re)) - r1) / re;
		float amp = mix(0.015, 0.05, max(depth, steep)) * ripple_fade * ripple_px;
		amp *= riverMask >= lakeMask ? 1.0 : 0.45;
		vec2 grad = (g0 * w0 + g1 * (1.0 - w0)) * amp * 2.0;
		vec3 water_n_ws = normalize(vec3(-grad.x, 1.0, -grad.y));
		vec3 water_n_vs = normalize(mat3(VIEW_MATRIX) * water_n_ws);
		NORMAL = normalize(mix(NORMAL, water_n_vs, wet));

		vec3 water = mix(water_shallow_color, water_deep_color, depth);
		// Seen: ruhig und zur Mitte tiefblau statt petrolgrün wie die Läufe —
		// sonst lasen sich See und Fluss als dasselbe Band.
		water = mix(water, water_lake_color, (1.0 - flowing) * smoothstep(0.2, 0.9, depth));
		// Bett: überwiegend die gemeinsame Bett-Farbe (WaterRender.waterBedColor),
		// nur ein Rest Gelände. Das volle Gelände trug sein Erosions-Detail ins
		// Wasser — Höhenlinien-Moiré und Ringe auf Seen und breiten Läufen.
		vec3 bed = mix(terr * 0.55, water_bed_color, 0.75 * wet);
		float opacity = mix(water_opacity_shallow, water_opacity_deep, depth);
		float ndv = clamp(dot(water_n_vs, VIEW), 0.0, 1.0);
		float fresnel = pow(1.0 - ndv, max(water_fresnel_exponent, 1e-6));

		if (riverMask >= lakeMask && length(dir) > 0.05) {
			// Schimmer aus derselben Fließkarte (nicht über dot(Position,
			// Richtung), s. Kräuselung oben): wandernde Schlieren statt Ringe.
			float flow = (vnoise(rp0 * 0.45) * w0 + vnoise(rp1 * 0.45) * (1.0 - w0)) * 2.0 - 1.0;
			water += flow * water_flow_shimmer_color;
		}

		// Weißwasser nur an Gefällestufen (nicht mehr als Saum an jeder
		// Uferlinie), fleckig über eine Schwelle auf demselben Rauschen.
		float foam_n = vnoise(wp * 4.0 - d1 * u_time * 1.5);
		float foam = smoothstep(1.0 - 0.55 * steep, 1.06 - 0.55 * steep, foam_n) * steep * water_foam_amount;
		water = mix(water, water_riffle_color, steep * smoothstep(0.3, 0.7, foam_n));
		vec3 water_final = mix(bed, water, opacity);
		// Spiegelung statt Farbe (Befund #174 „See milchig"): den Himmel spiegelt
		// Godot selbst (SPECULAR/ROUGHNESS gegen die Umgebung). Der Wasserkörper
		// tritt dafür mit dem Fresnel-Anteil zurück — Godot dämpft die diffuse
		// Albedo nicht mit Fresnel. Bis dahin mischte der Shader eine feste
		// Himmelsfarbe IN DIE ALBEDO; die Sonne beleuchtete sie wie Farbe, und
		// bei flachem Blick lag das Wasser als heller, kontrastloser Film da.
		water_final *= 1.0 - fresnel;
		water_final = mix(water_final, water_foam_color, foam);
		albedo = mix(terr, water_final, wet);
		roughness = mix(land_roughness, mix(water_roughness, 0.7, foam), wet);
		// Fließendes Wasser spiegelt den Himmel schwächer (wie die Bänder).
		specular = mix(0.5, mix(water_specular, water_river_specular, flowing * (1.0 - foam)), wet);
		// Seen spiegeln die Wolken (wie die Altarme in water.gdshader).
		vec3 view_ws = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
		vec3 refl = reflect(-view_ws, water_n_ws);
		vec3 lake_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		// Nur auf stehendem Wasser unter der Wolkenbasis (Review Neon Nr. 9:
		// vorher auch auf jedem fließenden Raster-Pixel, Ergebnis mal 0).
		float cloud_w = water_cloud_reflection * lakeMask * (1.0 - flowing);
		float cloud_hit = clouds_enabled && cloud_w > 0.0 && refl.y > 0.05 && lake_pos.y < cloud_height
			? cloud_cover(lake_pos.xz + refl.xz * (cloud_height - lake_pos.y) / refl.y, u_time) : 0.0;
		EMISSION = vec3(0.9, 0.93, 0.97) * cloud_hit * cloud_w * (0.35 + 0.65 * fresnel);
	}
	ALBEDO = albedo;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = specular;
	if (amplify_debug > 0) {
		ALBEDO = amplify_debug_color(amp_maps, relief.r);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	}
	// Wolkenschatten auf der GERENDERTEN Oberfläche: Weltposition aus dem
	// view-space VERTEX (INV_VIEW_MATRIX), nicht die Sim-Höhe — Seespiegel-
	// Anhebung, Relief-Verschiebung und Kronendach heben die sichtbare
	// Fläche über die Sim-Zelle, und die Schattenprojektion (cloud_sun_shift
	// je Einheit Höhendifferenz) rückte ihn sonst um diese Differenz: geschert
	// auf Seen, versetzt gegen die Bänder, die ihre echte Vertex-Höhe
	// übergeben (Review zu #174 D).
	vec3 shadow_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ALBEDO *= cloud_light(shadow_pos, u_time);
}

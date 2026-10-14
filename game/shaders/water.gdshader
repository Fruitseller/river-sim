// Wasser-Geometrie (Issues #31/#34): Bänder entlang der Mäander-Zentrumslinien,
// ihrer Delta-Distributäre und der abgeschnürten Altarme.
// Vertex-Vertrag von SimNode.buildRiverRibbons:
//   COLOR.rg = Fließrichtung (kodiert dir*0.5+0.5; genau 0 = STILLWASSER),
//   COLOR.b = Strahler-Rang/6, COLOR.a = Deckkraft,
//   UV.x = Quer-Position 0..1, UV.y = Bogenlänge (Welt),
//   UV2.x = Typ (0 Fluss · 0.5 Delta-Arm · 1 Altarm) == WaterRender.ribbonKind*,
//   UV2.y = signierte Bogenstärke −1…+1 (MeanderState.bendStrength, Issue #174
//           C2): + = Linksbogen, Außenufer (Prallhang) bei UV.x = 0. Färbt das
//           Querprofil außen dunkel-tief, innen hell-seicht (Vorlage E).
//           0 = symmetrisch (Wendepunkt, Delta-Arm, Altarm).
// Farben/Glanz sind DIESELBEN wie im Feld-Wasser des Terrain-Shaders, damit
// Band-Wasser und Textur-Zubringer als EIN Wasser lesen: Wasserfarben, Fresnel,
// Rauheit/Specular und der Strömungs-Schimmer kommen als water_*-Uniforms über
// die Brücke (SimCore/WaterRender.swift → SimRender.WaterUniforms → SimNode →
// Main.gd, Issues #91/#92) — beide Shader lesen dieselben Uniforms, der
// Struktur-Vertrag dazu ist SimCoreTests/WaterRenderTests.swift.
//
// Querprofil (Befund #174 „hässlich"): das Band ist kein halbtransparenter
// Schlauch mehr, der über die äußeren 35 % ins Gras ausfedert (las sich als
// aufgemalter Dunst), sondern Wasser im Gelände:
//   Bandkante → nasses Ufer (dunkler Saum, water_ribbon_bank_*)
//   → Wasserlinie (water_ribbon_waterline, mit Rauschen versetzt, kantenscharf
//     nach Pixelgröße geglättet)
//   → Flachwasser über dem Bett (water_bed_color scheint durch)
//   → tiefe Rinne in der Mitte bzw. am Prallhang.
// Die Wasserfläche ist dabei so deckend wie die Deckkraft-Rampe des
// Raster-Wassers (water_opacity_*: Bett ↔ Wasser, nicht Gras ↔ Wasser).
// Kräuselung und Schimmer kommen aus strömungs-ausgerichtetem Rauschen statt
// aus Sinus-Wellen längs der Bogenlänge: die malten gleich weite Querstreifen.
//
// EINE Seite malt (Befund #174, Band über dem See): wo der Terrain-Shader einen
// Raster-See malt, blendet das Band per Pixel aus — mit DERSELBEN See-Maske
// (Spiegel-Kontur × See-Gate aus height_tex/hf_tex/water_tex, dieselben
// Blenden), die Main.gd an dieses Material spiegelt.
shader_type spatial;
render_mode cull_disabled, depth_draw_never;

uniform float u_time = 0.0;

// Band-Überblende im Zeitraffer (#174, Main.gd `ribbon_fade`): nach einem
// Band-Bau zeichnen ZWEI Meshes, der vorige Stand (`ribbon_outgoing`) und der
// neue, mit derselben Blende. Sie teilen sich die optische Dicke
// (`ribbon_fade_alpha`, WaterRender.ribbonFadeOpacity): wo der Lauf
// stillsteht, decken beide zusammen genau wie EIN Band, wo er gewandert ist,
// blendet der alte Stand stetig aus und der neue ein. Weder lineares Mischen
// (Deckkraft 0,95 → 0,72 mitten in der Blende, pulste im Takt der Band-Bauten)
// noch ein Pixel-Los zwischen den Ständen (körnige Ufer, wo sie
// auseinanderliegen).
uniform float ribbon_blend = 1.0;
uniform bool ribbon_outgoing = false;

// Felder des Terrain-Shaders (Main.gd spiegelt dieselben Texturen hierher).
uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D hf_tex : filter_linear, repeat_disable;
uniform sampler2D height_prev_tex : filter_linear, repeat_disable;
uniform sampler2D hf_prev_tex : filter_linear, repeat_disable;
uniform sampler2D water_tex : filter_linear, repeat_disable;
uniform sampler2D water_prev_tex : filter_linear, repeat_disable;
uniform float height_blend = 1.0;
uniform float overlay_blend = 1.0;
uniform float world_size = 100.0;
uniform float sea_level = 0.15;

// Wasser-Kalibrierung über die Brücke (Issues #91/#92): Main.gd setzt die
// Werte beim Aufbau aus SimRender.WaterUniforms. BEWUSST ohne Default — ein
// Literal-Default wäre wieder eine Kopie der Kalibrierung (die #92 abschafft);
// die Editor-Vorschau ohne SimNode ist damit unkalibriert (alles Null), aber
// TOTAL: calib_window unten sichert die Typ-Fenster, max() den
// Fresnel-Exponenten gegen die Null-Uniforms ab (smoothstep mit
// edge0 >= edge1 und pow(0.0, 0.0) sind laut GLSL-Spec undefiniert;
// Review zu #105).
// Wächter: SimCoreTests/WaterUniformsTests.swift (default-frei, gelesen),
// game/tests/water_uniforms.gd (End-to-End: jede Uniform wird gesetzt).
uniform float water_lake_gate_lo;
uniform float water_lake_gate_hi;
uniform float water_pond_contour_lo;
uniform float water_pond_contour_hi;
uniform float water_ribbon_still_lo;
uniform float water_ribbon_still_hi;
uniform float water_ribbon_delta_lo;
uniform float water_ribbon_delta_hi;
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
uniform vec3 water_delta_plume_color;
uniform vec3 water_oxbow_water_color;
uniform float water_ribbon_bend_depth;
uniform float water_ribbon_shoal_mix;
uniform vec3 water_ribbon_shoal_color;
uniform float water_ribbon_waterline;
uniform float water_ribbon_waterline_jitter;
uniform float water_ribbon_waterline_scale;
uniform float water_ribbon_bank_opacity;
uniform float water_ribbon_fade_cap;
uniform vec3 water_ribbon_bank_color;
uniform vec3 water_bed_color;
uniform float water_ribbon_ripple_frequency;
uniform float water_ribbon_ripple_amplitude;
uniform float water_ribbon_ripple_stretch;
uniform float water_ribbon_ripple_speed;
uniform float water_ocean_wave_lacunarity;
uniform float water_ocean_wave_gain;
uniform float water_ocean_wave_fade_lo;
uniform float water_ocean_wave_fade_hi;

// Kalibrier-Fenster, total auch mit Null-Uniforms (Editor-Vorschau ohne
// SimNode, s. Deklarationsblock oben) — dasselbe Epsilon wie im
// Terrain-Shader: Mindest-Fensterbreite, keine Kalibrier-Kopie.
float calib_window(float lo, float hi, float x) {
	return smoothstep(lo, max(hi, lo + 1e-6), x);
}

// Deckkraft dieses Stands in der Überblende: Anteil `share` an der optischen
// Dicke −ln(1 − a). Gedeckelt (water_ribbon_fade_cap), sonst wäre sie bei
// a = 1 unendlich und ein allein liegender Stand spränge sofort auf voll.
// Außerhalb der Blende (share 1) unverändert.
float ribbon_fade_alpha(float a) {
	float share = ribbon_outgoing ? 1.0 - ribbon_blend : ribbon_blend;
	if (share >= 1.0) {
		return a;
	}
	return 1.0 - pow(1.0 - clamp(a, 0.0, water_ribbon_fade_cap), max(share, 0.0));
}

varying vec2 v_dir;
varying float v_rank;
varying float v_alpha;
varying float v_kind;
varying float v_bend;
varying vec3 v_world;

// Wolkenschatten (#151) laufen ohne Kante über die Bänder weiter.
#include "res://shaders/clouds.gdshaderinc"

// Wertrauschen wie im Ozean-Shader (Hash-Konstanten sind keine Kalibrierung).
float ribbon_hash(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float ribbon_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(ribbon_hash(i), ribbon_hash(i + vec2(1.0, 0.0)), u.x),
	           mix(ribbon_hash(i + vec2(0.0, 1.0)), ribbon_hash(i + vec2(1.0)), u.x), u.y);
}

// Wasserfeld mit derselben Zeitraffer-Blende wie `water_at` im Terrain-Shader.
float water_g_at(vec2 uv) {
	float g = texture(water_tex, uv).g;
	return overlay_blend < 1.0 ? mix(texture(water_prev_tex, uv).g, g, overlay_blend) : g;
}

// See-Maske GENAU wie terrain.gdshader (height_at/hf_at/pond_at/lake_gate_at):
// was dort als See gemalt wird, malt hier niemand ein zweites Mal.
float lake_mask_at(vec2 uv) {
	float h = texture(height_tex, uv).r;
	h = height_blend < 1.0 ? mix(texture(height_prev_tex, uv).r, h, height_blend) : h;
	float hf = texture(hf_tex, uv).r;
	hf = overlay_blend < 1.0 ? mix(texture(hf_prev_tex, uv).r, hf, overlay_blend) : hf;
	float pond = max(hf - h, 0.0) * step(sea_level, hf);
	return calib_window(water_pond_contour_lo, water_pond_contour_hi, pond)
		* calib_window(water_lake_gate_lo, water_lake_gate_hi, water_g_at(uv));
}

// Kräusel-Gradient in Strömungs-Koordinaten (x längs, y quer): Rausch-Oktaven,
// längs gestreckt und stromab verschoben. Jede Oktave blendet aus, sobald ihre
// Zellen unter die Pixelgröße fallen (Fenster und Oktaven-Folge teilt das Band
// mit dem Ozean) — die Ferne bleibt ruhig statt zu flimmern. Versätze und
// Differenzen-Schritt sind numerisch, keine Kalibrierung.
vec2 ribbon_ripple_grad(vec2 q, float footprint) {
	vec2 g = vec2(0.0);
	float freq = water_ribbon_ripple_frequency;
	float amp = water_ribbon_ripple_amplitude;
	for (int o = 0; o < 3; o++) {
		vec2 p = q * freq + vec2(float(o) * 13.7, float(o) * 7.1);
		float e = 0.08;
		float n0 = ribbon_noise(p);
		vec2 d = vec2(ribbon_noise(p + vec2(e, 0.0)) - n0, ribbon_noise(p + vec2(0.0, e)) - n0) / e;
		g += d * amp * (1.0 - calib_window(water_ocean_wave_fade_lo, water_ocean_wave_fade_hi, footprint * freq));
		freq *= water_ocean_wave_lacunarity;
		amp *= water_ocean_wave_gain;
	}
	return g;
}

void vertex() {
	v_dir = COLOR.rg * 2.0 - 1.0;
	v_rank = COLOR.b;
	v_alpha = COLOR.a;
	v_kind = UV2.x;
	v_bend = UV2.y;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Typ-Gewichte aus UV2.x (0 Fluss · 0.5 Delta · 1 Altarm). Als weiche
	// Gewichte statt if-Kaskade: die Werte kommen pro Vertex und werden über
	// das Band interpoliert, an Bandgrenzen gibt es also keine harte Kante.
	float still = calib_window(water_ribbon_still_lo, water_ribbon_still_hi, v_kind); // Altarm: keine Strömung
	float delta = (1.0 - still) * calib_window(water_ribbon_delta_lo, water_ribbon_delta_hi, v_kind); // Delta-Arm

	// Ableitungen VOR jedem bedingten Pfad (s. ocean.gdshader).
	float across = 1.0 - abs(UV.x * 2.0 - 1.0); // 0 = Bandkante, 1 = Mitte
	float aa = max(fwidth(across), 1e-4);
	float footprint = length(fwidth(v_world.xz));

	// Wasserlinie: um ein Rauschen versetzt, damit das Ufer nicht als
	// Lineal-Kante parallel zur Zentrumslinie läuft; Glättung nach Pixelgröße
	// (scharf in der Nähe, weich in der Übersicht, nie treppig).
	// Die Deckkraft des Vertex-Vertrags (Taper, Abfluss-Rampe, Übergaben)
	// wirkt als SCHMALER werdendes Wasser, nicht als Transparenz: ein
	// halbdurchsichtiges Band mit scharfer Wasserlinie las sich als Glasrohr.
	// Erst ganz zuletzt blendet der Rest aus. Die Fenster sind eigene
	// Optik-Zahlen dieses Shaders, keine WaterRender-Konstanten.
	float presence = clamp(v_alpha, 0.0, 1.0);
	float line = mix(0.9, water_ribbon_waterline, smoothstep(0.05, 0.75, presence))
		+ (ribbon_noise(v_world.xz * water_ribbon_waterline_scale) - 0.5) * 2.0 * water_ribbon_waterline_jitter;
	float wet = smoothstep(line - aa, line + aa, across);
	float bank = calib_window(0.0, line, across) * (1.0 - wet);
	float profile = calib_window(line, 1.0, across); // 0 Wasserlinie … 1 Mitte

	// Tiefe ∝ Strahler-Rang (Hierarchie: große Läufe tief, Bäche seicht), zur
	// Wasserlinie hin seicht (Querprofil eines echten Gerinnes).
	// Fast gleichmäßig tief bis an die Wasserlinie: ein über die Breite
	// durchlaufender Tiefenverlauf (und erst recht ein heller Flachwasser-
	// Saum) las sich als Rohr mit dunkler Mittellinie. Die Asymmetrie
	// Prallhang/Gleithang trägt das Bogenprofil darunter.
	float depth = clamp(0.35 + v_rank * 1.5, 0.0, 1.0) * mix(0.7, 1.0, smoothstep(0.0, 0.45, profile));
	// Delta-Arme liegen auf dem Ablagerungskörper: per Definition Flachwasser.
	depth = mix(depth, depth * 0.35, delta);
	// Querprofil im Bogen (Issue #174 C2, Spiegel: WaterRender.ribbonOutward):
	// +1 am Prallhang (Kolk, tief), −1 am Gleithang (Bank, seicht).
	float outward = -(UV.x * 2.0 - 1.0) * clamp(v_bend, -1.0, 1.0);
	depth = clamp(depth + water_ribbon_bend_depth * outward, 0.0, 1.0);

	vec3 water = mix(water_shallow_color, water_deep_color, depth);
	// Delta: sedimentbeladene Fahne über der Seefläche — heller und wärmer als
	// das Becken, sonst läse sich der Fächer als zweite Wasserfläche statt als
	// das, was er ist (Trübung über dem Ablagerungskörper).
	water = mix(water, water_delta_plume_color, delta * 0.5);
	// Altarm: stehendes, trübes Auwasser — grünlicher als der klare Lauf.
	water = mix(water, water_oxbow_water_color, still * 0.5);

	// Strömungs-Koordinaten des BANDS: x = Bogenlänge (UV.y, Welt, stromab
	// stetig), y = Quer-Position (UV.x, in Welt-Maß über die Fließrichtung
	// genähert). NICHT dot(Welt-Position, Richtung): die Richtung dreht je
	// Stützpunkt, und das Produkt mit einer ~50 Einheiten langen Position
	// sprang von Quad zu Quad — Querschraffur. Stillwasser hat keine Richtung
	// und kräuselt nur schwach.
	vec2 d1 = normalize(length(v_dir) > 0.05 ? v_dir : vec2(0.7, 0.7));
	vec2 d2 = vec2(-d1.y, d1.x);
	float speed = water_ribbon_ripple_speed * (1.0 - still);
	vec2 q = vec2(UV.y * water_ribbon_ripple_stretch - u_time * speed, UV.x);
	vec2 gq = ribbon_ripple_grad(q, footprint) * mix(1.0, 0.4, still) * mix(0.6, 1.0, depth);
	vec2 grad = d1 * gq.x * water_ribbon_ripple_stretch + d2 * gq.y;
	vec3 water_n_ws = normalize(vec3(-grad.x, 1.0, -grad.y));
	vec3 water_n_vs = normalize(mat3(VIEW_MATRIX) * water_n_ws);

	// Fresnel: flacher Blick spiegelt Himmel (Ton wie terrain.gdshader).
	float ndv = clamp(dot(water_n_vs, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, max(water_fresnel_exponent, 1e-6));
	water = mix(water, water_sky_reflect_color, fresnel * water_fresnel_sky_mix);

	// Strömungs-Schimmer stromab: lange, langsam wandernde Schlieren aus
	// demselben Rauschen (Bewegung im Zeitraffer ablesbar, aber kein
	// Streifenmuster). Ein Altarm hat KEINE Fließrichtung mehr.
	float flow = (ribbon_noise(vec2(q.x * 0.35 - u_time * speed * 0.5, q.y * 2.2) * water_ribbon_ripple_frequency + 5.3) - 0.5) * 2.0;
	water += flow * water_flow_shimmer_color * (1.0 - still);

	// Flachwasser: das Bett scheint durch (dieselbe Deckkraft-Rampe wie das
	// Raster-Wasser im Terrain-Shader, dort über dem echten Gelände). Am
	// Gleithang zusätzlich die Bank — nur im Saum an der Wasserlinie: über die
	// halbe Bandbreite gezogen lag sie als milchiger Schleier auf dem Fluss.
	vec3 water_final = mix(water_bed_color, water, mix(water_opacity_shallow, water_opacity_deep, depth));
	water_final = mix(water_final, water_ribbon_shoal_color,
		water_ribbon_shoal_mix * max(-outward, 0.0) * (1.0 - smoothstep(0.0, 0.6, profile)));

	vec3 col = mix(water_ribbon_bank_color, water_final, wet);
	col *= cloud_light(v_world.xz, u_time);
	ALBEDO = col;
	NORMAL = normalize(mix(mat3(VIEW_MATRIX) * vec3(0.0, 1.0, 0.0), water_n_vs, wet));
	float lake = lake_mask_at((v_world.xz + world_size * 0.5) / world_size);
	ALPHA = ribbon_fade_alpha(smoothstep(0.0, 0.25, presence) * max(wet, bank * water_ribbon_bank_opacity)
		* (1.0 - lake * (1.0 - delta)));
	// Die 0.55 ist die Stillwasser-Rauheit des Altarms (nur dieser Shader kennt
	// Stillwasser) — numerisch zufällig gleich fresnelSkyMix/waterOpacityShallow,
	// KEINE WaterRender-Konstante. Das nasse Ufer glänzt matt (0.6).
	float water_rough = mix(mix(water_roughness_steep, water_roughness_grazing, fresnel), 0.55, still);
	ROUGHNESS = mix(0.6, water_rough, wet);
	SPECULAR = mix(0.4, mix(water_specular_steep, water_specular_grazing, fresnel), wet);
}

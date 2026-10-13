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
// Struktur-Vertrag dazu ist SimCoreTests/WaterRenderTests.swift. Der Übergang
// zum Ufer läuft doppelt weich: Kanten-Feathering hier (Alpha → 0 zur
// Bandkante) + Nass-Halo des Terrain-Shaders (Saum-Stempel im Wasserfeld)
// darunter — gegen die dokumentierte Rückbau-Ursache von f3556c8 (harte
// Ribbon-Kanten).
shader_type spatial;
render_mode cull_disabled, depth_draw_never;

uniform float u_time = 0.0;

// Band-Überblende im Zeitraffer (#174, Main.gd `ribbon_fade`): nach einem
// Band-Bau zeichnen ZWEI Meshes, der vorige Stand (`ribbon_outgoing`) und der
// neue, mit derselben Blende. Jedes Pixel zeigt genau EINES der beiden, in
// fester Rausch-Reihenfolge: bei `ribbon_blend` = t hat der neue Stand den
// Anteil t der Pixel. Kein Alpha-Mischen: zwei übereinanderliegende
// halbdurchsichtige Bänder würden dort, wo der Lauf stillsteht, mitten in der
// Blende durchsichtiger (Deckkraft 0,95 → 0,72 bei t = 0,5) und pulsierten im
// Takt der Band-Bauten. So bleibt die Deckkraft überall die eines Bands; wo
// sich Lage oder Breite ändern, löst sich der alte Stand auf.
uniform float ribbon_blend = 1.0;
uniform bool ribbon_outgoing = false;

bool ribbon_hidden(vec2 frag) {
	// Interleaved Gradient Noise: gleichverteilt je Bildschirm-Pixel, ortsfest.
	float r = fract(52.9829189 * fract(dot(frag, vec2(0.06711056, 0.00583715))));
	return ribbon_outgoing ? r < ribbon_blend : r >= ribbon_blend;
}

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

// Kalibrier-Fenster, total auch mit Null-Uniforms (Editor-Vorschau ohne
// SimNode, s. Deklarationsblock oben) — dasselbe Epsilon wie im
// Terrain-Shader: Mindest-Fensterbreite, keine Kalibrier-Kopie.
float calib_window(float lo, float hi, float x) {
	return smoothstep(lo, max(hi, lo + 1e-6), x);
}

varying vec2 v_dir;
varying float v_rank;
varying float v_alpha;
varying float v_kind;
varying float v_bend;
varying vec3 v_world;

// Wolkenschatten (#151) laufen ohne Kante über die Bänder weiter.
#include "res://shaders/clouds.gdshaderinc"

void vertex() {
	v_dir = COLOR.rg * 2.0 - 1.0;
	v_rank = COLOR.b;
	v_alpha = COLOR.a;
	v_kind = UV2.x;
	v_bend = UV2.y;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (ribbon_hidden(FRAGCOORD.xy)) {
		discard;
	}
	// Typ-Gewichte aus UV2.x (0 Fluss · 0.5 Delta · 1 Altarm). Als weiche
	// Gewichte statt if-Kaskade: die Werte kommen pro Vertex und werden über
	// das Band interpoliert, an Bandgrenzen gibt es also keine harte Kante.
	float still = calib_window(water_ribbon_still_lo, water_ribbon_still_hi, v_kind); // Altarm: keine Strömung
	float delta = (1.0 - still) * calib_window(water_ribbon_delta_lo, water_ribbon_delta_hi, v_kind); // Delta-Arm

	// Quer-Profil: Mitte tief, Kanten seicht — Feathering über die äußeren 35 %.
	float across = min(UV.x, 1.0 - UV.x); // 0 = Bandkante, 0.5 = Mitte
	float feather = smoothstep(0.0, 0.35, across);
	// Tiefe ∝ Strahler-Rang (Hierarchie: große Läufe tiefblau, Bäche seicht),
	// zur Kante hin seichter (Tiefen-Profil eines echten Gerinnes).
	float depth = clamp(0.35 + v_rank * 1.5, 0.0, 1.0) * mix(0.35, 1.0, feather);
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
	// Gleithang: über der Bank scheint der Sand durch.
	water = mix(water, water_ribbon_shoal_color, water_ribbon_shoal_mix * max(-outward, 0.0));

	// Kräusel-Normale wie beim Feld-Wasser: Wellen entlang der Bogenlänge
	// (folgen der Kurve) + quer, analytischer Gradient → Glints. Stillwasser
	// kräuselt nur schwach und ohne Vorzugsrichtung.
	float speed = mix(1.0, 0.2, still);
	float p1 = UV.y * 2.3 - u_time * 5.0 * speed;
	float p2 = v_world.x * 4.1 + v_world.z * 3.7 - u_time * 3.1 * speed;
	// Amplituden-Fenster der Band-Kräusel: eigene Optik-Zahl dieses Shaders —
	// die 0.05 ist numerisch zufällig gleich geometryLiftHi, KEINE
	// WaterRender-Konstante (das Raster-Wasser kräuselt mit 0.015..0.05).
	float amp = mix(0.02, 0.05, depth) * mix(1.0, 0.4, still);
	vec2 d1 = normalize(length(v_dir) > 0.05 ? v_dir : vec2(0.7, 0.7));
	vec2 grad = d1 * (2.3 * cos(p1)) * amp * (1.0 - still) + vec2(0.6, 0.55) * (cos(p2) * amp);
	vec3 water_n_ws = normalize(vec3(-grad.x, 1.0, -grad.y));
	vec3 water_n_vs = normalize(mat3(VIEW_MATRIX) * water_n_ws);
	NORMAL = water_n_vs;

	// Fresnel: flacher Blick spiegelt Himmel (Ton wie terrain.gdshader).
	float ndv = clamp(dot(water_n_vs, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, max(water_fresnel_exponent, 1e-6));
	water = mix(water, water_sky_reflect_color, fresnel * water_fresnel_sky_mix);

	// Strömungs-Schimmer stromab (Bewegung im Zeitraffer ablesbar) — ein Altarm
	// hat KEINE Fließrichtung mehr, genau daran soll man ihn erkennen.
	float flow = sin(UV.y * 1.4 - u_time * 4.0) * 0.5
		+ sin(UV.y * 3.1 - u_time * 6.5 + 1.7) * 0.5;
	water += flow * water_flow_shimmer_color * (1.0 - still);

	water *= cloud_light(v_world.xz, u_time);
	ALBEDO = water;
	ALPHA = clamp(v_alpha, 0.0, 1.0) * mix(water_opacity_shallow, water_opacity_deep, depth) * feather;
	// Die 0.55 ist die Stillwasser-Rauheit des Altarms (nur dieser Shader kennt
	// Stillwasser) — numerisch zufällig gleich fresnelSkyMix/waterOpacityShallow,
	// KEINE WaterRender-Konstante.
	ROUGHNESS = mix(mix(water_roughness_steep, water_roughness_grazing, fresnel), 0.55, still);
	SPECULAR = mix(water_specular_steep, water_specular_grazing, fresnel);
}

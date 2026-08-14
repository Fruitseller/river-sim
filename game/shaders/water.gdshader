// Wasser-Geometrie (Issues #31/#34): Bänder entlang der Mäander-Zentrumslinien,
// ihrer Delta-Distributäre und der abgeschnürten Altarme.
// Vertex-Vertrag von SimNode.buildRiverRibbons:
//   COLOR.rg = Fließrichtung (kodiert dir*0.5+0.5; genau 0 = STILLWASSER),
//   COLOR.b = Strahler-Rang/6, COLOR.a = Deckkraft,
//   UV.x = Quer-Position 0..1, UV.y = Bogenlänge (Welt),
//   UV2.x = Typ (0 Fluss · 0.5 Delta-Arm · 1 Altarm) == WaterRender.ribbonKind*.
// Farben/Glanz sind DIESELBEN wie im Feld-Wasser des Terrain-Shaders, damit
// Band-Wasser und Textur-Zubringer als EIN Wasser lesen: Wasserfarben, Fresnel,
// Rauheit/Specular und der Strömungs-Schimmer stehen in SimCore/WaterRender.swift
// und werden von SimCoreTests/WaterRenderTests.swift gegen BEIDE Shader-
// Quelltexte verglichen (Issue #51) — wer hier eine Zahl ändert, ändert sie dort
// und im Terrain-Shader mit, sonst wird der Test rot. Der Übergang zum
// Ufer läuft doppelt weich: Kanten-Feathering hier (Alpha → 0 zur Bandkante)
// + Nass-Halo des Terrain-Shaders (Saum-Stempel im Wasserfeld) darunter —
// gegen die dokumentierte Rückbau-Ursache von f3556c8 (harte Ribbon-Kanten).
shader_type spatial;
render_mode cull_disabled, depth_draw_never;

uniform float u_time = 0.0;

varying vec2 v_dir;
varying float v_rank;
varying float v_alpha;
varying float v_kind;
varying vec3 v_world;

void vertex() {
	v_dir = COLOR.rg * 2.0 - 1.0;
	v_rank = COLOR.b;
	v_alpha = COLOR.a;
	v_kind = UV2.x;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Typ-Gewichte aus UV2.x (0 Fluss · 0.5 Delta · 1 Altarm). Als weiche
	// Gewichte statt if-Kaskade: die Werte kommen pro Vertex und werden über
	// das Band interpoliert, an Bandgrenzen gibt es also keine harte Kante.
	float still = smoothstep(0.75, 1.0, v_kind);        // Altarm: keine Strömung
	float delta = (1.0 - still) * smoothstep(0.25, 0.5, v_kind); // Delta-Arm

	// Quer-Profil: Mitte tief, Kanten seicht — Feathering über die äußeren 35 %.
	float across = min(UV.x, 1.0 - UV.x); // 0 = Bandkante, 0.5 = Mitte
	float feather = smoothstep(0.0, 0.35, across);
	// Tiefe ∝ Strahler-Rang (Hierarchie: große Läufe tiefblau, Bäche seicht),
	// zur Kante hin seichter (Tiefen-Profil eines echten Gerinnes).
	float depth = clamp(0.35 + v_rank * 1.5, 0.0, 1.0) * mix(0.35, 1.0, feather);
	// Delta-Arme liegen auf dem Ablagerungskörper: per Definition Flachwasser.
	depth = mix(depth, depth * 0.35, delta);

	vec3 shallow = vec3(0.18, 0.37, 0.42);
	vec3 deep = vec3(0.03, 0.12, 0.26);
	vec3 water = mix(shallow, deep, depth);
	// Delta: sedimentbeladene Fahne über der Seefläche — heller und wärmer als
	// das Becken, sonst läse sich der Fächer als zweite Wasserfläche statt als
	// das, was er ist (Trübung über dem Ablagerungskörper).
	water = mix(water, vec3(0.34, 0.38, 0.33), delta * 0.5);
	// Altarm: stehendes, trübes Auwasser — grünlicher als der klare Lauf.
	water = mix(water, vec3(0.16, 0.28, 0.24), still * 0.5);

	// Kräusel-Normale wie beim Feld-Wasser: Wellen entlang der Bogenlänge
	// (folgen der Kurve) + quer, analytischer Gradient → Glints. Stillwasser
	// kräuselt nur schwach und ohne Vorzugsrichtung.
	float speed = mix(1.0, 0.2, still);
	float p1 = UV.y * 2.3 - u_time * 5.0 * speed;
	float p2 = v_world.x * 4.1 + v_world.z * 3.7 - u_time * 3.1 * speed;
	float amp = mix(0.02, 0.05, depth) * mix(1.0, 0.4, still);
	vec2 d1 = normalize(length(v_dir) > 0.05 ? v_dir : vec2(0.7, 0.7));
	vec2 grad = d1 * (2.3 * cos(p1)) * amp * (1.0 - still) + vec2(0.6, 0.55) * (cos(p2) * amp);
	vec3 water_n_ws = normalize(vec3(-grad.x, 1.0, -grad.y));
	vec3 water_n_vs = normalize(mat3(VIEW_MATRIX) * water_n_ws);
	NORMAL = water_n_vs;

	// Fresnel: flacher Blick spiegelt Himmel (Ton wie terrain.gdshader).
	float ndv = clamp(dot(water_n_vs, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, 5.0);
	vec3 sky = vec3(0.62, 0.7, 0.76);                   // Ton wie terrain.gdshader
	water = mix(water, sky, fresnel * 0.55);

	// Strömungs-Schimmer stromab (Bewegung im Zeitraffer ablesbar) — ein Altarm
	// hat KEINE Fließrichtung mehr, genau daran soll man ihn erkennen.
	float flow = sin(UV.y * 1.4 - u_time * 4.0) * 0.5
		+ sin(UV.y * 3.1 - u_time * 6.5 + 1.7) * 0.5;
	water += flow * vec3(0.012, 0.018, 0.025) * (1.0 - still);

	ALBEDO = water;
	ALPHA = clamp(v_alpha, 0.0, 1.0) * mix(0.55, 0.95, depth) * feather;
	ROUGHNESS = mix(mix(0.34, 0.08, fresnel), 0.55, still);
	SPECULAR = mix(0.55, 1.0, fresnel);
}

// Fluss-Ribbons (Issue #31): Band-Geometrie entlang der Mäander-Zentrumslinien.
// Vertex-Vertrag von SimNode.buildRiverRibbons:
//   COLOR.rg = Fließrichtung (kodiert dir*0.5+0.5), COLOR.b = Strahler-Rang/6,
//   COLOR.a = Deckkraft, UV.x = Quer-Position 0..1, UV.y = Bogenlänge (Welt).
// Farben/Glanz sind an das Feld-Wasser des Terrain-Shaders angelehnt, damit
// Ribbon-Mäander und Textur-Zubringer als EIN Wasser lesen. Der Übergang zum
// Ufer läuft doppelt weich: Kanten-Feathering hier (Alpha → 0 zur Bandkante)
// + Nass-Halo des Terrain-Shaders (Saum-Stempel im Wasserfeld) darunter —
// gegen die dokumentierte Rückbau-Ursache von f3556c8 (harte Ribbon-Kanten).
shader_type spatial;
render_mode cull_disabled, depth_draw_never;

uniform float u_time = 0.0;

varying vec2 v_dir;
varying float v_rank;
varying float v_alpha;
varying vec3 v_world;

void vertex() {
	v_dir = COLOR.rg * 2.0 - 1.0;
	v_rank = COLOR.b;
	v_alpha = COLOR.a;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Quer-Profil: Mitte tief, Kanten seicht — Feathering über die äußeren 35 %.
	float across = min(UV.x, 1.0 - UV.x); // 0 = Bandkante, 0.5 = Mitte
	float feather = smoothstep(0.0, 0.35, across);
	// Tiefe ∝ Strahler-Rang (Hierarchie: große Läufe tiefblau, Bäche seicht),
	// zur Kante hin seichter (Tiefen-Profil eines echten Gerinnes).
	float depth = clamp(0.35 + v_rank * 1.5, 0.0, 1.0) * mix(0.35, 1.0, feather);

	vec3 shallow = vec3(0.18, 0.37, 0.42);
	vec3 deep = vec3(0.03, 0.12, 0.26);
	vec3 water = mix(shallow, deep, depth);

	// Kräusel-Normale wie beim Feld-Wasser: Wellen entlang der Bogenlänge
	// (folgen der Kurve) + quer, analytischer Gradient → Glints.
	float p1 = UV.y * 2.3 - u_time * 5.0;
	float p2 = v_world.x * 4.1 + v_world.z * 3.7 - u_time * 3.1;
	float amp = mix(0.02, 0.05, depth);
	vec2 d1 = normalize(length(v_dir) > 0.05 ? v_dir : vec2(0.7, 0.7));
	vec2 grad = d1 * (2.3 * cos(p1)) * amp + vec2(0.6, 0.55) * (cos(p2) * amp);
	vec3 water_n_ws = normalize(vec3(-grad.x, 1.0, -grad.y));
	vec3 water_n_vs = normalize(mat3(VIEW_MATRIX) * water_n_ws);
	NORMAL = water_n_vs;

	// Fresnel: flacher Blick spiegelt Himmel (Ton wie terrain.gdshader).
	float ndv = clamp(dot(water_n_vs, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, 5.0);
	water = mix(water, vec3(0.62, 0.70, 0.76), fresnel * 0.55);

	// Strömungs-Schimmer stromab (Bewegung im Zeitraffer ablesbar).
	float flow = sin(UV.y * 1.4 - u_time * 4.0) * 0.5
		+ sin(UV.y * 3.1 - u_time * 6.5 + 1.7) * 0.5;
	water += flow * vec3(0.012, 0.018, 0.025);

	ALBEDO = water;
	ALPHA = clamp(v_alpha, 0.0, 1.0) * mix(0.55, 0.95, depth) * feather;
	ROUGHNESS = mix(0.34, 0.08, fresnel);
	SPECULAR = mix(0.55, 1.0, fresnel);
}

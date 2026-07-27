// Textur-Displacement-Terrain: ein statisches Gitter wird in der GPU nach dem
// Höhenfeld (height_tex, R32F) verschoben; Normalen aus Nachbar-Texeln; Farbe
// aus color_tex. Wasser (Flüsse/Seen/Altarme) kommt als GLATTES Feld-Overlay aus
// water_tex (R=Fluss-Intensität, G=Seetiefe, BA=Fließrichtung) — kein blockiges
// Pro-Zell-Wasser, sondern linear gefiltert und geshadet (nasser Glanz).
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D color_tex : filter_linear, repeat_disable;
uniform sampler2D water_tex : filter_linear, repeat_disable;
uniform float hscale = 26.0;
uniform float world_size = 100.0;
uniform float grid_n = 256.0;
uniform float u_time = 0.0;

varying vec2 v_uv;

// UV aus der Weltposition ableiten (statt Mesh-UV) → deckungsgleich mit der
// Zellindizierung des Sim-Kerns und damit mit Flüssen/Wasser.
vec2 world_uv(vec3 vert) {
	return (vert.xz + world_size * 0.5) / world_size;
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

	// Tiefe skaliert mit dem Abfluss (stream-Intensität) → Hauptflüsse tief-blau,
	// Bäche seicht-teal. Erzeugt die sichtbare Fluss-Hierarchie.
	float depth = clamp(max(lake * 2.5, stream), 0.0, 1.0);

	// --- „Echtes Wasser" statt angemalter Erde ---
	// (1) Wasser hat eine EIGENE Oberfläche: flache Welt-Normale mit animierten
	// Kräusel-Wellen — nicht die Fels-Normale des Flussbetts darunter. Erst dadurch
	// fängt es Sonne/Himmel wie eine Wasserfläche (Glints), statt wie nasser Stein.
	vec2 wp = v_uv * world_size;
	float speed = riverMask >= lakeMask ? 1.0 : 0.25;      // Seen kräuseln nur träge
	vec2 d1 = normalize(length(dir) > 0.05 ? dir : vec2(0.7, 0.7));
	vec2 d2 = vec2(-d1.y, d1.x);                            // quer zur Fließrichtung
	// Wellen-Höhenfeld h = Σ aᵢ·sin(fᵢ·x − ωᵢ·t): Gradient analytisch → Normale.
	float p1 = dot(wp, d1) * 2.3 - u_time * 5.0 * speed;
	float p2 = dot(wp, d2) * 4.1 + dot(wp, d1) * 1.3 - u_time * 3.1 * speed;
	float p3 = dot(wp, d1 + d2) * 6.3 - u_time * 7.3 * speed + 1.7;
	// Kräuselung mit der Kameradistanz ausblenden: von weitem aliast die
	// Wellen-Normale sonst zu weißem Specular-Glitzer (Konfetti auf den Seen).
	float ripple_fade = 1.0 - smoothstep(50.0, 160.0, length(VERTEX));
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

	vec3 water_final = mix(bed, water, opacity);
	ALBEDO = mix(terr, water_final, wet);
	// nasser Glanz: bei STEILEM Blick matter (sonst spiegelt der graue Himmel die
	// Farbe milchig-weg), erst bei flachem Winkel (Fresnel) glasklar spiegelnd.
	ROUGHNESS = mix(0.95, mix(0.34, 0.08, fresnel), wet);
	METALLIC = 0.0;
	SPECULAR = mix(0.5, mix(0.55, 1.0, fresnel), wet);
}

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
	float riverMask = smoothstep(0.12, 0.55, stream);
	float lakeMask = smoothstep(0.03, 0.16, lake);
	float wet = max(riverMask, lakeMask);

	// Wasserfarbe: entsättigtes Teal (Vorbild nickmcd), tiefer → dunkler
	float depth = clamp(max(lake * 2.5, riverMask * 0.6), 0.0, 1.0);
	vec3 shallow = vec3(0.34, 0.52, 0.53);
	vec3 deep = vec3(0.13, 0.32, 0.40);
	vec3 water = mix(shallow, deep, depth);

	// Animation: Flüsse strömen entlang dir, Seen kräuseln nur (niedrige Frequenz)
	vec2 wp = v_uv * world_size;
	if (riverMask >= lakeMask && length(dir) > 0.05) {
		float along = dot(wp, normalize(dir));
		float flow = 0.5 * sin(along * 1.4 - u_time * 4.0)
			+ 0.5 * sin(along * 3.1 - u_time * 6.5 + 1.7);
		water += flow * vec3(0.025, 0.035, 0.05);
	} else {
		float rip = sin(wp.x * 0.3 + u_time) * sin(wp.y * 0.34 + u_time * 0.8);
		water += rip * vec3(0.02, 0.025, 0.03);
	}

	ALBEDO = mix(terr, water, wet);
	// nasser Glanz: Wasser glatt (niedrige Roughness) mit etwas Spiegelung
	ROUGHNESS = mix(0.95, 0.18, wet);
	METALLIC = 0.0;
	SPECULAR = mix(0.5, 0.9, wet);
}

// Talnebel (#237): Dunst nur in Tälern und flach über dem Meer, in
// Sonnenfarbe. Kein gleichmäßiger Schleier: die Look-Iterationen 9 und 17
// verloren mit dichterem bzw. tieferem Dunst gegen „milchig“ (Kontrastverlust
// überall, auch in der Nahsicht, docs/look-hillclimb-log.md).
//
// Bauform: wenige transparente Lagen über der Insel. Jede Lage liegt eine
// feste Schichtdicke über dem TIEFSTEN Gelände der Umgebung (Minimum der
// Höhe über ~1,4 km, im Vertex-Shader aus height_tex), über dem Meer knapp
// über dem Spiegel. Sichtbar wird sie nur, wo das Gelände unter ihr liegt,
// und umso dichter, je tiefer es darunter liegt: auf Talböden, in Becken und
// über dem Meer; Hänge und Grate stehen darüber. Die erste Fassung legte die
// Lage auf das MITTEL der Umgebung: auf breiten Talböden lag sie dann im
// Boden, Nebel gab es nur als Saum an den Talflanken. Die Dicke der Luftschicht unter der Lage
// rechnet das Fragment aus derselben Höhe, die Kante ist damit weich ohne
// Tiefenpuffer. Rauschen bricht die Lage in Schwaden.
//
// Stärke koppelt am Kameraabstand (Main.gd → ValleyFog.gd): in der Nahsicht
// fast null, damit `nah` keinen Kontrast verliert; in der Totalen staffelt
// der Nebel die Tiefe. Rein visuell, die Sim bleibt unberührt.
shader_type spatial;
// Unbeleuchtet: beleuchtet las sich die Lage im Talschatten als brauner
// Schmutzfilm (erste Fassung). Dunst streut das Sonnenlicht auch im Schatten.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform sampler2D height_tex : filter_linear, repeat_disable, hint_default_black;
uniform float world_size;
uniform float grid_n;
uniform float hscale;
uniform float sea_y;
uniform float u_time;
// 0 … 1 je Lage (unten → oben); obere Lagen nur im Kern.
uniform float fog_layer;
// Gesamtstärke (Kameraabstand, ValleyFog.gd).
uniform float fog_strength;
uniform vec3 fog_color;
// Abstand Kamera → Fokuspunkt (ValleyFog/Atmosphere.gd): dahinter wird der
// Nebel dichter, davor dünner. Das staffelt die Tiefe.
uniform float fog_ref_dist;

// Geschmackswerte (Welteinheiten ≈ 100 m).
const float ABOVE_FLOOR = 1.2;      // Schichtdicke über dem tiefsten Gelände
const float ABOVE_SEA = 0.55;       // Lage über dem Meer
const float LAYER_STEP = 0.35;      // Abstand der Lagen
const float THICK_FULL = 1.8;       // Luftschicht für volle Deckung (weiche Kante)
const float SEA_OPACITY = 0.35;     // über dem Meer nur ein Hauch
const float LAND_OPACITY = 0.65;
const float SMOOTH_TEXELS = 11.0;   // Abstand der Taps (±22 Zellen)

varying vec3 v_world;
varying float v_sea; // 1 über dem Meer

vec2 world_uv(vec2 xz) {
	float n = max(grid_n, 2.0);
	return ((xz / max(world_size, 1e-4) + 0.5) * (n - 1.0) + 0.5) / n;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
	           mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 uv = world_uv(w.xz);
	// 5×5-Minimum der Höhe: grob, aber das Netz ist grob und weich.
	float lo = 1e9;
	float texel = SMOOTH_TEXELS / max(grid_n, 2.0);
	for (int j = -2; j <= 2; j++) {
		for (int i = -2; i <= 2; i++) {
			vec2 q = clamp(uv + vec2(float(i), float(j)) * texel, vec2(0.0), vec2(1.0));
			lo = min(lo, max(textureLod(height_tex, q, 0.0).r * hscale, sea_y));
		}
	}
	float land = smoothstep(sea_y + 0.05, sea_y + 0.6, lo);
	v_sea = 1.0 - land;
	float base = mix(sea_y + ABOVE_SEA, lo + ABOVE_FLOOR, land);
	w.y = base + fog_layer * LAYER_STEP;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(w, 1.0)).xyz;
	v_world = w;
}

void fragment() {
	if (fog_strength <= 0.001) {
		discard;
	}
	vec2 uv = world_uv(v_world.xz);
	float ground = max(textureLod(height_tex, clamp(uv, vec2(0.0), vec2(1.0)), 0.0).r * hscale, sea_y);
	float thick = v_world.y - ground;
	float cover = smoothstep(0.0, THICK_FULL * (1.0 + fog_layer), thick);
	cover *= cover;
	if (cover <= 0.0) {
		discard;
	}
	// Schwaden: großflächig, langsam treibend; obere Lagen nur im Kern.
	vec2 p = v_world.xz * 0.12 + vec2(u_time * 0.004, u_time * 0.0025);
	float n = noise(p) * 0.65 + noise(p * 2.7 + 5.0) * 0.35;
	float wisps = smoothstep(0.32 + fog_layer * 0.2, 0.78 + fog_layer * 0.1, n);
	float opacity = mix(LAND_OPACITY, SEA_OPACITY, v_sea);
	// Nahe der Kamera aus (sonst stünde der Nebel als Fläche vor dem Bild).
	float d = length(VERTEX);
	float near = smoothstep(6.0, 22.0, d);
	near *= mix(0.35, 1.0, smoothstep(fog_ref_dist * 0.75, fog_ref_dist * 1.35, d));
	ALPHA = cover * wisps * opacity * fog_strength * near;
	ALBEDO = fog_color;
}

// Gelände-Verfeinerung im Terrain-Shader (#238). Die Fläche selbst kommt als
// `relief_tex` im Vertrag der Backtextur (TerrainAmplifier.gd, encode.glsl);
// hier stehen nur die Karten fürs Material und die Debug-Ansicht.
//
// `amplify_tex`: R Abtrag, G Ablagerung, B Abfluss, A Schutt (thermisch
// erhalten), je 0…1, mit Mip-Kette; an Wasser, Bändern und Küstensaum null.
// Strang C (#237) liest dieselbe Textur als Material-Eingang.
uniform bool amplify_enabled = false;
uniform sampler2D amplify_tex : filter_linear_mipmap_anisotropic, repeat_disable, hint_default_black;
uniform sampler2D amplify_prev_tex : filter_linear_mipmap_anisotropic, repeat_disable, hint_default_black;
// Mip-Stufe, auf der die Vertex-Stufe `relief_tex` liest: Texel der Textur je
// Vertexabstand als Zweierlogarithmus. Das Sim-Netz (ein Vertex je Zelle)
// liest die 2880²-Fläche auf Stufe 2, also ihr Zellmittel; ungefiltert
// tastete es Feinstruktur ab, die es nicht darstellen kann, und der Talboden
// würde wieder bucklig. Dichtere Kacheln (#235) lesen feinere Stufen.
uniform float amplify_vertex_lod = 0.0;
// Debug-Ansicht (RS_AMPLIFY_DEBUG): 1 Abweichung, 2 Abtrag, 3 Ablagerung,
// 4 Abfluss, 5 Schutt, 6 alle vier Karten als Farbe.
uniform int amplify_debug = 0;

// Geschmackswerte: wie stark die Karten das Material umverteilen.
const float AMPLIFY_SCREE_FROM_ROCK = 0.75;   // Schutt deckt Fels
const float AMPLIFY_SCREE_FROM_GREEN = 0.45;  // und, schwächer, Bewuchs
const float AMPLIFY_FAN_SHARE = 0.5;          // Gewicht der Ablagerung im Schutt
const float AMPLIFY_CUT_ROCK = 0.9;           // Abtrag legt auf Steilhängen Fels frei

// Karten am Pixel, im Zeitraffer vom alten zum neuen Stand geblendet. Nur im
// gleichförmigen Kontrollfluss rufen (implizite Mip-Stufe).
vec4 amplify_maps(vec2 uv, float blend) {
	if (!amplify_enabled) {
		return vec4(0.0);
	}
	vec4 cur = texture(amplify_tex, uv);
	if (blend < 1.0) {
		cur = mix(texture(amplify_prev_tex, uv), cur, blend);
	}
	return cur;
}

// Schutt am Hangfuß und in Rinnen, frischer Fels in den Einschnitten steiler
// Hänge. Nimmt nur von Fels und Bewuchs, die Gewichtssumme bleibt.
void amplify_material(vec4 maps, float steep, inout float vegetation, inout float rock,
		inout float scree) {
	float talus = clamp(maps.a + maps.g * AMPLIFY_FAN_SHARE, 0.0, 1.0);
	float from_rock = rock * talus * AMPLIFY_SCREE_FROM_ROCK;
	float from_green = vegetation * talus * AMPLIFY_SCREE_FROM_GREEN;
	rock -= from_rock;
	vegetation -= from_green;
	scree += from_rock + from_green;
	float cut = vegetation * maps.r * steep * AMPLIFY_CUT_ROCK;
	vegetation -= cut;
	rock += cut;
}

vec3 amplify_debug_color(vec4 maps, float lift_code) {
	if (amplify_debug == 1) {
		float v = (lift_code - 0.5) * 20.0;  // ±0,25 Welteinheiten bei Code 0,2
		return vec3(0.5) + vec3(v, -abs(v) * 0.5, -v);
	}
	if (amplify_debug == 2) { return vec3(maps.r); }
	if (amplify_debug == 3) { return vec3(maps.g); }
	if (amplify_debug == 4) { return vec3(maps.b); }
	if (amplify_debug == 5) { return vec3(maps.a); }
	return vec3(maps.r, maps.g + maps.a * 0.5, maps.b);
}

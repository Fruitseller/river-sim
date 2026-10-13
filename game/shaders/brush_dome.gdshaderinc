// Pinselkuppel (#174, Paket E; Lesbarkeit nach dem Abnahme-Befund „zu schwer
// zu erkennen"). Gemeinsamer Körper der beiden Pässe brush_dome.gdshader
// (sichtbarer Teil) und brush_dome_hidden.gdshader (vom Gelände verdeckter
// Teil, gedämpft). Vorher waren es 1-px-GL-Linien in blassem Cyan unter Nebel
// und Tonemapper: auf Sand, Schnee und Wolken und aus der Distanz verschwanden
// sie, und der Rand zerfiel an jeder Bodenwelle in Striche.
//
// Jedes Linienstück ist ein Band aus vier Ecken, das der Vertex-Shader in
// BILDSCHIRM-Pixeln aufspannt: die Breite hängt weder am Radius noch an der
// Kameradistanz. Innen trägt das Band die Vertex-Farbe (hell), außen einen
// dunklen Halo; so liest es sich auf hellem Grund (Sand, Schnee, Wolken) wie
// auf dunklem (Wald, Wasser, Hangschatten). Unlit und ohne Nebel.
//
// Daten je Ecke (gebaut in Main.gd, `_brush_bands`; dort stehen Breiten und
// Farben, hier nur die Darstellung des Halos):
//   VERTEX       eigener Endpunkt (relativ zur Kuppelmitte)
//   CUSTOM0.xyz  anderer Endpunkt; CUSTOM0.w ±1 dreht die Normale, damit beide
//                Enden das Band zur selben Seite aufspannen
//   UV.x         Seite quer zum Band (−1 … +1), UV.y Kernbreite in px
//   UV2.x        Halo-Breite je Seite in px
//   COLOR        Kernfarbe und Deckkraft

// Geräte-Pixel je logischem Pixel (DisplayServer.screen_get_scale, Retina 2);
// Main.gd setzt ihn, 1.0 gilt nur für die Editor-Vorschau.
uniform float px_scale = 1.0;

const vec3 HALO_COLOR = vec3(0.01, 0.02, 0.03);
// Deckkraft des Halos relativ zur Deckkraft der Linie.
const float HALO_ALPHA = 0.6;
// Unlit-Farben laufen weiter durch den AgX-Tonemapper (Lighting.gd, Belichtung
// 0.9), der Weiß zu Grau drückt; der Faktor hebt den Kern wieder ins Weiß.
const float CORE_GAIN = 1.6;
// Das Band steht im Bild flach, das Gelände steigt bei Schrägsicht zur Kamera
// hin an und schnitte die untere Bandhälfte ab. Die Ecke rückt deshalb um
// diesen Anteil ihrer halben Bandbreite (gemessen in Bildhöhen) zur Kamera;
// die Bildposition bleibt dabei exakt gleich (Skalierung im View-Raum).
const float DEPTH_PULL = 4.0;

void vertex() {
	float half_px = (0.5 * UV.y + UV2.x) * px_scale;
	float pull = 1.0 - DEPTH_PULL * half_px / VIEWPORT_SIZE.y;
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec4 clip = PROJECTION_MATRIX * vec4(view.xyz * pull, 1.0);
	vec4 other = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(CUSTOM0.xyz, 1.0));
	vec2 a = clip.xy / max(clip.w, 1e-4) * VIEWPORT_SIZE;
	vec2 b = other.xy / max(other.w, 1e-4) * VIEWPORT_SIZE;
	vec2 dir = b - a;
	dir = length(dir) > 1e-3 ? normalize(dir) : vec2(1.0, 0.0);
	vec2 side = vec2(-dir.y, dir.x) * UV.x * CUSTOM0.w;
	clip.xy += side * half_px * 2.0 / VIEWPORT_SIZE * clip.w;
	POSITION = clip;
}

void fragment() {
	float x = abs(UV.x);
	float core = 0.5 * UV.y / (0.5 * UV.y + UV2.x);
	float aa = fwidth(UV.x);
	float in_core = 1.0 - smoothstep(core - aa, core + aa, x);
	float in_band = 1.0 - smoothstep(1.0 - aa, 1.0, x);
	ALBEDO = mix(HALO_COLOR, COLOR.rgb * CORE_GAIN, in_core);
	ALPHA = mix(HALO_ALPHA, 1.0, in_core) * COLOR.a * in_band * PASS_ALPHA;
}

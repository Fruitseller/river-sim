shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Räumliche Glättung des Raster-Wasserfelds — GPU-Fassung von `blurMax` in
// WaterFieldRenderer (SimRender). Der Rest jenes Passes bleibt auf der CPU: er
// besteht in der Mitte aus zwei SEQUENZIELLEN Graph-Algorithmen (Kontinuitäts-
// Kette entlang der D8-Empfänger, Flood-Fill der Wasser-Komponenten), die in
// kein Pixel-Programm passen.
//
// max(Kern, Blur) statt reinem Blur — dieselbe Regel wie auf der CPU: die
// Kern-Intensität bleibt voll (sonst verblassen dünne Läufe in der Übersicht),
// nur die Ränder bekommen den weichen Saum, den terrain.gdshader smoothstept.
//
// KEINE Kalibrier-Zahlen hier: alle Schwellen des Wasserfelds stehen weiterhin
// im getesteten Vertrag SimCore.WaterRender und wirken CPU-seitig, bevor dieses
// Feld entsteht. Dieser Shader ist reine Glättung.
//
// texelFetch statt texture(): der 3×3-Kern muss GENAU die Nachbarzellen mitteln,
// die auch die CPU-Fassung mittelt — mit bilinearer Filterung und UV-Rundung
// wäre der Kern an den Zellgrenzen ein anderer. Randzellen zählen nur ihre
// vorhandenen Nachbarn (4 bzw. 6 statt 9), ebenfalls wie auf der CPU; ein
// geklemmter Rand-Sample würde die Kantenzelle doppelt wiegen.
uniform sampler2D src : filter_nearest, repeat_disable;
// Welche Kanäle dieser Pass glättet: R = Fluss-Intensität, G = See-Gate.
// Die Fließrichtung (BA) wird NIE geglättet — sie ist eine Richtung, kein
// Deckungsgrad; ihre zeitliche Glättung macht der EWMA-Pass.
// Der See-Kanal braucht zwei Durchläufe (er muss den seichten Ufersaum unter
// der rawWet-Schwelle überdecken), der Fluss-Kanal einen — also läuft dieselbe
// Datei zweimal mit verschiedener Maske, statt zwei fast gleiche Shader zu haben.
uniform vec2 blur_channels = vec2(1.0, 1.0);

void fragment() {
	ivec2 size = textureSize(src, 0);
	ivec2 p = ivec2(FRAGCOORD.xy);
	vec4 c = texelFetch(src, p, 0);
	vec4 sum = vec4(0.0);
	float count = 0.0;
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			ivec2 q = p + ivec2(dx, dy);
			if (q.x < 0 || q.y < 0 || q.x >= size.x || q.y >= size.y) {
				continue;
			}
			sum += texelFetch(src, q, 0);
			count += 1.0;
		}
	}
	vec4 blurred = sum / count;
	COLOR = vec4(
		mix(c.r, max(c.r, blurred.r), blur_channels.x),
		mix(c.g, max(c.g, blurred.g), blur_channels.y),
		c.b, c.a);
}

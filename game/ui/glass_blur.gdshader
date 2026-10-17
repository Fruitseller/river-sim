// Weichzeichner-Hintergrund der Glas-Panels (Issue #174, Paket E; Vorlagen
// B/C: „halbtransparent, abgerundet, Weichzeichner-Hintergrund").
//
// Material eines ColorRect, das Main.gd (`_panel`) HINTER jedes Glas-Panel
// legt. Das Panel selbst (Tönung, Rand, Schatten, Rundung) zeichnet das Theme
// darüber (game/ui/glass_theme.tres); hier steht nur, was ein StyleBox nicht
// kann: den Bildschirm hinter dem Panel verwischen. Damit bleibt die Form EINE
// Quelle: Eckenradius und Weichzeichner-Radius kommen aus dem Theme und
// reisen als Uniforms hierher (Main.gd `_glass_material`); die Uniforms sind
// bewusst default-frei, ein Literal-Default wäre wieder eine Kopie.
//
// Kosten: `hint_screen_texture` mit Mip-Filter lässt Godot EINMAL je Bild den
// Bildschirm kopieren und dessen Mip-Kette bauen (unabhängig von der Zahl der
// Panels); der eigene Fragment-Aufwand sind neun Abfragen nur auf den
// Panel-Flächen. Messung: docs/zielbild-measurements.md § Glas-Weichzeichner.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;
// Weichzeichner-Radius in Pixeln (Theme: GlassBackdrop/blur_radius).
uniform float blur_px;
// Eckenradius in Pixeln (Theme: Glas-Panel `PanelContainer/styles/panel`).
uniform float corner_px;
// Abdunklung des verwischten Hintergrunds, je Kanal multipliziert (Theme:
// GlassBackdrop/dim). Ohne sie wird Glas über Schnee mittelgrau, und die
// gedämpfte Schrift (Abschnitt, Tempo) verliert den Kontrast.
uniform vec4 dim;

void fragment() {
	// Größe des (achsenparallelen) Rechtecks in Pixeln aus der UV-Steigung:
	// das ColorRect trägt keine Größe als Uniform, sie wäre je Panel eine
	// weitere Kopie, die beim Umbruch der Spalte veralten könnte.
	vec2 size = 1.0 / max(fwidth(UV), vec2(1e-6));
	vec2 half_size = 0.5 * size;
	float radius = min(corner_px, min(half_size.x, half_size.y));
	vec2 q = abs((UV - 0.5) * size) - (half_size - radius);
	float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
	float inside = clamp(0.5 - dist, 0.0, 1.0);

	// Mip-Texel der Stufe L decken 2^L Pixel; ein Mip-Texel hat die Kantenlänge
	// des halben Weichzeichner-Radius. Ein Ring aus acht Abfragen im selben
	// Abstand glättet die Rautenmuster, die eine einzelne bilineare Abfrage in
	// hohen Stufen zeigt.
	float lod = log2(max(blur_px, 1.0)) - 1.0;
	vec2 ring = 0.5 * blur_px * SCREEN_PIXEL_SIZE;
	vec3 sum = textureLod(screen_tex, SCREEN_UV, lod).rgb;
	for (int i = 0; i < 8; i++) {
		float a = float(i) * 0.78539816;
		sum += textureLod(screen_tex, SCREEN_UV + vec2(cos(a), sin(a)) * ring, lod).rgb;
	}
	COLOR = vec4(sum / 9.0 * dim.rgb, inside);
}

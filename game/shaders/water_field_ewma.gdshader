shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Zeitliche Glättung des Raster-Wasserfelds — GPU-Fassung der EWMA aus
// WaterFieldRenderer. Ohne sie wird das Feld je Tick frisch aus der Drainage
// gebaut und die Läufe SPRINGEN zwischen den diskreten D8-Netzen; mit ihr
// blenden sie über ~2 s in die neue Lage.
//
// Ping-Pong: `state` ist das Ergebnis des VORIGEN Ticks (das andere der zwei
// Zustands-Viewports), geschrieben wird in dieses. Ein Target zu lesen und zu
// beschreiben ist undefiniert, deshalb zwei.
//
// FRAMERATE-UNABHÄNGIG bleibt das nur, weil Main.gd die Viewports mit
// UPDATE_ONCE genau EINMAL pro Textur-Update taktet — nicht pro Frame. Ein auf
// UPDATE_ALWAYS gestellter Viewport würde die Glättungsrate an die Bildrate
// koppeln und damit die Regel aus AGENTS.md brechen.
uniform sampler2D fresh : filter_nearest, repeat_disable;
uniform sampler2D state : filter_nearest, repeat_disable;
// 1.0 = frischen Wert sofort übernehmen (Sprung, Sculpting, erster Frame),
// klein = weiches Blenden im Zeitraffer. Gleiche Bedeutung wie das `blend`-
// Argument der CPU-Fassung.
uniform float blend : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	ivec2 p = ivec2(FRAGCOORD.xy);
	vec4 f = texelFetch(fresh, p, 0);
	vec4 s = texelFetch(state, p, 0);
	// Alle vier Kanäle im KODIERTEN Raum mischen. Für R/G ist das der Wert
	// selbst; die Richtung (BA) liegt als *0.5+0.5 vor, und weil diese Kodierung
	// affin ist, ist „mischen und kodieren" dasselbe wie „kodieren und mischen".
	COLOR = s + blend * (f - s);
}

// Bett des Fluss-Korridors unter Wasser, aktueller Band-Stand (Gremium,
// Befund 2): OHNE Tiefe. Das Band liegt immer darüber; schrieb das Bett
// Deckel-Tiefe, gewann es den Tiefentest gegen das Wasser überall dort, wo
// die Deckel von Band und Korridor nur um Millimeter auseinanderlagen
// (Kaskaden, Zwischen-Stützpunkte) — Querstreifen ohne Wasser. Gegen das
// Gelände testet das Bett weiter mit der Deckel-Tiefe.
shader_type spatial;
render_mode cull_disabled, depth_draw_never;

#define CORRIDOR_WET
#include "res://shaders/corridor.gdshaderinc"

// Ufer des Fluss-Korridors, aktueller Band-Stand (Look E, #239): nur der
// TROCKENE Teil, mit Tiefe (Deckel-Tiefe, s. corridor_common.gdshaderinc),
// damit die Wasserfläche danach gegen das Ufer getestet wird. Das Bett unter
// Wasser zeichnet corridor_wet.gdshader ohne Tiefe.
shader_type spatial;
render_mode cull_disabled, depth_draw_always;

#define CORRIDOR_DRY
#include "res://shaders/corridor.gdshaderinc"

// Ufer und Bett des Fluss-Korridors, aktueller Band-Stand (Look E, #239).
// Schreibt Tiefe (Deckel-Tiefe, s. corridor_common.gdshaderinc), damit die
// Wasserfläche danach gegen Ufer und Bett getestet wird.
shader_type spatial;
render_mode cull_disabled, depth_draw_always;

#include "res://shaders/corridor.gdshaderinc"

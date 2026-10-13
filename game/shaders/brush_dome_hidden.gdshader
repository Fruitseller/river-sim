// Pinselkuppel, vom Gelände verdeckter Teil: ohne Tiefentest und gedämpft.
// Läuft VOR dem sichtbaren Pass (Main.gd hängt den als `next_pass` an), der
// ihn überall deckt, wo die Kuppel frei liegt; hinter einem Kamm, unter dem
// Meer oder wo eine Bodenwelle den Rand schneidet, bleibt sie so als Schemen
// lesbar. Körper und Begründung: brush_dome.gdshaderinc.
shader_type spatial;
render_mode unshaded, fog_disabled, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled;

#define PASS_ALPHA 0.35
#include "res://shaders/brush_dome.gdshaderinc"

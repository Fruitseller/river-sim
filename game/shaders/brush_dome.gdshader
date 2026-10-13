// Pinselkuppel, sichtbarer Teil (mit Tiefentest). Körper und Begründung:
// brush_dome.gdshaderinc.
shader_type spatial;
render_mode unshaded, fog_disabled, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

#define PASS_ALPHA 1.0
#include "res://shaders/brush_dome.gdshaderinc"

shader_type spatial;
render_mode unshaded, fog_disabled, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled;

#define PASS_ALPHA 0.35
#include "res://shaders/brush_dome.gdshaderinc"

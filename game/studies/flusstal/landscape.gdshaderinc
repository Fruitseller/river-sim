uniform int study_debug = 0;
uniform sampler2D protect_tex : filter_linear, repeat_disable;

#include "res://shaders/protect.gdshaderinc"

void study_debug_view(vec2 uv, float forest, inout vec3 color) {
	if (study_debug == 1) {
		color = mix(color, vec3(0.9, 0.1, 0.1), protect_at(uv));
	} else if (study_debug == 2) {
		color = mix(color, vec3(0.9, 0.1, 0.9), forest);
	} else if (study_debug == 3) {
		color = vec3(0.5 + relief_cavity(relief_pixel(uv)) * 0.5);
	}
}

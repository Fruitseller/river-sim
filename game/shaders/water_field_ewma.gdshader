shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D fresh : filter_nearest, repeat_disable;
uniform sampler2D state : filter_nearest, repeat_disable;
uniform float blend : hint_range(0.0, 1.0);

void fragment() {
	ivec2 p = ivec2(FRAGCOORD.xy);
	vec4 f = texelFetch(fresh, p, 0);
	vec4 s = texelFetch(state, p, 0);
	COLOR = s + blend * (f - s);
}

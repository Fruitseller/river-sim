shader_type spatial;
render_mode cull_back, depth_draw_opaque, ensure_correct_normals;

varying vec3 v_tint;
varying float v_shade;
varying float v_crown;

void vertex() {
	float con = INSTANCE_CUSTOM.x;
	VERTEX = mix(CUSTOM0.xyz, VERTEX, con);
	NORMAL = normalize(mix(CUSTOM1.xyz, NORMAL, con));
	v_tint = INSTANCE_CUSTOM.yzw;
	v_shade = COLOR.r;
	v_crown = COLOR.g;
}

void fragment() {
	vec3 bark = vec3(0.10, 0.075, 0.05);
	vec3 leaf = v_tint * mix(0.55, 1.15, v_shade);
	ALBEDO = mix(bark, leaf, v_crown);
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
	BACKLIGHT = v_tint * 0.35 * v_crown;
}

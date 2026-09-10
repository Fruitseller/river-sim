shader_type spatial;
#include "res://studies/flusstal/materials.gdshaderinc"
varying vec3 world_position;
varying vec3 world_normal;
void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
	vec3 n = normalize(world_normal);
	vec3 c = vec3(0.5);
	float r = 0.9;
	study_material(world_position, 0.0, c, n, r);
	ALBEDO = c;
	NORMAL = normalize(mat3(VIEW_MATRIX) * n);
	ROUGHNESS = r;
}

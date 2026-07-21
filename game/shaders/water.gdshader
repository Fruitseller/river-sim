// Animiertes Flusswasser — portiert aus dem Web-Prototyp (Three.js ShaderMaterial).
// Fließrichtung kommt per Vertex-COLOR.rg (kodiert als dir*0.5+0.5); Seen haben
// dir = (0,0) → sie kräuseln nur. Wellenbänder wandern stromabwärts, seltene
// Glitzerpunkte blitzen hash-basiert auf.
shader_type spatial;
render_mode cull_disabled, unshaded, depth_draw_never;

uniform float u_time = 0.0;

varying vec2 v_dir;
varying vec3 v_world;

void vertex() {
	// COLOR.rg trägt die (dekodierte) Fließrichtung, COLOR.b als Fluss/See-Flag.
	v_dir = COLOR.rg * 2.0 - 1.0;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec3 col = vec3(0.14, 0.44, 0.77);
	float dl = length(v_dir);
	if (dl > 0.01) {
		float along = dot(v_world.xz, v_dir / dl);
		float stream = 0.5 * sin(along * 2.0 - u_time * 6.0)
			+ 0.5 * sin(along * 4.7 - u_time * 9.0 + 1.7);
		col += stream * vec3(0.06, 0.09, 0.12);
	} else {
		float ripple = sin(v_world.x * 2.1 + u_time * 1.2) * sin(v_world.z * 2.4 + u_time * 0.9);
		col += ripple * vec3(0.04, 0.05, 0.06);
	}
	vec2 cell = floor(v_world.xz * 5.0);
	float r = hash(cell);
	float tw = 0.5 + 0.5 * sin(u_time * (1.5 + r * 4.0) + r * 62.831);
	col += pow(tw, 120.0) * step(0.82, r) * 0.5 * vec3(1.0, 1.0, 0.95);
	ALBEDO = col;
	ALPHA = 0.9;
}

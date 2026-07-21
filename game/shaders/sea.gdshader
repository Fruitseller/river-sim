// Offenes Meer — PBR-Wasser, das den prozeduralen Himmel spiegelt.
// Kräuselung über prozedurale Normalen (zwei wandernde Wellenzüge), Fresnel
// erhöht Reflexion + Deckkraft an flachen Blickwinkeln. Keine Vertex-Verschiebung
// (die Platte bleibt plan), damit nichts durchs Terrain stößt.
shader_type spatial;
render_mode cull_disabled;

uniform float u_time = 0.0;
uniform vec3 shallow_col : source_color = vec3(0.18, 0.46, 0.56);
uniform vec3 deep_col : source_color = vec3(0.03, 0.10, 0.26);

varying vec3 world_pos;

float wave(vec2 p, float t) {
	return sin(dot(p, vec2(0.21, 0.13)) + t * 1.1)
		+ 0.6 * sin(dot(p, vec2(-0.11, 0.27)) - t * 1.4);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_pos.xz;
	float e = 0.7;
	float h0 = wave(p, u_time);
	float hx = wave(p + vec2(e, 0.0), u_time);
	float hz = wave(p + vec2(0.0, e), u_time);
	vec3 nrm = normalize(vec3(-(hx - h0) * 0.4, 1.0, -(hz - h0) * 0.4));
	NORMAL = (VIEW_MATRIX * vec4(nrm, 0.0)).xyz;

	float ndv = clamp(dot(normalize(VIEW), NORMAL), 0.0, 1.0);
	float fres = pow(1.0 - ndv, 4.0);
	ALBEDO = mix(deep_col, shallow_col, 0.35);
	METALLIC = 0.0;
	ROUGHNESS = mix(0.08, 0.02, fres); // glatter → stärkere Himmelsspiegelung
	SPECULAR = 0.7;
	ALPHA = mix(0.82, 0.97, fres);
}

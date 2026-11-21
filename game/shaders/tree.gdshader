// Einzelbäume (#236). WO ein Baum steht, wie groß und welcher Art er ist,
// schreibt der Compute-Pass `tree_place.glsl` jedes Bild in die Instanzdaten
// (Transform mit Standort, Drehung und Größe; INSTANCE_CUSTOM = Nadelbaum-
// Anteil und Laubfarbe). Hier nur die Form: das Mesh trägt Nadelbaum
// (VERTEX/NORMAL) und Laubbaum (CUSTOM0/CUSTOM1) mit derselben Topologie
// (TreeMesh.gd), gemischt nach dem Anteil.
shader_type spatial;
// Die Instanz skaliert ungleichmäßig (schlanke Nadelbäume): Normalen über
// die inverse Transponierte.
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
	// Laub lässt Licht durch: Gegenlicht leuchtet die Kronenränder grün an.
	BACKLIGHT = v_tint * 0.35 * v_crown;
}

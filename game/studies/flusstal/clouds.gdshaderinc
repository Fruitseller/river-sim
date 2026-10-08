// Wolkenschatten der Flusstal-Studie (#116). Gemeinsam für Terrain, Ozean und
// Flussbänder, damit ein Schatten über Land und Wasser ohne Kante weiterläuft.
// Rein visuell: wirkt als Albedo-Faktor (dunkelt damit auch das Umgebungslicht
// leicht mit ab) — ein eigenes light() für alle drei Shader wäre teurer und
// müsste Godots Beleuchtung nachbauen.
uniform bool study_clouds = false;
uniform float study_cloud_strength = 0.24;

float study_cloud_hash(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	p += dot(p, p + 19.19);
	return fract(p.x * p.y);
}

float study_cloud_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(study_cloud_hash(i), study_cloud_hash(i + vec2(1.0, 0.0)), u.x),
	           mix(study_cloud_hash(i + vec2(0.0, 1.0)), study_cloud_hash(i + vec2(1.0)), u.x), u.y);
}

// Faktor für ALBEDO: 1 = Sonne, 1 − strength = im Wolkenschatten.
// world_xz in Welteinheiten (≈ 100 m), Zellgröße der Wolken ~3–4 km.
float study_cloud_light(vec2 world_xz, float t) {
	if (!study_clouds) {
		return 1.0;
	}
	vec2 q = world_xz * 0.028 + vec2(t * 0.010, t * 0.004);
	float c = study_cloud_noise(q) * 0.55 + study_cloud_noise(q * 2.1 + 7.3) * 0.3
	        + study_cloud_noise(q * 4.7 + 3.1) * 0.15;
	return 1.0 - smoothstep(0.56, 0.70, c) * study_cloud_strength;
}

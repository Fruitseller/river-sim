// Wolkenschatten (Issue #151, aus der Flusstal-Studie #116 übernommen).
// Gemeinsam für Terrain, Ozean und Flussbänder, damit ein Schatten über Land
// und Wasser ohne Kante weiterläuft. Rein visuell: wirkt als Albedo-Faktor
// (dunkelt damit auch das Umgebungslicht leicht mit ab) — ein eigenes light()
// für alle drei Shader wäre teurer und müsste Godots Beleuchtung nachbauen.
//
// Die Uniforms sind bewusst default-frei: Werte und Qualitätsstufe setzt
// ausschließlich game/scripts/Lighting.gd (Wächter: game/tests/lighting.gd).
uniform bool clouds_enabled;
uniform float cloud_strength;
uniform float cloud_scale;

float cloud_hash(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	p += dot(p, p + 19.19);
	return fract(p.x * p.y);
}

float cloud_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(cloud_hash(i), cloud_hash(i + vec2(1.0, 0.0)), u.x),
	           mix(cloud_hash(i + vec2(0.0, 1.0)), cloud_hash(i + vec2(1.0)), u.x), u.y);
}

// Faktor für ALBEDO: 1 = Sonne, 1 − cloud_strength = im Wolkenschatten.
// world_xz in Welteinheiten (≈ 100 m); cloud_scale legt die Zellgröße fest.
// Alle drei Shader übergeben dieselben Weltkoordinaten (Ursprung Weltmitte),
// sonst bekäme der Schatten an der Uferlinie eine Kante.
float cloud_light(vec2 world_xz, float t) {
	if (!clouds_enabled) {
		return 1.0;
	}
	vec2 q = world_xz * cloud_scale + vec2(t * 0.010, t * 0.004);
	float c = cloud_noise(q) * 0.55 + cloud_noise(q * 2.1 + 7.3) * 0.3
	        + cloud_noise(q * 4.7 + 3.1) * 0.15;
	return 1.0 - smoothstep(0.56, 0.70, c) * cloud_strength;
}

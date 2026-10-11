// Wolkenschatten (Issue #151, aus der Flusstal-Studie #116 übernommen) und
// die gemeinsame Rauschquelle der Wolkenkörper (#174 D, cloud_body.gdshader).
// Gemeinsam für Terrain, Ozean, Flussbänder und Wolkenkörper, damit ein
// Schatten über Land und Wasser ohne Kante weiterläuft und genau unter seiner
// Wolke liegt. Rein visuell: wirkt als Albedo-Faktor (dunkelt damit auch das
// Umgebungslicht leicht mit ab) — ein eigenes light() für alle drei Shader wäre
// teurer und müsste Godots Beleuchtung nachbauen.
//
// Die Uniforms sind bewusst default-frei: Werte und Qualitätsstufe setzt
// ausschließlich game/scripts/Lighting.gd (Wächter: game/tests/lighting.gd).
uniform bool clouds_enabled;
uniform float cloud_strength;
uniform float cloud_scale;
// Wolkenschicht (#174 D): Welt-Y der Wolkenbasis und Versatz je Höheneinheit
// zur Sonne hin (xz/y des Einheitsvektors zur Sonne). Der Schatten eines
// Punkts kommt von der Wolke, die auf dem Strahl zur Sonne in Basishöhe
// liegt; so fällt er dorthin, wo die Sonne ihn hinwirft, und deckt sich mit
// dem Wolkenkörper.
uniform float cloud_height;
uniform vec2 cloud_sun_shift;

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

// Wolkendichte (Rauschsumme, ≈ 0 … 1) in Basishöhe an `world_xz` (Weltmitte
// als Ursprung, Welteinheiten ≈ 100 m); cloud_scale legt die Zellgröße fest.
float cloud_density(vec2 world_xz, float t) {
	vec2 q = world_xz * cloud_scale + vec2(t * 0.010, t * 0.004);
	return cloud_noise(q) * 0.55 + cloud_noise(q * 2.1 + 7.3) * 0.3
	     + cloud_noise(q * 4.7 + 3.1) * 0.15;
}

// Deckung 0 … 1: dieselbe Schwelle für Schatten und Wolkenkörper.
float cloud_cover(vec2 world_xz, float t) {
	return smoothstep(0.56, 0.70, cloud_density(world_xz, t));
}

// Faktor für ALBEDO: 1 = Sonne, 1 − cloud_strength = im Wolkenschatten.
// `world_pos` in Weltkoordinaten; alle Shader übergeben dieselben (Ursprung
// Weltmitte), sonst bekäme der Schatten an der Uferlinie eine Kante. Was über
// der Wolkenbasis liegt, steht in der Sonne.
float cloud_light(vec3 world_pos, float t) {
	if (!clouds_enabled || world_pos.y >= cloud_height) {
		return 1.0;
	}
	vec2 at = world_pos.xz + cloud_sun_shift * (cloud_height - world_pos.y);
	return 1.0 - cloud_cover(at, t) * cloud_strength;
}

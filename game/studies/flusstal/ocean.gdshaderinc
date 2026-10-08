// Offenes Meer der Flusstal-Studie (#116). Eingebunden nach clouds.gdshaderinc
// (nutzt dessen Noise) und nur im FLUSSTAL_STUDY-Build.
//
// Der Produktions-Ozean baut seine Normalen aus drei Sinuswellen und legt einen
// Sinus-Schimmer darüber. Aus der Übersicht wird daraus ein regelmäßiges
// Streifenmuster bis zum Horizont, das die Insel als Modell auf einem Tisch
// lesen lässt. Hier: Rausch-Wellen, die mit ihrer Pixelgröße ausblenden, und
// Farbe aus der echten Wassertiefe über dem Sim-Schelf mit Brandungssaum.
uniform bool study_ocean = false;

vec2 study_ocean_grad(vec2 p, float t) {
	float footprint = length(fwidth(p));
	vec2 g = vec2(0.0);
	float freq = 0.55;
	float amp = 0.045;
	for (int o = 0; o < 4; o++) {
		vec2 q = p * freq + vec2(t * 0.21, t * 0.13) * (1.0 + float(o) * 0.35)
		       + vec2(float(o) * 13.7, float(o) * 7.1);
		float e = 0.08;
		float n0 = study_cloud_noise(q);
		vec2 d = vec2(study_cloud_noise(q + vec2(e, 0.0)) - n0,
		              study_cloud_noise(q + vec2(0.0, e)) - n0) / e;
		g += d * amp * (1.0 - smoothstep(0.2, 0.8, footprint * freq));
		freq *= 2.3;
		amp *= 0.7;
	}
	return g;
}

vec3 study_ocean_color(vec2 p, float h, float fresnel, bool inside, float t) {
	// Tiefe in Sim-Höheneinheiten; 0.06 ≈ 1,4 Welteinheiten ≈ 140 m.
	float depth = inside ? clamp((sea_level - h) / 0.06, 0.0, 1.0) : 1.0;
	vec3 shallow = vec3(0.09, 0.27, 0.27);
	vec3 mid = vec3(0.030, 0.125, 0.165);
	vec3 deep = vec3(0.012, 0.050, 0.082);
	vec3 col = mix(shallow, mid, smoothstep(0.0, 0.25, depth));
	col = mix(col, deep, smoothstep(0.25, 1.0, depth));
	col = mix(col, water_sky_reflect_color, fresnel * water_fresnel_sky_mix);
	// Brandung: schmaler, gebrochener Saum direkt an der Küste.
	float surf = 1.0 - smoothstep(0.0, 0.045, depth);
	surf *= smoothstep(0.35, 0.75, study_cloud_noise(p * 3.1 + vec2(t * 0.6, 0.0)));
	return mix(col, vec3(0.80, 0.85, 0.86), surf * (inside ? 0.55 : 0.0));
}

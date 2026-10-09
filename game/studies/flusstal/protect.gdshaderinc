// Schutzmaske der Flusstal-Studie (#116/#154): Rasterwasser plus gebaute
// Bänder plus Saum, berechnet in SimRender (R8, Mip-Kette nativ). Verschiebung und
// Kronendach enden hier, damit Bänder und Seeufer auf der Sim-Höhe bleiben.
// Erwartet `study_protect_tex` (filter_linear_mipmap) beim Einbinder.
float study_protect(vec2 uv) {
	// Stufe 0: die Maske (Wasser + Bänder + Saum, binär, aus SimRender); Stufe
	// 1,5 weicht deren Kante auf. Der Mip-Halo (~2–3 Zellen) kommt zum
	// Masken-Saum (`WaterRender.protectSeamCells`) DAZU: wirksam ~4–5 Zellen.
	vec4 a = textureLod(study_protect_tex, uv, 0.0);
	vec4 b = textureLod(study_protect_tex, uv, 1.5);
	float near = smoothstep(0.12, 0.30, max(a.r, a.g));
	float halo = smoothstep(0.10, 0.28, max(b.r, b.g));
	return max(near, halo);
}

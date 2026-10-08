// Schutzmaske der Flusstal-Studie (#116): Rasterwasser plus jedes gebaute
// Band-Dreieck (Flusstal.gd, Mip-Kette nativ erzeugt). Verschiebung und
// Kronendach enden hier, damit Bänder und Seeufer auf der Sim-Höhe bleiben.
// Erwartet `study_protect_tex` (filter_linear_mipmap) beim Einbinder.
float study_protect(vec2 uv) {
	// Stufe 0: das Wasser selbst; Stufe 1,5 (~3 Zellen Mittel): ein Saum von
	// etwa zwei Zellen, damit Ufer nicht über ein Band wachsen. Schwache
	// Abflusswerte (unterhalb der Sichtbarkeit) sperren nichts.
	vec4 a = textureLod(study_protect_tex, uv, 0.0);
	vec4 b = textureLod(study_protect_tex, uv, 1.5);
	float near = smoothstep(0.12, 0.30, max(a.r, a.g));
	float halo = smoothstep(0.10, 0.28, max(b.r, b.g));
	return max(near, halo);
}

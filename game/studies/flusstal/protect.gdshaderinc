// Schutzmaske der Flusstal-Studie (#116/#154): Rasterwasser plus gebaute
// Bänder plus Saum, binär berechnet in SimRender (R8). Verschiebung und
// Kronendach enden hier, damit Bänder und Seeufer auf der Sim-Höhe bleiben.
// Erwartet `study_protect_tex` (Linearfilter) beim Einbinder.
float study_protect(vec2 uv) {
	// Der Saum steckt vollständig in der Maske (`WaterRender.protectSeamCells`);
	// hier kommt KEIN zweiter dazu. Die lineare Filterung weicht nur die Kante
	// über eine Zelle auf, statt Verschiebung und Kronendach hart abzuschneiden.
	return textureLod(study_protect_tex, uv, 0.0).r;
}

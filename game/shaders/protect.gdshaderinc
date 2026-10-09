// Schutzmaske (#154): Rasterwasser plus gebaute Bänder plus Saum, binär
// berechnet in SimRender (R8). Render-Verschiebung (#153) und das Kronendach
// der Studie enden hier, damit Bänder und Seeufer auf der Sim-Höhe bleiben.
// Erwartet `protect_tex` (Linearfilter) beim Einbinder.
float protect_at(vec2 uv) {
	// Der Saum steckt vollständig in der Maske (`WaterRender.protectSeamCells`);
	// hier kommt KEIN zweiter dazu. Die lineare Filterung weicht nur die Kante
	// über eine Zelle auf, statt Verschiebung und Kronendach hart abzuschneiden.
	return textureLod(protect_tex, uv, 0.0).r;
}

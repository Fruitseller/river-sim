// Schutzmaske (#154): Rasterwasser plus gebaute Bänder plus Saum, binär
// berechnet in SimRender (R8). Die Render-Verschiebung (#153) endet hier,
// damit Bänder und Seeufer auf der Sim-Höhe bleiben; das Kronendach (#152)
// liest die Maske schon CPU-seitig (SimRender.ForestCanopyMask).
// Erwartet `protect_tex` (Linearfilter) beim Einbinder.
float protect_at(vec2 uv) {
	// Der Saum steckt vollständig in der Maske (`WaterRender.protectSeamCells`);
	// hier kommt KEIN zweiter dazu. Die lineare Filterung weicht nur die Kante
	// über eine Zelle auf, statt die Verschiebung hart abzuschneiden.
	return textureLod(protect_tex, uv, 0.0).r;
}

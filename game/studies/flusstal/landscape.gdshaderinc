// Landschaftsschichten der Flusstal-Studie (#116), zweite Runde.
// Eingebunden NACH den Uniforms und Noise-Helfern von terrain.gdshader und nur
// im FLUSSTAL_STUDY-Build. Alles rein visuell, die Sim-Felder bleiben unberührt.
//
// Alle Hebel der zweiten Runde sind Produktion: `geometry` (grobe Rinnen und
// geschärfte Grate als echte Verschiebung) seit #153 (terrain.gdshader,
// relief_bake.gdshader), `canopy` (Kronendach statt Instanzbäumen) seit #152
// (terrain.gdshader, Waldmaske aus SimRender.ForestCanopyMask). Geblieben sind
// die Debug-Ansichten der Kalibrierung.

uniform int study_debug = 0; // 1 = Schutzmaske, 2 = Waldmaske, 3 = Rinnen/Rippen
// Schutzmaske (#154) nur für die Debug-Ansicht; Flusstal.gd bindet sie.
uniform sampler2D protect_tex : filter_linear, repeat_disable;

#include "res://shaders/protect.gdshaderinc"

void study_debug_view(vec2 uv, float forest, inout vec3 color) {
	if (study_debug == 1) {
		color = mix(color, vec3(0.9, 0.1, 0.1), protect_at(uv));
	} else if (study_debug == 2) {
		color = mix(color, vec3(0.9, 0.1, 0.9), forest);
	} else if (study_debug == 3) {
		color = vec3(0.5 + relief_cavity(uv) * 0.5);
	}
}

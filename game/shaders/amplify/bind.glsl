// Bindung an die Sim (#238): aus dem verfeinerten Zustand wird die
// Abweichung von der bilinearen Sim-Fläche, und zwar
//  - ohne das Mittel (Korrekturfeld aus mean_solve.glsl, bilinear),
//  - in fester Schranke (weich gedeckelt),
//  - null an Wasser, Flussbändern und ihrem Saum (Schutzmaske #154) und am
//    Küstensaum (mask.glsl): die Küstenlinie bleibt, Bänder werden nicht
//    verschüttet,
//  - wo Wasser steht, nie über dem Wasserspiegel.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_height;
layout(set = 0, binding = 1) uniform sampler2D sim_height;  // linear
layout(set = 0, binding = 2) uniform sampler2D sim_filled;  // linear
layout(set = 0, binding = 3) uniform sampler2D cell_mask;   // linear, aus mask.glsl
layout(set = 0, binding = 4) uniform sampler2D cell_mean;   // linear
layout(set = 0, binding = 5, rg16f) uniform writeonly image2D dst_offset;  // r Abweichung, g Maske
layout(set = 0, binding = 6) uniform sampler2D src_flux;    // a Gefälle der Sim-Fläche
layout(push_constant, std430) uniform Params {
	vec4 size;    // xy Größe, z Überhöhung, w Meeresspiegel (Sim-Höhe)
	vec4 bound;   // x Schranke nach unten, y nach oben (Welteinheiten), z Stärke,
	              // w Tümpeltiefe (Sim-Höhe)
	vec4 steep;   // x Stärke an Steilwänden, yz Gefälle von … bis, w Wellenlänge der
	              // Gebiete in Sim-Zellen
	vec4 region;  // x Stärke in den ruhigen Gebieten (Anteil), y Sim-Gitter n
} pc;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(pc.size.xy);
	if (p.x >= size.x || p.y >= size.y) {
		return;
	}
	vec2 uv = (vec2(p) + 0.5) / vec2(size);
	float hs = textureLod(sim_height, uv, 0.0).r;
	float off = texelFetch(src_height, p, 0).r - hs * pc.size.z;
	// Erst das Mittel abziehen, dann die Schranke. Umgekehrt (zuerst gebaut)
	// lag die rohe Abweichung am Steilhang schon weit in der Sättigung: der
	// Abtrag senkt dort alles gleichmäßig um 30 bis 60 m, und die weiche
	// Schranke drückte die Rinnen darauf platt, die Felswände blieben glatt.
	off = shaped(off - textureLod(cell_mean, uv, 0.0).r, texelFetch(src_flux, p, 0).a,
		pc.bound, pc.steep);
	// Nicht jeder Hang gleich zerfurcht: ein grobes Rauschen aus der Position
	// (Wellenlänge `steep.w` Zellen) lässt die Form gebietsweise bis auf
	// `region.x` zurücktreten. Überall gleich stark las das Gelände in der
	// Totalen als gekämmt.
	vec2 cell = (vec2(p) + 0.5) / (pc.size.x / pc.region.y) - 0.5;
	float patch_noise = vnoise(cell / pc.steep.w + 31.7) * 0.65 + vnoise(cell / pc.steep.w * 2.3 + 5.2) * 0.35;
	off *= mix(pc.region.x, 1.0, smoothstep(0.35, 0.65, patch_noise));
	// Schutzmaske und Küstensaum halten die Sim-Höhe (mask.glsl).
	// Der Küstensaum zusätzlich je Texel: unter ihm ist die Abweichung exakt
	// null, die Küstenlinie bleibt, wo die Sim sie hat.
	float sea = pc.size.w;
	float w = textureLod(cell_mask, uv, 0.0).r * smoothstep(sea + 0.008, sea + 0.04, hs);
	off *= w;
	// Steht Wasser in der Zelle, hebt die Verfeinerung sie nie über den
	// Spiegel. „Wasser“ ab der Tiefe, ab der der Terrain-Shader einen Tümpel
	// zeigt (`bound.w`, WaterRender.pondContourLo); die gefüllte Fläche der
	// Sim liegt fast überall um Zentimeter über dem Gelände, eine harte
	// Schwelle bei null verböte das Anheben auf zwei Dritteln des Landes.
	float depth = textureLod(sim_filled, uv, 0.0).r - hs;
	if (off > 0.0) {
		off *= 1.0 - smoothstep(pc.bound.w * 0.5, pc.bound.w, depth);
	}
	imageStore(dst_offset, p, vec4(off, w, 0.0, 0.0));
}

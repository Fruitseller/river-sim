// Back-Pass der Render-Verschiebung von Rinnen und Graten (#153, aus der
// Flusstal-Studie #116 übernommen). Läuft als canvas_item in einem SubViewport
// auf 2× Sim-Auflösung, EINMAL je Terrain-Update (Main.gd `_bake_relief`).
// Pro Vertex und Pass gerechnet kostete derselbe Filter in der Studie 35,6 ms je
// Bild: Tiefen-Vorpass, Farbpass und vier Schattenkaskaden werteten ihn je neu
// aus. Gebacken liest der Terrain-Shader nur eine Textur.
//
// Ausgabe (linear, Float-Viewport): R = Höhenzuschlag in Welteinheiten,
// GB = Steigungszuschlag dh/duv, A = Rinnen (−) / Rippen (+). Kodiert mit
// Versatz 0.5, damit kein Kanal negativ wird; die Codes kommen wie alle Zahlen
// dieses Passes aus SimCore.ReliefRender (Uniform-Weg über die Brücke).
// Den Höhen-Code dekodiert auch Main.gd (Pinselring und Kameraziel).
shader_type canvas_item;
render_mode blend_disabled;

#include "res://shaders/erosion_filter.gdshaderinc"

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D protect_tex : filter_linear, repeat_disable;
// Gitter, Überhöhung und Meeresspiegel setzt Main.gd wie beim Terrain-Material;
// ohne Editor-Vorschau braucht dieser Pass keine Literal-Defaults.
uniform float grid_n;
uniform float hscale;
uniform float sea_level;
// Kalibrierung (SimCore.ReliefRender), default-frei wie die water_*-Uniforms.
uniform float relief_scale;
uniform float relief_strength;
uniform float relief_sharpen;
uniform float relief_sharpen_radius;
uniform float relief_height_code;
uniform float relief_slope_code;
uniform float relief_cavity_gully_gain;
uniform float relief_cavity_ridge_gain;
uniform float relief_ridge_cap;
// Felsrippen (Look-Iteration 7): dieselbe Rinnenfunktion eine Skala feiner,
// nach der Steilheit gewichtet. Weltsteigung braucht die Kartengröße.
uniform float world_size;
uniform float relief_rib_scale;
uniform float relief_rib_strength;
uniform float relief_rib_slope_lo;
uniform float relief_rib_slope_hi;
uniform float relief_rib_floor;
uniform float relief_cavity_rib_gain;
// Felsbänke (Look-Iteration 7): Schichtstufen auf Steilflanken.
uniform float relief_bench_spacing;
uniform float relief_bench_relief;
uniform float relief_cavity_bench_gain;

#include "res://shaders/protect.gdshaderinc"

// Laplace-artiger Gratanteil: Höhe minus Mittel eines Rings. Positiv auf
// Kuppen und Graten, negativ in Mulden; nur der positive Teil wird benutzt,
// die Verschiebung hebt Grate also nur an und senkt keinen Talboden. Weich
// gedeckelt (tanh, in Welteinheiten): junges, steiles Relief würde einzelne
// Gipfel sonst zu Nadeln ziehen.
float ridge_at(vec2 uv) {
	float r = relief_sharpen_radius / grid_n;
	float d = r * 0.7071;
	float h = texture(height_tex, uv).r;
	float ring = texture(height_tex, uv + vec2(r, 0.0)).r + texture(height_tex, uv - vec2(r, 0.0)).r
	           + texture(height_tex, uv + vec2(0.0, r)).r + texture(height_tex, uv - vec2(0.0, r)).r
	           + texture(height_tex, uv + vec2(d, d)).r + texture(height_tex, uv - vec2(d, d)).r
	           + texture(height_tex, uv + vec2(d, -d)).r + texture(height_tex, uv - vec2(d, -d)).r;
	float cap = relief_ridge_cap / hscale;  // Deckel in Sim-Höhe
	return cap * tanh(max(h - ring * 0.125, 0.0) * relief_sharpen / cap);
}

void fragment() {
	vec2 uv = UV;
	float h = texture(height_tex, uv).r;
	float texel = 1.0 / grid_n;
	vec2 slope = vec2(texture(height_tex, uv + vec2(texel, 0.0)).r - texture(height_tex, uv - vec2(texel, 0.0)).r,
	                  texture(height_tex, uv + vec2(0.0, texel)).r - texture(height_tex, uv - vec2(0.0, texel)).r)
	           * 0.5 * grid_n;
	// Wasser (Schutzmaske) und Küstensaum bleiben auf der Sim-Höhe.
	float w = (1.0 - protect_at(uv)) * smoothstep(sea_level + 0.008, sea_level + 0.04, h);
	vec4 relief = vec4(0.0);
	if (w > 0.001) {
		float fade_target = clamp((h - sea_level) / 0.6 * 2.0 - 1.0, -1.0, 1.0);
		float mag;
		vec4 det = erosion_detail_at(uv, slope, fade_target, relief_scale,
		                             relief_strength, 3, mag);
		float e = texel;
		vec2 ridge_slope = vec2(ridge_at(uv + vec2(e, 0.0)) - ridge_at(uv - vec2(e, 0.0)),
		                        ridge_at(uv + vec2(0.0, e)) - ridge_at(uv - vec2(0.0, e)))
		                 / (2.0 * e);
		float ridge = ridge_at(uv);
		// Felsrippen (Look-Iteration 7): eine zweite, feinere Rinnenschar
		// (~120 m statt ~2,5 km), die auf Steilflanken voll und auf sanften
		// Grashängen nur zu `relief_rib_floor` steht. Sie zerlegt glatte Wände
		// in Rippen und Runsen mit echtem Licht und Schatten und trägt, anders
		// als das feine Pixel-Detail, bis in die Übersicht. Versetzt
		// abgetastet, damit sie nicht in Phase mit der groben Schar liegt.
		float wslope = length(slope) * hscale / max(world_size, 1e-6);
		float steep = mix(relief_rib_floor, 1.0,
		                  smoothstep(relief_rib_slope_lo, max(relief_rib_slope_hi, relief_rib_slope_lo + 1e-6), wslope));
		float rib_mag;
		vec4 rib = erosion_detail_at(uv + vec2(0.37, 0.61), slope, fade_target, relief_rib_scale,
		                             relief_rib_strength, 3, rib_mag);
		rib.xyz *= steep;
		// Felsbänke (Look-Iteration 7): Schichtstufen im Abstand
		// `relief_bench_spacing` (Welt-Höhe), gewellt mit den Rippen. Jede
		// Stufe ist eine kurze, steile, beschattete Stirn über einer flacheren
		// Bank: die Steigung wird dort größer, hier kleiner (Mittel über eine
		// Stufe ≈ 0, keine Höhenänderung), die Stirn dunkelt über den
		// Hell-Dunkel-Kanal ab. Nur auf Steilflanken (`steep` ohne den
		// Grashang-Anteil). Je Pixel im Terrain-Shader kostete dasselbe Bildzeit.
		float bench_w = clamp((steep - relief_rib_floor) / max(1.0 - relief_rib_floor, 1e-6), 0.0, 1.0);
		float bp = fract(h * hscale / max(relief_bench_spacing, 1e-6) + rib.x / rib_mag * 0.35
		                 + det.x / mag * 0.25);
		float riser = smoothstep(0.70, 0.86, bp) * (1.0 - smoothstep(0.94, 1.0, bp));
		vec2 bench_slope = slope * (riser * 4.0 - 0.75) * relief_bench_relief * bench_w;
		relief = vec4((det.x + rib.x + ridge) * hscale, det.yz + rib.yz + ridge_slope + bench_slope,
		              clamp(det.x / mag * relief_cavity_gully_gain + rib.x / rib_mag * relief_cavity_rib_gain
		                    + ridge * relief_cavity_ridge_gain - riser * bench_w * relief_cavity_bench_gain,
		                    -1.0, 1.0)) * w;
	}
	COLOR = vec4(relief.x * relief_height_code + 0.5, relief.yz * relief_slope_code + 0.5,
	             relief.w * 0.5 + 0.5);
}

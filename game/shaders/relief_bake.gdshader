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
uniform float relief_bank_lift;
uniform float relief_bank_radius;
uniform float relief_bank_shade;
uniform float relief_bar_lift;

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

// Wasser-Kern der Schutzmaske (Stufe 255: Bänder und sichtbares Rasterwasser;
// 254 = nur geschützt, 253 = frische Bank, s. SimRender.WaterProtectMask),
// bilinear aus den vier Nachbar-Texeln: x = Kern-Anteil, y = Höhen-Deckel der
// Uferkante (0 im Kern, `relief_bar_lift` auf der Bank, sonst
// `relief_bank_lift`). Die Schwellen trennen nur die Byte-Stufen.
vec2 bank_tap(ivec2 i) {
	ivec2 hi = ivec2(int(grid_n) - 1);
	float p = texelFetch(protect_tex, clamp(i, ivec2(0), hi), 0).r;
	float core = step(254.5 / 255.0, p);
	float bar = step(252.5 / 255.0, p) * (1.0 - step(253.5 / 255.0, p));
	return vec2(core, mix(mix(relief_bank_lift, relief_bar_lift, bar), 0.0, core));
}

vec2 core_at(vec2 uv) {
	vec2 t = uv * grid_n - 0.5;
	ivec2 i0 = ivec2(floor(t));
	vec2 f = t - floor(t);
	vec2 c00 = bank_tap(i0), c10 = bank_tap(i0 + ivec2(1, 0));
	vec2 c01 = bank_tap(i0 + ivec2(0, 1)), c11 = bank_tap(i0 + ivec2(1, 1));
	return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}

// Uferkante (ReliefRender.bankLift): Land außerhalb des Wasser-Kerns steht um
// `relief_bank_lift` höher, Bänder, Rasterwasser und Seen bleiben auf der
// Sim-Höhe — ein Einschnitt mit Böschung, deren Fuß die Bandfläche in der
// Tiefenprüfung als Wasserlinie abschneidet. Frische Bänke stehen nur um
// `relief_bar_lift` höher (knapp über dem Bandspiegel), die Böschung steigt
// erst hinter ihnen an. Kern und Deckel werden über einen Ring gemittelt,
// damit die Böschung stetig ansteigt; das Küsten-Gate blendet sie zum Meer
// hin aus.
float bank_at(vec2 uv) {
	float r = relief_bank_radius / grid_n;
	float d = r * 0.7071;
	vec2 p = core_at(uv)
	       + core_at(uv + vec2(r, 0.0)) + core_at(uv - vec2(r, 0.0))
	       + core_at(uv + vec2(0.0, r)) + core_at(uv - vec2(0.0, r))
	       + core_at(uv + vec2(d, d)) + core_at(uv - vec2(d, d))
	       + core_at(uv + vec2(d, -d)) + core_at(uv - vec2(d, -d));
	p /= 9.0;
	float h = texture(height_tex, uv).r;
	return min(relief_bank_lift * (1.0 - smoothstep(0.3, 0.95, p.x)), p.y)
	     * smoothstep(sea_level + 0.008, sea_level + 0.04, h);
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
		                             relief_strength, mag);
		float e = texel;
		vec2 ridge_slope = vec2(ridge_at(uv + vec2(e, 0.0)) - ridge_at(uv - vec2(e, 0.0)),
		                        ridge_at(uv + vec2(0.0, e)) - ridge_at(uv - vec2(0.0, e)))
		                 / (2.0 * e);
		float ridge = ridge_at(uv);
		relief = vec4((det.x + ridge) * hscale, det.yz + ridge_slope,
		              clamp(det.x / mag * relief_cavity_gully_gain + ridge * relief_cavity_ridge_gain, -1.0, 1.0)) * w;
	}
	float eb = texel;
	float bank = bank_at(uv);
	vec2 bank_slope = vec2(bank_at(uv + vec2(eb, 0.0)) - bank_at(uv - vec2(eb, 0.0)),
	                       bank_at(uv + vec2(0.0, eb)) - bank_at(uv - vec2(0.0, eb))) / (2.0 * eb);
	relief.x += bank;
	relief.yz += bank_slope / hscale;  // Steigungskanal in Sim-Höhe je UV
	// Böschung dunkel (Rinnen-Kanal) nach ihrer Steigung: die Flanke wird
	// nasse, beschattete Erde, die flache Bank am Fuß und die Kante oben
	// nicht. Anstieg je Texel in Welteinheiten; die steilste Stelle steigt
	// bei `relief_bank_radius` 2 um rund ein Viertel von `relief_bank_lift`.
	float rise = length(bank_slope) * eb;
	relief.w = clamp(relief.w - relief_bank_shade * smoothstep(0.02, 0.12, rise), -1.0, 1.0);
	COLOR = vec4(relief.x * relief_height_code + 0.5, relief.yz * relief_slope_code + 0.5,
	             relief.w * 0.5 + 0.5);
}

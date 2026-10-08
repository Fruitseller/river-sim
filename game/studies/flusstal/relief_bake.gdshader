// Back-Pass der groben Verschiebung (Flusstal-Studie #116). Läuft als
// canvas_item in einem SubViewport auf 2× Sim-Auflösung, EINMAL je
// Terrain-Update (Flusstal.gd). Pro Vertex und Pass gerechnet kostete derselbe
// Filter ~20 ms je Bild: Tiefen-Vorpass, Farbpass und vier Schattenkaskaden
// werteten ihn je erneut aus. Gebacken liest der Terrain-Shader nur eine Textur.
//
// Ausgabe (linear, Float-Viewport): R = Höhenzuschlag in Welteinheiten,
// GB = Steigungszuschlag dh/duv, A = Rinnen (−) / Rippen (+). Kodiert mit
// Versatz, damit kein Kanal negativ wird (Schlüssel: STUDY_RELIEF_* unten,
// gespiegelt in landscape.gdshaderinc).
shader_type canvas_item;
render_mode blend_disabled;

#include "res://shaders/erosion_filter.gdshaderinc"

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D study_protect_tex : filter_linear_mipmap, repeat_disable;
uniform float grid_n = 720.0;
uniform float hscale = 24.0;
uniform float sea_level = 0.15;
// Grobe Rinnen: Skala in UV (0.022 ≈ 16 Sim-Zellen ≈ 2,5 km Wellenlänge der
// größten Rinne), Stärke relativ zur Skala wie beim feinen Detail.
uniform float study_relief_scale = 0.022;
uniform float study_relief_strength = 0.55;
// Gratschärfung: nur positive Krümmung (Grate) wird angehoben; Talböden
// bleiben, wo sie sind, damit kein Bett unter einem Band absinkt.
uniform float study_sharpen = 2.2;
uniform float study_sharpen_radius = 2.5; // Sim-Zellen

#include "res://studies/flusstal/protect.gdshaderinc"

// Laplace-artiger Gratanteil: Höhe minus Mittel eines Rings. Positiv auf
// Kuppen und Graten, negativ in Mulden; nur der positive Teil wird benutzt.
float study_ridge(vec2 uv) {
	float r = study_sharpen_radius / grid_n;
	float d = r * 0.7071;
	float h = texture(height_tex, uv).r;
	float ring = texture(height_tex, uv + vec2(r, 0.0)).r + texture(height_tex, uv - vec2(r, 0.0)).r
	           + texture(height_tex, uv + vec2(0.0, r)).r + texture(height_tex, uv - vec2(0.0, r)).r
	           + texture(height_tex, uv + vec2(d, d)).r + texture(height_tex, uv - vec2(d, d)).r
	           + texture(height_tex, uv + vec2(d, -d)).r + texture(height_tex, uv - vec2(d, -d)).r;
	return max(h - ring * 0.125, 0.0) * study_sharpen;
}

void fragment() {
	vec2 uv = UV;
	float h = texture(height_tex, uv).r;
	float texel = 1.0 / grid_n;
	vec2 slope = vec2(texture(height_tex, uv + vec2(texel, 0.0)).r - texture(height_tex, uv - vec2(texel, 0.0)).r,
	                  texture(height_tex, uv + vec2(0.0, texel)).r - texture(height_tex, uv - vec2(0.0, texel)).r)
	           * 0.5 * grid_n;
	float w = (1.0 - study_protect(uv)) * smoothstep(sea_level + 0.008, sea_level + 0.04, h);
	vec4 relief = vec4(0.0);
	if (w > 0.001) {
		float fade_target = clamp((h - sea_level) / 0.6 * 2.0 - 1.0, -1.0, 1.0);
		float mag;
		vec4 det = erosion_detail_at(uv, slope, fade_target, study_relief_scale,
		                             study_relief_strength, mag);
		float e = texel;
		vec2 ridge_slope = vec2(study_ridge(uv + vec2(e, 0.0)) - study_ridge(uv - vec2(e, 0.0)),
		                        study_ridge(uv + vec2(0.0, e)) - study_ridge(uv - vec2(0.0, e)))
		                 / (2.0 * e);
		float ridge = study_ridge(uv);
		relief = vec4((det.x + ridge) * hscale, det.yz + ridge_slope,
		              clamp(det.x / mag * 1.6 + ridge * 25.0, -1.0, 1.0)) * w;
	}
	COLOR = vec4(relief.x * 0.25 + 0.5, relief.yz * 0.02 + 0.5, relief.w * 0.5 + 0.5);
}

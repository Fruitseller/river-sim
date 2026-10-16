// Wolkenkörper über dem Kamm (Issue #174 D, Vorlagen B/C): wenige weiche
// Wolken als Impostor-Schichten in Gipfelhöhe. Dieselbe Rauschquelle und
// Schwelle wie die Wolkenschatten (clouds.gdshaderinc, `cloud_cover_at`), in
// Basishöhe `cloud_height`; die Schatten in Terrain, Ozean und Bändern
// projizieren entlang der Sonne auf genau diese Höhe und liegen damit unter
// ihrer Wolke. Sichtbar ist eine Wolke nur über hohem Gelände (Kamm), der
// Schatten fällt wie bisher überall.
//
// Drei gestapelte Ebenen (`cloud_body_layer` 0 … 1): je höher, desto dichter
// muss die Wolke sein. Das wölbt die Wolke zur Mitte hin auf, statt ein
// flaches Blatt zu zeigen. Werte und Qualitätsstufe setzt ausschließlich
// game/scripts/Lighting.gd (Wächter: game/tests/lighting.gd); in
// `performance` sind die Körper ausgeblendet.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

#include "res://shaders/clouds.gdshaderinc"

uniform float u_time = 0.0;
// Sim-Höhenfeld (Main.gd bindet height_tex des Terrains), schwarz ohne Bindung.
uniform sampler2D height_tex : filter_linear, repeat_disable, hint_default_black;
uniform float world_size;
uniform float hscale;
uniform float cloud_body_layer;
uniform float cloud_body_opacity;
// Tuning der Körper-Optik (Review zu #174 D): alle Tuning-Werte setzt
// game/scripts/Lighting.gd — hier keine Literal-Defaults.
uniform float cloud_body_lift;           // Schwelle je Ebene angehoben (Kern)
uniform float cloud_body_self_shadow_dist;  // Dichte-Probe zur Sonne (Selbstschatten)
uniform float cloud_body_self_shadow_gain;   // Helligkeit je Dichte-Differenz
uniform float cloud_body_ridge_lo;
uniform float cloud_body_ridge_hi;
uniform vec3 cloud_body_sun;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 xz = v_world.xz;
	// Erst die billige Kamm-Prüfung (eine Textur-Lesung), dann die teure
	// Dichte (drei Rausch-Oktaven je Aufruf): die Ebenen sind weltgroß und
	// transparent, der Löwenanteil der Fragmente liegt außerhalb des Kamms
	// oder der Welt und verwirft hier, bevor Rauschen läuft (Review zu
	// #174 D).
	vec2 uv = xz / max(world_size, 1e-4) + vec2(0.5);
	float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
	float ground = textureLod(height_tex, clamp(uv, vec2(0.0), vec2(1.0)), 0.0).r * hscale;
	float ridge = smoothstep(cloud_body_ridge_lo, max(cloud_body_ridge_hi, cloud_body_ridge_lo + 1e-4), ground)
	            * inside;
	if (ridge <= 0.0) {
		discard;
	}
	float density = cloud_density(xz, u_time);
	// Höhere Ebenen nur im Wolkenkern: dieselbe Schwelle wie der Schatten an
	// der Basis (cloud_cover_at, clouds.gdshaderinc — EINE Quelle), nach oben
	// um bis zu cloud_body_lift angehoben.
	float lift = cloud_body_layer * cloud_body_lift;
	float cover = cloud_cover_at(xz, u_time, lift);
	float alpha = cover * ridge * cloud_body_opacity;
	if (alpha < 0.003) {
		discard;
	}
	// Selbstschatten: wo die Wolke zur Sonne hin dichter wird, liegt diese
	// Stelle in ihrem eigenen Schatten (grauer Bauch, helle Kuppe).
	vec2 sun_xz = length(cloud_body_sun.xz) > 1e-4 ? normalize(cloud_body_sun.xz) : vec2(0.0);
	float toward = cloud_density(xz + sun_xz * cloud_body_self_shadow_dist, u_time);
	float lit = clamp(0.75 + (density - toward) * cloud_body_self_shadow_gain
	                + cloud_body_layer * 0.2, 0.0, 1.0);
	ALBEDO = mix(vec3(0.60, 0.64, 0.70), vec3(1.0, 0.98, 0.95), lit);
	ALPHA = alpha;
}

// Ufer und Bett des Fluss-Korridors (Look E, Issue #239). Eingebunden von
// corridor.gdshader (aktueller Band-Stand, schreibt Tiefe) und
// corridor_outgoing.gdshader (voriger Stand in der Zeitraffer-Blende, ohne
// Tiefe — sonst verdeckte der ausblendende Stand den neuen).
//
// Vertex-Vertrag (RiverCorridorMesh, SimNode `corridor_*`):
//   COLOR.rg = Band-Tangente (·0,5 + 0,5), COLOR.b = Rang/6, COLOR.a = Deckkraft
//   UV.x = Querlage −1 … +1 (Uferkante links … rechts), UV.y = Bogenlänge (Welt)
//   UV2.x = signierte Bogenstärke, UV2.y = Gleithang-Anteil (Kiesbank)
//   CUSTOM0 = (Tiefe unter Wasser, Deckel-Höhe, Querversatz, Wasser-Halbbreite),
//             alles in Welt-Einheiten.
// Das Mesh liegt im Ursprung (MODEL_MATRIX = Einheit), Main.gd setzt nichts anderes.

uniform float u_time = 0.0;
uniform float ribbon_blend = 1.0;
uniform bool ribbon_outgoing = false;
uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D height_prev_tex : filter_linear, repeat_disable;
uniform sampler2D color_tex : filter_linear, repeat_disable;
uniform sampler2D color_prev_tex : filter_linear, repeat_disable;
uniform float height_blend = 1.0;
uniform float overlay_blend = 1.0;
uniform float world_size = 100.0;
uniform float grid_n = 256.0;

#include "res://shaders/corridor_common.gdshaderinc"
#include "res://shaders/clouds.gdshaderinc"

// Geschmackswerte des Korridors.
const vec3 BANK_SOIL = vec3(0.24, 0.18, 0.12);      // Böschung, Prallhang (Erde)
const vec3 BANK_GRAVEL = vec3(0.60, 0.56, 0.47);    // Kiesbank am Gleithang
const vec3 BED_COLOR = vec3(0.40, 0.37, 0.29);      // Bett unter Wasser
const vec3 WATER_INSCATTER = vec3(0.014, 0.055, 0.072); // Wasserkörper, tief (Petrol, Look-Iteration 14)
const vec3 WATER_ABSORB = vec3(34.0, 14.0, 10.0);     // Beer-Lambert je Welt-Einheit Tiefe
const float WET_RIM = 0.008;                        // nasser Saum über der Wasserlinie (Welt-Y; flache Ufer steigen kaum)
const float EDGE_FADE = 0.2;                        // Uferkante blendet ins Gelände (Anteil Querlage)
const float FADE_CAP = 0.98;

varying vec3 v_world;
varying float v_lid;
varying float v_depth;
varying float v_alpha;
varying float v_bend;
varying float v_bar;
varying vec2 v_dir;

float cor_hash(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float cor_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(cor_hash(i), cor_hash(i + vec2(1.0, 0.0)), u.x),
	           mix(cor_hash(i + vec2(0.0, 1.0)), cor_hash(i + vec2(1.0)), u.x), u.y);
}

void vertex() {
	vec3 p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 t = COLOR.rg * 2.0 - 1.0;
	vec2 perp = vec2(-t.y, t.x);
	float lid = CUSTOM0.y;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	float f = corridor_widen(p, CUSTOM0.w, COLOR.a, cam, PROJECTION_MATRIX);
	if (f > 1.001) {
		vec2 center = p.xz - perp * CUSTOM0.z;
		p.xz = center + perp * corridor_widened_offset(CUSTOM0.z, CUSTOM0.w, f);
		float yt = corridor_terrain_y(p.xz);
		// Ufer über Wasser legen sich auf das Gelände der neuen Lage.
		if (CUSTOM0.x < 0.0) {
			p.y = mix(p.y, max(p.y, yt), clamp((f - 1.0) * 2.0, 0.0, 1.0));
		}
		lid = max(lid, yt + CORRIDOR_LID_CLEAR);
	}
	VERTEX = p;
	v_world = p;
	v_lid = lid;
	v_depth = CUSTOM0.x;
	v_alpha = COLOR.a;
	v_bend = UV2.x;
	v_bar = UV2.y;
	v_dir = t;
}

void fragment() {
	vec2 guv = corridor_grid_uv(v_world.xz);
	vec3 terrain_col = texture(color_tex, guv).rgb;
	if (overlay_blend < 1.0) {
		terrain_col = mix(texture(color_prev_tex, guv).rgb, terrain_col, overlay_blend);
	}
	float across = abs(UV.x);
	float footprint = length(fwidth(v_world.xz));
	vec3 n_ws = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	if (n_ws.y < 0.0) {
		n_ws = -n_ws;
	}
	float steep = 1.0 - n_ws.y;

	// Ufer: Grundton ist das Gelände daneben (bewachsenes Ufer), darauf
	// Erde, wo die Böschung steil ist (Prallhang), und Kies auf der flachen
	// Bank am Gleithang, fleckig entlang des Laufs. Direkt über der
	// Wasserlinie ein nasser, dunkler Saum.
	float pebble = cor_noise(v_world.xz * 55.0) * 0.6 + cor_noise(v_world.xz * 140.0) * 0.4;
	vec3 gravel = BANK_GRAVEL * mix(0.8, 1.12, pebble);
	vec3 soil = BANK_SOIL * mix(0.8, 1.1, cor_noise(v_world.xz * 30.0));
	float above = max(-v_depth, 0.0);
	float top = smoothstep(1.0 - 2.0 * EDGE_FADE, 1.0, across);
	float patch = smoothstep(0.3, 0.55, cor_noise(vec2(UV.y * 1.3, v_bend * 3.0) + 11.0));
	float bar = smoothstep(0.12, 0.5, v_bar) * (1.0 - smoothstep(0.35, 0.7, steep))
		* mix(0.35, 1.0, patch) * (1.0 - top);
	// Erde nur auf Flächen, die zum Fluss schauen: die Außenflanke eines
	// Uferwalls (Kante über flacher Aue) ist keine Prallhang-Wand.
	vec2 outward_dir = vec2(-v_dir.y, v_dir.x) * sign(UV.x);
	float facing_in = smoothstep(0.0, 0.15, -dot(n_ws.xz, outward_dir));
	float cut = smoothstep(0.2, 0.55, steep) * (1.0 - top * 0.5) * facing_in;
	vec3 bank = terrain_col * mix(1.0, 0.72, 1.0 - top);
	bank = mix(bank, soil, cut);
	bank = mix(bank, gravel, bar);
	float wet = 1.0 - smoothstep(0.0, WET_RIM, above);
	bank *= mix(1.0, 0.6, wet);

	// Bett unter Wasser: Beer-Lambert aus der Tiefe des Profils, schräger
	// Blick verlängert den Weg durchs Wasser.
	float d = max(v_depth, 0.0);
	float ndv = clamp(dot(normalize(VIEW), mat3(VIEW_MATRIX) * vec3(0.0, 1.0, 0.0)), 0.25, 1.0);
	vec3 trans = exp(-WATER_ABSORB * d / ndv);
	vec3 bed = mix(BED_COLOR, gravel * 0.8, bar) * mix(0.85, 1.05, pebble);
	vec3 under = bed * trans + WATER_INSCATTER * (1.0 - trans);
	float submerged = smoothstep(-0.002, 0.004, v_depth);
	vec3 col = mix(bank, under, submerged);
	col *= cloud_light(v_world, u_time);

	ALBEDO = col;
	ROUGHNESS = mix(mix(0.92, 0.45, wet), 1.0, submerged);
	SPECULAR = mix(mix(0.3, 0.5, wet), 0.0, submerged);
	// Kiesel als Normalen-Rauschen auf der Bank, nur wo sie Pixel tragen.
	float near = 1.0 - smoothstep(0.01, 0.04, footprint);
	vec2 pg = vec2(cor_noise(v_world.xz * 140.0 + 3.1), cor_noise(v_world.xz * 140.0 + 7.7)) - 0.5;
	vec3 n2 = normalize(n_ws + vec3(pg.x, 0.0, pg.y) * 0.35 * bar * near * (1.0 - submerged));
	NORMAL = normalize(mat3(VIEW_MATRIX) * n2);

	float a = clamp(v_alpha, 0.0, 1.0);
	float presence = smoothstep(0.02, 0.25, a);
	float edge = 1.0 - smoothstep(1.0 - EDGE_FADE, 1.0, across);
	// Über Wasser deckt der Korridor nur, wo er etwas zeigt: Wand am
	// Prallhang, Kies am Gleithang, nasser Saum. Sonst scheint das Gelände
	// durch (es liegt dort ohnehin fast auf der Böschung); die Makrofarbe
	// allein ist nicht das fertig schattierte Gelände und las sich grau.
	float shows = max(max(cut, bar), wet * 0.85);
	float alpha = presence * edge * mix(shows, 1.0, submerged);
	float share = ribbon_outgoing ? 1.0 - ribbon_blend : ribbon_blend;
	if (share < 1.0) {
		alpha = 1.0 - pow(1.0 - clamp(alpha, 0.0, FADE_CAP), max(share, 0.0));
	}
	ALPHA = alpha;

	vec3 cam = CAMERA_POSITION_WORLD;
	DEPTH = corridor_depth(v_world, v_lid, cam, VIEW_MATRIX, PROJECTION_MATRIX);
	LIGHT_VERTEX = (VIEW_MATRIX * vec4(corridor_lid_point(v_world, v_lid, cam), 1.0)).xyz;
}

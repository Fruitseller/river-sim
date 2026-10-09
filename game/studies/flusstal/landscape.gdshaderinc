// Landschaftsschichten der Flusstal-Studie (#116), zweite Runde.
// Eingebunden NACH den Uniforms und Noise-Helfern von terrain.gdshader und nur
// im FLUSSTAL_STUDY-Build. Alles rein visuell, die Sim-Felder bleiben unberührt.
//
// Maßstab: 1 Welteinheit ≈ 100 m (Relief bis ~2,4 km bei hscale 24). Daraus
// folgen Kronen von ~11 m und ein Kronendach von ~20 m Höhe.
//
// 1. Geometrie: die Sim-Höhe ist bilinear glatt („Knete"). Hier wird sie beim
//    Rendern verfeinert, als echte Verschiebung (Silhouette + Schattenwurf),
//    nicht nur als Normale: grobe Erosionsrinnen (dieselbe runevision-Funktion
//    wie das feine Detail, nur größere Skala) und einseitig geschärfte Grate.
//    Gerechnet wird beides einmal je Terrain-Update in relief_bake.gdshader;
//    hier wird nur gelesen (Vertex: Höhe, Fragment: Steigung und Rinnen).
// 2. Wald: statt einzelner Instanzbäume ein angehobenes Kronendach mit Kronen
//    pro Pixel. Wald liest aus der Luft als Textur aus Kronen und dunklen
//    Lücken, nicht als Ansammlung einzelner Modelle.
//
// Beide Schichten enden an Wasser: `study_protect_tex` ist die Schutzmaske aus
// SimRender (Rasterwasser plus gebaute Bänder plus Saum, #154).
// So liegen Flussbänder und Seeufer weiter auf der unveränderten Sim-Höhe.

uniform bool study_geometry = false;
uniform bool study_canopy_enabled = false;
uniform int study_debug = 0; // 1 = Schutzmaske, 2 = Waldmaske, 3 = Rinnen/Rippen
uniform sampler2D study_protect_tex : filter_linear, repeat_disable;
// Gebackene grobe Verschiebung (relief_bake.gdshader, Kodierung dort).
uniform sampler2D study_relief_tex : filter_linear, repeat_disable;
uniform float study_canopy_cell = 0.11;   // Welteinheiten je Krone
uniform float study_canopy_height = 0.20; // Welteinheiten Dachhöhe

varying float v_study_forest;

#include "res://studies/flusstal/protect.gdshaderinc"

float study_forest_mask(vec2 uv, float h, vec2 slope_uv) {
	vec4 s = textureLod(surface_tex, uv, 0.0);
	vec2 wp = uv * world_size;
	float world_slope = length(slope_uv) * hscale / world_size;
	// Lichtungen und Waldränder: Rauschen auf ~200–400 m verschiebt die
	// Vegetationsschwelle, der Wald bildet so Gruppen statt einer Fläche.
	float clump = fbm(wp * 0.45) - 0.47;
	float f = smoothstep(0.14, 0.32, s.r + clump * 0.45);
	f *= 1.0 - smoothstep(1.2, 1.8, world_slope); // keine Bäume in Wänden
	f *= 1.0 - smoothstep(0.15, 0.40, s.b);         // nicht auf Schnee/Eis
	f *= 1.0 - study_protect(uv);
	f *= smoothstep(sea_level + 0.012, sea_level + 0.03, h);
	return f;
}

// Liefert die zusätzliche Höhe in Welteinheiten. Varyings darf nur vertex()
// selbst schreiben, deshalb kommen Steigung, Waldmaske und Rinnen als out-Parameter.
float study_vertex(vec2 uv, float h, float lift, out float forest_out) {
	forest_out = 0.0;
	if (!study_enabled) {
		return 0.0;
	}
	float dy = 0.0;
	vec2 slope = vec2(0.0);
	if (study_geometry) {
		// Seen hebt der Vertex-Shader selbst auf den Spiegel; dort keine Rinnen.
		// Nur die Höhe: Normalen und Rinnen liest der Fragment-Shader direkt aus
		// der Backtextur, damit ihr Detail nicht an der Mesh-Dichte hängt.
		dy = (textureLod(study_relief_tex, uv, 0.0).r - 0.5) * 4.0 * (1.0 - lift);
	}
	if (study_canopy_enabled) {
		float texel = 1.0 / grid_n;
		slope = vec2(texture(height_tex, uv + vec2(texel, 0.0)).r - texture(height_tex, uv - vec2(texel, 0.0)).r,
		             texture(height_tex, uv + vec2(0.0, texel)).r - texture(height_tex, uv - vec2(0.0, texel)).r)
		      * 0.5 * grid_n;
		forest_out = study_forest_mask(uv, h, slope);
		dy += smoothstep(0.2, 0.65, forest_out) * study_canopy_height;
	}
	return dy;
}

// Steigungszuschlag der groben Verschiebung je Pixel (dh/duv).
vec2 study_slope(vec2 uv) {
	if (!study_enabled || !study_geometry) {
		return vec2(0.0);
	}
	return (texture(study_relief_tex, uv).gb - 0.5) * 50.0;
}

// Hell-Dunkel des groben Reliefs auf freien Flächen (unter dem Kronendach
// übernimmt das Dach selbst die Struktur).
// Rinnen (−) und Rippen (+) der groben Verschiebung dunkeln Rinnenböden ab und
// hellen Rippen auf. Erst diese Hell-Dunkel-Struktur macht große Felsflächen
// aus der Übersicht als Fels lesbar statt als glatten Sand.
float study_cavity(vec2 uv) {
	return (texture(study_relief_tex, uv).a - 0.5) * 2.0;
}

void study_relief_shade(vec2 uv, inout vec3 color) {
	if (!study_geometry) {
		return;
	}
	float c = study_cavity(uv);
	color *= 1.0 + (c < 0.0 ? c * 0.42 : c * 0.18);
}

// Kronendach pro Pixel: Voronoi-Kronen (Laubbaum als Kuppel, Nadelbaum als
// Kegel), dunkle Lücken dazwischen, Selbstschatten zum Kronenrand. In der
// Entfernung (Krone unter ~1 Pixel) geht das Muster in seinen Mittelwert über.
void study_canopy(vec2 wp, vec2 uv, float h, vec3 view_pos, vec3 macro_n,
                  inout vec3 color, inout vec3 n, inout float rough) {
	if (study_debug == 1) {
		color = mix(color, vec3(0.9, 0.1, 0.1), study_protect(uv));
		return;
	}
	if (study_debug == 3) {
		color = vec3(0.5 + study_cavity(uv) * 0.5);
		return;
	}
	if (study_debug == 2) {
		color = mix(color, vec3(0.9, 0.1, 0.9), v_study_forest);
		return;
	}
	float f = v_study_forest;
	if (!study_canopy_enabled || f <= 0.002) {
		return;
	}
	float conifer_share = smoothstep(veg_alt_lo - 0.08, veg_alt_hi, h);
	vec2 p = wp / study_canopy_cell;
	vec2 g = floor(p);
	float best = 0.0;
	vec2 tilt = vec2(0.0);
	float tint = 0.0;
	float con = 0.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 c = g + vec2(float(i), float(j));
			vec2 r1 = ehash(c);
			vec2 r2 = ehash(c + vec2(17.3, 5.1));
			// Krone steht nur, wo die Waldmaske ihre eigene Schwelle übertrifft:
			// am Rand dünnt der Wald so kronenweise aus.
			if (f < r2.y * 0.30 + 0.55) {
				continue;
			}
			vec2 d = p - (c + 0.5 + r1 * 0.30);
			float rad = 0.58 + 0.16 * r2.x;
			float dd = length(d);
			bool is_con = (r1.x * 0.5 + 0.5) < conifer_share;
			float hgt = is_con ? (rad - dd) * 1.7 : sqrt(max(rad * rad - dd * dd, 0.0));
			if (hgt > best) {
				best = hgt;
				tilt = is_con ? d / max(dd, 1e-4) * 1.7 : d / max(hgt, 0.12);
				tint = r1.y * 0.5 + 0.5;
				con = is_con ? 1.0 : 0.0;
			}
		}
	}
	vec3 decid = vec3(0.105, 0.175, 0.055) * mix(0.75, 1.25, tint);
	vec3 conif = vec3(0.050, 0.098, 0.060) * mix(0.8, 1.2, tint);
	vec3 crown = mix(decid, conif, con) * mix(0.55, 1.0, clamp(best / 0.6, 0.0, 1.0));
	vec3 gap = vec3(0.022, 0.034, 0.020);
	float inside = smoothstep(0.35, 0.75, f); // Lücken nur im Bestand dunkel
	vec3 avg = mix(mix(decid, conif, conifer_share) * 0.8, gap, 0.3);
	float footprint = length(fwidth(p));
	float detail = 1.0 - smoothstep(0.35, 1.1, footprint);
	float covered = best > 0.0 ? 1.0 : inside;
	vec3 near_col = best > 0.0 ? crown : gap;
	vec3 canopy = mix(avg, near_col, detail);
	float amount = mix(smoothstep(0.25, 0.6, f), covered, detail);
	color = mix(color, canopy, amount);
	vec3 t = vec3(clamp(tilt.x, -2.0, 2.0), 0.0, clamp(tilt.y, -2.0, 2.0)) * 0.85 * detail;
	n = normalize(mix(n, normalize(macro_n + t), amount));
	rough = mix(rough, 0.92, amount);
}

// Gemeinsame Bausteine des Fluss-Korridors (Look E, Issue #239), gelesen von
// corridor.gdshaderinc (Ufer und Bett) und water.gdshader (Wasserfläche).
//
// Erwartet vom einbindenden Shader die Felder height_tex/height_prev_tex,
// height_blend, world_size und grid_n (dieselben, die Main.gd für Band und
// Terrain spiegelt) sowie die Uniform corridor_hscale.
//
// Zwei Kunstgriffe, beide nur Darstellung:
//
// 1. DECKEL-TIEFE: Ufer und Bett liegen unter der sichtbaren Geländefläche.
//    Statt das Gelände abzusenken (dessen Naht läge auf dem Zellgitter),
//    schreiben Korridor und Wasser als Tiefe die ihres Strahls auf dem Deckel
//    (`lid`, RiverCorridor.swift: höchste Geländehöhe im Querschnitt, gekappt
//    auf Wasserspiegel + `lidMaxAboveWater`, + Abstand). Gegen das Gelände darunter gewinnen sie, Hügel davor verdecken
//    sie. Ein Rest `CORRIDOR_DEPTH_KEEP` der wahren Tiefe hält die Reihenfolge
//    der Korridor-Flächen untereinander (Wasser vor Bett, nahes Ufer vor dem
//    fernen). Licht und Schatten liest der Korridor am Deckelpunkt
//    (LIGHT_VERTEX): das Gelände, das er ersetzt, wirft keinen Schatten auf ihn.
//
// 2. MINDESTBREITE: in der Totalen wird ein Lauf schmaler als ein paar
//    Bildpunkte und verschwindet. Das Band wächst dann quer mit dem
//    Kameraabstand (Kartografen-Regel: Flüsse breiter zeichnen, als sie sind).

uniform float corridor_hscale = 24.0;
// Richtung ZUR Sonne (Lighting.sun_direction), fürs Glitzern.
uniform vec3 corridor_sun_dir = vec3(0.0, 1.0, 0.0);
// Höhe des Viewports in Bildpunkten (RiverCorridor.advance). VIEWPORT_SIZE
// ist im Vertex-Shader nicht verlässlich (gemessen: Verbreiterung griff auch
// in der Nahsicht voll).
uniform float corridor_viewport_h = 1080.0;

// Geschmackswerte (Entscheidung des Eigners: Konstanten neben ihrem Code).
const float CORRIDOR_MIN_WATER_PX = 5.0;   // Wasserbreite in der Totalen, Bildpunkte
const float CORRIDOR_MAX_WIDEN = 3.5;      // höchstens so viel breiter als echt
const float CORRIDOR_DEPTH_KEEP = 0.08;    // Anteil der wahren Tiefe hinter dem Deckel …
const float CORRIDOR_DEPTH_KEEP_MAX = 0.008; // … höchstens so weit unter dem Deckel (Welt-Y, < Abstand/2)
const float CORRIDOR_LID_REACH = 3.0;      // Deckelpunkt höchstens (Deckel − Punkt) × so weit vor dem Punkt
const float CORRIDOR_LID_CLEAR = 0.02;     // = CorridorProfile.lidClearance

vec2 corridor_grid_uv(vec2 xz) {
	float n = max(grid_n, 2.0);
	return ((xz / world_size + 0.5) * (n - 1.0) + 0.5) / n;
}

// Sichtbare Geländehöhe (Welt-Y), bilinear: nur für die verbreiterten
// Kanten in der Totalen, wo die Triangulierung keine Rolle mehr spielt.
float corridor_terrain_y(vec2 xz) {
	vec2 uv = corridor_grid_uv(xz);
	float h = textureLod(height_tex, uv, 0.0).r;
	if (height_blend < 1.0) {
		h = mix(textureLod(height_prev_tex, uv, 0.0).r, h, height_blend);
	}
	return h * corridor_hscale;
}

// Verbreiterungs-Faktor ≥ 1 für ein Wasser der Halbbreite `water_half`
// (Welt) am Weltpunkt `p`. `presence` (0 … 1) blendet ihn an Bandenden aus.
float corridor_widen(vec3 p, float water_half, float presence, vec3 cam, mat4 proj) {
	float dist = length(cam - p);
	float px = 2.0 * dist / max(abs(proj[1][1]) * corridor_viewport_h, 1e-4);
	float f = clamp(CORRIDOR_MIN_WATER_PX * px / max(2.0 * water_half, 1e-4), 1.0, CORRIDOR_MAX_WIDEN);
	return mix(1.0, f, smoothstep(0.1, 0.5, presence));
}

// Querversatz nach der Verbreiterung: nur das Wasser wächst um `f`, Ufer und
// Böschung jenseits der Wasser-Halbbreite behalten ihre Breite (sonst lagen
// in der Totalen breite helle Ufer wie Straßen neben dem Lauf).
float corridor_widened_offset(float off, float water_half, float f) {
	return off + sign(off) * min(abs(off), water_half) * (f - 1.0);
}

// Punkt, an dem der Sehstrahl zu `p` die Deckel-Höhe `lid` schneidet.
// Bei flachem Blick läge der Schnitt mit der (unendlichen) Deckel-Ebene weit
// vor dem Fluss, und der Korridor gewänne gegen Hügel davor: der Weg zum
// Deckelpunkt ist auf `CORRIDOR_LID_REACH` × (Deckel − Punkt) begrenzt. Dort
// verliert das Bett eher gegen das Gelände, als dass es durch Berge scheint.
// 3 statt 6 gehört zur Deckel-Kappung (Schlucht-Befund zu #240): mit dem
// Deckel ≤ Wasser + 0,12 bleibt der Weg damit unter ~1 Welteinheit (Bett
// 0,2 tief), auch an hohen Ufern. Preis: bei sehr flachem Blick verliert das
// Bett früher gegen Gelände knapp davor.
vec3 corridor_lid_point(vec3 p, float lid, vec3 cam) {
	vec3 d = p - cam;
	if (cam.y > lid && p.y < lid && abs(d.y) > 1e-6) {
		float t = (lid - cam.y) / d.y;                       // 0 … 1 vom Auge zum Punkt
		float reach = CORRIDOR_LID_REACH * (lid - p.y) / max(length(d), 1e-6);
		return cam + d * max(t, 1.0 - reach);
	}
	return p;
}

// Clip-Position des Weltpunkts `p` mit der Tiefe des Deckel-Punkts (Rest
// der wahren Tiefe bleibt). Im VERTEX-Shader als POSITION: der Tiefentest
// bleibt früh (ein DEPTH-Schreiben im Fragment schaltet Early-Z ab) und
// gilt in jeder Clip-Konvention (auch gl_compatibility). Zwischen den
// Vertices läuft die Tiefe linear im Bild statt exakt; der Deckel hat dafür
// Abstand.
vec4 corridor_clip(vec3 p, float lid, vec3 cam, mat4 view, mat4 proj) {
	vec4 clip = proj * (view * vec4(p, 1.0));
	vec3 pl = corridor_lid_point(p, lid, cam);
	// Rest der wahren Tiefe: hält die Reihenfolge der Korridor-Flächen, aber
	// nie mehr als CORRIDOR_DEPTH_KEEP_MAX unter den Deckel (sonst verlöre ein
	// tiefes Bett gegen Gelände knapp unter dem Deckel, Review Neon Nr. 1).
	float keep = min(CORRIDOR_DEPTH_KEEP, CORRIDOR_DEPTH_KEEP_MAX / max(pl.y - p.y, 1e-6));
	vec3 q = mix(pl, p, keep);
	vec4 lid_clip = proj * (view * vec4(q, 1.0));
	return vec4(clip.xy, lid_clip.z / lid_clip.w * clip.w, clip.w);
}

// Scan-Materialien (#237): Fels, Schutt, Kies und Sand aus gescannten
// CC0-PBR-Sätzen statt aus Rausch-Oktaven. Quellen, Lizenz und Prüfsummen:
// game/assets/materials/MANIFEST.md, gepackt von
// scripts/look/pack_scan_materials.py.
//
// Zwei Textur-Arrays mit derselben Ebenen-Reihenfolge (SCAN_*):
//   scan_albedo: RGB Albedo (sRGB, mittlere Helligkeit beim Packen auf
//                SCAN_ALBEDO_MEAN normiert), A Höhe (0 … 1, für den
//                Übergang nach Höhe statt linear);
//   scan_normal: RG Normale (OpenGL, Tangentenraum), B Rauheit, A frei.
//
// WO welches Material liegt, entscheidet weiter SimRender.TerrainColorRenderer
// (Gewichte in surface_tex/cover_tex, Sand im A-Kanal der Makrofarbe); hier
// entsteht nur, WIE es aussieht. Geschmackswerte stehen als Konstanten hier.
//
// Ableitungen: die Aufrufer verzweigen je Pixel (nur auf Fels, nur auf Sand),
// implizite Mip-Wahl wäre dort undefiniert. Alle Abfragen laufen deshalb über
// textureGrad mit den Bildschirm-Ableitungen der Weltposition, die fragment()
// EINMAL im gleichförmigen Kontrollfluss bestimmt (`dpdx`, `dpdy`).

uniform sampler2DArray scan_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray scan_normal : filter_linear_mipmap_anisotropic, repeat_enable;

// Eingang für die Verfeinerung aus #238 (Strang D): Karten der GPU-Erosion
// in derselben Welt-UV wie height_tex. R Abtrag, G Ablagerung, B Abfluss,
// je 0 … 1; A frei. Ungebunden schwarz: das Material sieht aus wie ohne D.
// Wirkung (scan_amplify): Abtrag legt Fels frei und lässt ihn zerklüftet
// erscheinen, Ablagerung macht aus Fels Schutt, Abfluss dunkelt Rinnen
// feucht ab. Die Verteilung aus TerrainColorRenderer bleibt die Grundlage,
// die Karten verschieben nur innerhalb der Zelle (wie der Relief-Bake).
uniform sampler2D amplify_maps : filter_linear, repeat_disable, hint_default_black;
const float SCAN_AMPLIFY_ROCK = 0.6;   // Abtrag → Fels aus Grund und Bewuchs
const float SCAN_AMPLIFY_SCREE = 0.7;  // Ablagerung → Fels wird Schutt
const float SCAN_AMPLIFY_WET = 0.35;   // Abfluss → Abdunklung

// Karten aus #238, auf 0 … 1 geklemmt (HDR-Karten dürfen keine negativen
// Gewichte erzeugen).
vec3 scan_amplify_at(vec2 uv) {
	return clamp(texture(amplify_maps, uv).rgb, vec3(0.0), vec3(1.0));
}

const float SCAN_ROCK_BEDDED = 0.0; // Fels mit Bankung (Sediment)
const float SCAN_ROCK_JOINTED = 1.0; // Fels zerklüftet, blockig
const float SCAN_SCREE = 2.0;        // Schutt, eckig
const float SCAN_GRAVEL = 3.0;       // Flusskies, gerundet
const float SCAN_SAND = 4.0;         // Sand
// Mittlere lineare Helligkeit, auf die der Packer jede Albedo normiert hat:
// Albedo / SCAN_ALBEDO_MEAN ist damit Detail um 1, die Grundfarbe bleibt beim
// Shader (Fels dunkelgrau wie seit #174 D).
const float SCAN_ALBEDO_MEAN = 0.18;

// Weltgröße einer Kachel (Welteinheiten ≈ 100 m). Fels groß, damit eine Wand
// in der Nahsicht nicht kachelt; ein zweiter, kleinerer Maßstab mischt das
// Feingran hinein (gegen sichtbares Kacheln, Issue #237).
const float SCAN_ROCK_TILE = 1.6;
const float SCAN_ROCK_DETAIL_TILE = 0.28;
const float SCAN_SCREE_TILE = 0.55;
const float SCAN_GRAVEL_TILE = 0.30;
const float SCAN_SAND_TILE = 0.45;
// Stärke der Scan-Normalen (Tangentenneigung je Einheit).
const float SCAN_ROCK_NORMAL = 2.2;
const float SCAN_GROUND_NORMAL = 0.7;

// Schichtung: Bänder nach Höhe (Welt-Y), großflächig verbogen, in Ton und
// Normale; Abstand in Welteinheiten.
const float SCAN_STRATA_SPACING = 0.35;
const float SCAN_STRATA_WARP = 0.25;
const float SCAN_STRATA_TONE = 0.45;

struct ScanSample {
	vec3 albedo; // um 1 (Detail), mit SCAN_ALBEDO_MEAN normiert
	vec3 bump;   // tangentiale Neigung der Weltnormalen
	float rough;
	float height;
};

// Triplanare Gewichte, scharf (Potenz 6), Projektionen unter 3 % entfallen.
vec3 scan_weights(vec3 n) {
	vec3 w = pow(abs(n), vec3(6.0));
	w /= max(w.x + w.y + w.z, 1e-4);
	w = max(w - 0.03, 0.0);
	return w / max(w.x + w.y + w.z, 1e-4);
}

// Eine Projektion: `uv` in Kacheln, Ableitungen in Kacheln je Pixel.
void scan_fetch(float layer, vec2 uv, vec2 gx, vec2 gy, float w, inout vec4 alb, inout vec4 nrm) {
	alb += textureGrad(scan_albedo, vec3(uv, layer), gx, gy) * w;
	nrm += textureGrad(scan_normal, vec3(uv, layer), gx, gy) * w;
}

// Triplanar in einem Maßstab. Die Tangenten-Normale geht je Ebene entlang
// ihrer beiden Achsen in die Welt. Auf den Wänden läuft v gegen Welt-Y
// (Bildzeilen zählen nach unten), damit der Scan aufrecht steht: Bankung
// und Überhänge liegen dann richtig herum. OpenGL-Normalen zeigen mit Grün
// bildaufwärts, also nach +Y an der Wand und nach −Z in der Draufsicht.
ScanSample scan_triplanar(float layer, vec3 p, vec3 w, vec3 dpdx, vec3 dpdy, float tile) {
	float s = 1.0 / tile;
	vec4 a = vec4(0.0);
	vec3 bump = vec3(0.0);
	float rough = 0.0;
	if (w.x > 0.0) {
		vec4 al = vec4(0.0), nr = vec4(0.0);
		vec2 f = vec2(1.0, -1.0) * s;
		scan_fetch(layer, p.zy * f, dpdx.zy * f, dpdy.zy * f, 1.0, al, nr);
		vec2 t = nr.rg * 2.0 - 1.0;
		a += al * w.x; bump += vec3(0.0, t.y, t.x) * w.x; rough += nr.b * w.x;
	}
	if (w.z > 0.0) {
		vec4 al = vec4(0.0), nr = vec4(0.0);
		vec2 f = vec2(1.0, -1.0) * s;
		scan_fetch(layer, p.xy * f, dpdx.xy * f, dpdy.xy * f, 1.0, al, nr);
		vec2 t = nr.rg * 2.0 - 1.0;
		a += al * w.z; bump += vec3(t.x, t.y, 0.0) * w.z; rough += nr.b * w.z;
	}
	if (w.y > 0.0) {
		vec4 al = vec4(0.0), nr = vec4(0.0);
		scan_fetch(layer, p.xz * s, dpdx.xz * s, dpdy.xz * s, 1.0, al, nr);
		vec2 t = nr.rg * 2.0 - 1.0;
		a += al * w.y; bump += vec3(t.x, 0.0, -t.y) * w.y; rough += nr.b * w.y;
	}
	ScanSample r;
	r.albedo = a.rgb / SCAN_ALBEDO_MEAN;
	r.height = a.a;
	r.bump = bump;
	r.rough = rough;
	return r;
}

// Nur Draufsicht (flache Böden: Kies, Sand).
ScanSample scan_top(float layer, vec2 xz, vec3 dpdx, vec3 dpdy, float tile) {
	float s = 1.0 / tile;
	vec4 al = vec4(0.0), nr = vec4(0.0);
	scan_fetch(layer, xz * s, dpdx.xz * s, dpdy.xz * s, 1.0, al, nr);
	vec2 t = nr.rg * 2.0 - 1.0;
	ScanSample r;
	r.albedo = al.rgb / SCAN_ALBEDO_MEAN;
	r.height = al.a;
	r.bump = vec3(t.x, 0.0, -t.y);
	r.rough = nr.b;
	return r;
}

// Übergang nach Höhe zweier Materialien (Höhe aus dem Scan): bei Gewicht
// `t` von B gewinnt, wer höher steht; `contrast` schärft die Kante. An den
// Enden exakt (t = 0 → 0, t = 1 → 1), dazwischen stetig: die Höhe
// verschiebt nur die Mitte (Faktor 4t(1 − t)), sonst sprang ein Gewicht von
// 1 % an einem Höhenunterschied auf die Hälfte (Review Gemini, PR #237).
float scan_height_blend(float ha, float hb, float t, float contrast) {
	float shift = (hb - ha) * 2.0 * t * (1.0 - t);
	return clamp((t - 0.5 + shift) * contrast + 0.5, 0.0, 1.0);
}

// Schichtung: Ton je Bank (−1 … 1) und Bankfuge (0 … 1), aus Welt-Y, großflächig
// verbogen. `px` (Pixelgröße in Welteinheiten) blendet beides vor dem Flimmern
// in den Mittelwert. `lith` (−1 … 1, echte Lithologie) staucht weiche Lagen.
float scan_strata(vec3 p, float lith, float px, out float joint) {
	float warp = (vnoise(p.xz * 0.45 + vec2(3.0, 11.0)) - 0.5) * SCAN_STRATA_WARP
	           + (vnoise(p.xz * 1.9 + vec2(7.0, 1.0)) - 0.5) * SCAN_STRATA_WARP * 0.25;
	float b = (p.y + warp) / (SCAN_STRATA_SPACING * (1.0 + 0.25 * lith));
	float id = floor(b);
	float f = b - id;
	float fw = px / SCAN_STRATA_SPACING;
	float detail = 1.0 - smoothstep(0.25, 0.7, fw);
	// Ton je Bank, zwei Bänke im Wechsel hart/weich plus Zufall.
	float tone = vhash(vec2(id, 17.0)) * 0.7 + (mod(id, 2.0) - 0.5) * 0.6;
	// Bankfuge am oberen Rand jeder Bank, stückweise offen.
	float gate = smoothstep(0.55, 0.75, vnoise(vec2(p.x * 1.7 + p.z * 1.1, id * 3.1)));
	joint = smoothstep(1.0 - 0.06 - fw, 1.0, f) * gate * detail;
	return tone * detail;
}

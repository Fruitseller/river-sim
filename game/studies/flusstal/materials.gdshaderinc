// Optionale PBR-Bildstudie. Standardpfad bleibt ausgeschaltet, Wasser wird danach
// weiterhin vom gemeinsamen Terrain-Shader mit seinen Vertragswerten gemischt.
// Integration (Review zu #121): die PBR-Texturen modulieren ALBEDO und Rauheit
// INNERHALB der vorhandenen Sim-Gewichte — Fels-PBR nur mit Felsanteil, Boden-PBR
// mit Vegetation/Bodenanteil, nie auf Schnee/Eis (cold-Ausnahme bleibt) — statt
// `terr` am Ende pauschal zu überschreiben. So vergleicht das A/B Materialqualität
// auf denselben Biomen und Wüste/Playa bleiben nicht grün.
uniform bool study_enabled = false;
uniform sampler2D study_rock_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D study_rock_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D study_rock_roughness : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D study_ground_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D study_ground_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D study_ground_roughness : filter_linear_mipmap_anisotropic, repeat_enable;

vec3 study_tri(sampler2D tex, vec3 p, vec3 weights) {
	return texture(tex, p.yz).rgb * weights.x
	     + texture(tex, p.xz).rgb * weights.y
	     + texture(tex, p.xy).rgb * weights.z;
}

// Triplanare Tangenten-Normalen OHNE Vorzeichenkorrektur (Review zu #121):
// die Textur wird weltplanar gesampelt (p.yz/p.xz/p.xy), nicht über
// per-Face-Tangentframes. Für eine Höhenfeld-Normale (-h_u, -h_v, 1) ist der
// Tangential-Anteil bei BEIDEN Achsrichtungen (+X und -X) identisch, die
// Projektion ist ja ungespiegelt. Ein sign(macro_n)-Faktor dreht die Störung
// auf negativen Achsen um 180° („Dellen statt Beulen"), er korrigiert nichts.
// Whiteout/UDN versehen nur die Außenseiten-Komponente (tangent z) mit dem
// Achsen-Vorzeichen; hier wird z ohnehin verworfen (detail -= macro_n * dot).
vec3 study_tri_normal(vec3 p, float scale, vec3 weights) {
	vec2 nx = texture(study_rock_normal, p.yz * scale).xy * 2.0 - 1.0;
	vec2 ny = texture(study_rock_normal, p.xz * scale).xy * 2.0 - 1.0;
	vec2 nz = texture(study_rock_normal, p.xy * scale).xy * 2.0 - 1.0;
	return vec3(0.0, nx.x, nx.y) * weights.x
	     + vec3(ny.x, 0.0, ny.y) * weights.y
	     + vec3(nz.x, nz.y, 0.0) * weights.z;
}

// macro_n ist die UNGESTÖRTE Makro-Normale: `weights`/`cliff` dürfen nicht mit der
// mikro-gestörten Normale rauschen (Review zu #121).
void study_material(vec3 p, float cold, float rock_w, float veg_w, float soil_w,
                    vec3 macro_n, inout vec3 color, inout vec3 normal,
                    inout float roughness) {
	vec3 weights = pow(abs(macro_n), vec3(4.0));
	weights /= max(dot(weights, vec3(1.0)), 0.001);
	float cliff = 1.0 - smoothstep(0.60, 0.92, macro_n.y);
	// Studien-Gewicht: wie stark die PBR-Modulation maximal ist. Sie folgt den
	// Sim-Gewichten (Fels/PBR-Fels, Vegetation+Boden/PBR-Boden) und endet auf
	// Schnee/Eis; der mineralische Grundton bleibt auf Felsflächen erhalten.
	float study_w = clamp(rock_w + veg_w + soil_w, 0.0, 1.0) * (1.0 - cold);
	vec3 stone = study_tri(study_rock_color, p * 0.22, weights);
	float limestone = dot(stone, vec3(0.2126, 0.7152, 0.0722));
	stone = vec3(0.38, 0.40, 0.39) * (0.48 + limestone * 2.0);
	vec3 ground = texture(study_ground_color, p.xz * 1.4).rgb;
	vec3 moss = ground * vec3(0.48, 0.65, 0.34);
	// PBR-Palette nach Sim-Gewichten mischen: Fels-PBR dominiert Felsflächen,
	// Boden-PBR liegt unter Vegetation und auf freiem Boden.
	vec3 study_albedo = mix(moss, stone * vec3(1.12, 1.14, 1.12), cliff);
	study_albedo = mix(study_albedo, moss, veg_w * 0.6);
	// Albedo-Modulation INNERHALB der Gewichte statt Überschreiben von terr:
	// die Sim-Biomfarben (Vegetation, Boden, Lithologie, Salzkruste) bleiben
	// erkennbar, die PBR-Textur liefert die Oberflächenqualität.
	color = mix(color, study_albedo, study_w * 0.78);
	float r = mix(texture(study_ground_roughness, p.xz * 1.4).r,
	              study_tri(study_rock_roughness, p * 0.22, weights).r, cliff);
	roughness = mix(roughness, clamp(r, 0.5, 1.0), study_w);
	vec3 rock_n = study_tri_normal(p, 0.22, weights);
	vec3 ground_n = texture(study_ground_normal, p.xz * 1.4).rgb * 2.0 - 1.0;
	// Tangentiale Störung statt einer zweiten Gelände- oder Wasseroberfläche.
	vec3 detail = mix(vec3(ground_n.x, 0.0, ground_n.y), rock_n, cliff);
	detail -= macro_n * dot(detail, macro_n);
	normal = normalize(macro_n + detail * 0.32 * study_w);
}

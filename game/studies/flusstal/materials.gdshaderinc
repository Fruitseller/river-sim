// Optionale PBR-Bildstudie. Standardpfad bleibt ausgeschaltet, Wasser wird danach
// weiterhin vom gemeinsamen Terrain-Shader mit seinen Vertragswerten gemischt.
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

void study_material(vec3 p, float cold, inout vec3 color,
                    inout vec3 normal, inout float roughness) {
	vec3 weights = pow(abs(normal), vec3(4.0));
	weights /= max(dot(weights, vec3(1.0)), 0.001);
	float cliff = 1.0 - smoothstep(0.60, 0.92, normal.y);
	vec3 stone = study_tri(study_rock_color, p * 0.22, weights);
	float limestone = dot(stone, vec3(0.2126, 0.7152, 0.0722));
	stone = vec3(0.38, 0.40, 0.39) * (0.48 + limestone * 2.0);
	vec3 ground = texture(study_ground_color, p.xz * 1.4).rgb;
	vec3 moss = ground * vec3(0.48, 0.65, 0.34);
	vec3 palette = mix(moss, stone * vec3(1.12, 1.14, 1.12), cliff);
	color = mix(palette, color, cold);
	float r = mix(texture(study_ground_roughness, p.xz * 1.4).r,
	              study_tri(study_rock_roughness, p * 0.22, weights).r, cliff);
	roughness = mix(clamp(r, 0.5, 1.0), roughness, cold);
	vec2 nx = texture(study_rock_normal, p.yz * 0.22).xy * 2.0 - 1.0;
	vec2 ny = texture(study_rock_normal, p.xz * 0.22).xy * 2.0 - 1.0;
	vec2 nz = texture(study_rock_normal, p.xy * 0.22).xy * 2.0 - 1.0;
	vec3 rock_n = vec3(0.0, nx.x, nx.y) * weights.x
	            + vec3(ny.x, 0.0, ny.y) * weights.y
	            + vec3(nz.x, nz.y, 0.0) * weights.z;
	vec3 ground_n = texture(study_ground_normal, p.xz * 1.4).rgb * 2.0 - 1.0;
	// Tangentiale Störung statt einer zweiten Gelände- oder Wasseroberfläche.
	vec3 detail = mix(vec3(ground_n.x, 0.0, ground_n.y), rock_n, cliff);
	detail -= normal * dot(detail, normal);
	normal = normalize(normal + detail * 0.32 * (1.0 - cold));
}

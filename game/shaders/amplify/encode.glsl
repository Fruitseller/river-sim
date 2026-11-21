// Ausgabe der Verfeinerung in zwei Texturen:
//  - `dst_relief` (RGBA16F) im Vertrag der bisherigen Backtextur
//    (relief_bake.gdshader): R Höhenzuschlag, GB Steigungszuschlag dh/duv,
//    A Rinne (−) / Rippe (+), je mit Versatz 0,5. Terrain-Shader, Pinselkuppel,
//    Raycast und Kameraziel lesen sie unverändert.
//  - `dst_maps` (RGBA8) für das Material: R Abtrag, G Ablagerung, B Abfluss,
//    A Schutt (thermisch erhalten), je 0…1.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_offset;  // r Abweichung, g Maske
layout(set = 0, binding = 1) uniform sampler2D src_flux;
layout(set = 0, binding = 2) uniform sampler2D src_accum;
layout(set = 0, binding = 3, rgba16f) uniform writeonly image2D dst_relief;
layout(set = 0, binding = 4, rgba8) uniform writeonly image2D dst_maps;
layout(push_constant, std430) uniform Params {
	vec4 size;    // xy Größe, z Überhöhung, w Tiefe für volle Rinne/Rippe
	vec4 code;    // x Höhen-Code, y Steigungs-Code
	vec4 maps;    // x Abtrag-, y Ablagerungs-, z Schutt-Maß, w Abfluss-Sättigung
} pc;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(pc.size.xy);
	if (p.x >= size.x || p.y >= size.y) {
		return;
	}
	ivec2 hi = size - 1;
	vec2 o = texelFetch(src_offset, p, 0).rg;
	float l = texelFetch(src_offset, clamp(p - ivec2(1, 0), ivec2(0), hi), 0).r;
	float r = texelFetch(src_offset, clamp(p + ivec2(1, 0), ivec2(0), hi), 0).r;
	float d = texelFetch(src_offset, clamp(p - ivec2(0, 1), ivec2(0), hi), 0).r;
	float u = texelFetch(src_offset, clamp(p + ivec2(0, 1), ivec2(0), hi), 0).r;
	// Steigung in Sim-Höhe je UV, wie `coarse_slope` im Terrain-Shader.
	vec2 slope = vec2(r - l, u - d) * 0.5 * pc.size.x / pc.size.z;
	float cavity = clamp(o.r / pc.size.w, -1.0, 1.0);
	imageStore(dst_relief, p, vec4(o.r * pc.code.x + 0.5, slope * pc.code.y + 0.5, cavity * 0.5 + 0.5));

	vec4 acc = texelFetch(src_accum, p, 0);
	float stream = texelFetch(src_flux, p, 0).r;
	vec4 m = vec4(1.0 - exp(-acc.r / pc.maps.x), 1.0 - exp(-acc.g / pc.maps.y),
	              clamp(log2(1.0 + stream) / log2(1.0 + pc.maps.w), 0.0, 1.0),
	              1.0 - exp(-acc.b / pc.maps.z));
	imageStore(dst_maps, p, m * o.g);
}

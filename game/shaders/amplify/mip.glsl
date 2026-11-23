layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src;
layout(set = 0, binding = 1, FORMAT) uniform writeonly image2D dst;
layout(push_constant, std430) uniform Params {
	vec4 size;
} pc;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(pc.size.xy);
	if (p.x >= size.x || p.y >= size.y) {
		return;
	}
	imageStore(dst, p, textureLod(src, (vec2(p) + 0.5) / vec2(size), 0.0));
}

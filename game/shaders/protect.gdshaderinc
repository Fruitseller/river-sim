float protect_at(vec2 uv) {
	return textureLod(protect_tex, uv, 0.0).r;
}

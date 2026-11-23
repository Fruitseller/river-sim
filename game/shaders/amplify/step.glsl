// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Schott (MultiScaleErosion), angepasst; Lizenztext in NOTICE

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_height;
layout(set = 0, binding = 1) uniform sampler2D src_flux;
layout(set = 0, binding = 2, rg32f) uniform writeonly image2D dst_height;
layout(set = 0, binding = 3, rgba16f) uniform writeonly image2D dst_flux;
layout(set = 0, binding = 4, rgba16f) uniform image2D accum;
layout(push_constant, std430) uniform Params {
	vec4 size;
	vec4 ero;
	vec4 thermal;
	vec4 ero2;
	vec4 dep;
} pc;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(pc.size.xy);
	if (p.x >= size.x || p.y >= size.y) {
		return;
	}
	vec2 hc = texelFetch(src_height, p, 0).rg;
	vec4 fc = texelFetch(src_flux, p, 0);
	vec4 acc = imageLoad(accum, p);
	float h = hc.r;
	float dx = pc.size.z;
	float hard = acc.a;

	float stream = pc.size.w;
	float sed_in = 0.0;
	float out_sum = 0.0;
	float steepest = 0.0;
	float lowest = h;
	float th_in = 0.0;
	float th_out = 0.0;
	float h_sum = 0.0;
	float stream_sum = 0.0;
	float count = 0.0;
	for (int i = 0; i < 8; i++) {
		ivec2 q = p + NB[i];
		if (q.x < 0 || q.y < 0 || q.x >= size.x || q.y >= size.y) {
			continue;
		}
		vec2 hq = texelFetch(src_height, q, 0).rg;
		vec4 fq = texelFetch(src_flux, q, 0);
		float d = NB_DIST[i] * dx;
		h_sum += hq.r;
		stream_sum += fq.r;
		count += 1.0;
		float old_sl = (hq.g - hc.g) / d;
		if (old_sl > 0.0) {
			float w = pow(old_sl, pc.ero.z) * fq.g;
			stream += w * fq.r;
			sed_in += w * fq.b;
		}
		float sl = (hq.r - h) / d;
		float talus = max(pc.thermal.y, 0.5 * (fc.a + fq.a) * pc.ero2.x);
		if (sl > 0.0) {
			th_in += max(sl - talus, 0.0) * d;
		} else if (sl < 0.0) {
			float o = -sl;
			out_sum += pow(o, pc.ero.z);
			steepest = max(steepest, o);
			lowest = min(lowest, hq.r);
			th_out += max(o - talus, 0.0) * d;
		}
	}
	if (fc.g == 0.0) {
		stream = max(stream, fc.r);
	}
	stream = min(stream, STREAM_MAX);
	bool pit = out_sum <= 1e-4;
	float inv = pit ? 0.0 : 1.0 / out_sum;

	float speed = min(steepest * steepest, 1.0);
	float k = pc.ero.x * (1.0 + pc.ero.w * (0.5 - hard) * 2.0);
	float carve = mix(stream, stream_sum / max(count, 1.0), pc.thermal.w);
	float drop = max(h - lowest, 1e-7);
	float eroded = 0.5 * drop * (1.0 - exp(-2.0 * k * pow(carve, pc.ero.y) * speed / drop));
	float hn = h - eroded;
	hn += pc.dep.y * (h_sum / max(count, 1.0) - h);

	float th = pc.thermal.x * (th_in - th_out);
	hn += th;

	float sed = (fc.g == 0.0 ? fc.b : 0.0) + sed_in + eroded;
	float capacity = pc.dep.x * sqrt(stream) * speed;
	float deposit = min(max(sed - capacity, 0.0) * pc.dep.z, pc.dep.w * dx);
	hn += deposit;
	sed = min(sed - deposit, STREAM_MAX);

	imageStore(dst_height, p, vec4(hn, h, 0.0, 0.0));
	imageStore(dst_flux, p, vec4(stream, inv, sed, fc.a));
	imageStore(accum, p, vec4(acc.r + eroded, acc.g + deposit, acc.b + max(th, 0.0), hard));
}

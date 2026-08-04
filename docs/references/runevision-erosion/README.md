# Referenz: runevision-Erosionsfilter

`SimCore/Sources/SimCore/ErosionFilter.swift` ist ein Swift-Port des
Erosionsfilters von Rune Skovbo Johansen:

- Blog: https://blog.runevision.com/2026/03/fast-and-gorgeous-erosion-filter.html
- Video: https://www.youtube.com/watch?v=gsJHzBTPG0Y
- Shadertoy: https://www.shadertoy.com/view/wXcfWn

`shader_buffer_Buffer_A.glsl` ist der Original-GLSL-Quelltext des Filters
(Phacelle Noise + Erosion Filter, © 2025 Rune Skovbo Johansen,
[MPL-2.0](https://mozilla.org/MPL/2.0/)) als Lese-Referenz für den Port.

Die übrigen Tabs des Shadertoys (Common, Buffer B, Image — Rendering/Raymarching,
teils von anderen Shadertoys abgeleitet) sind hier bewusst **nicht** enthalten;
sie sind unter dem Shadertoy-Link einsehbar und für den Port irrelevant.

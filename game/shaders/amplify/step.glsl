// Ein Schritt der Nach-Erosion auf einer Stufe (Vorbild: Schott u. a. 2024,
// erosion.glsl / thermal.glsl / deposition.glsl, MIT): Abfluss sammeln,
// Stream-Power-Abtrag, thermischer Abtrag, Ablagerung. Ein Pass statt drei,
// damit ein Schritt nur EINE 3×3-Nachbarschaft liest.
//
// Abweichungen vom Vorbild:
//  - Der Abfluss verteilt sich nach den Höhen EINEN Schritt davor (Höhe.g),
//    deren Normierung jedes Texel selbst mitführt (Fluss.g). Das Vorbild
//    rechnet die Normierung jedes Nachbarn aus dessen 3×3 neu (25 Abgriffe
//    je Texel statt 9); mit der Normierung des Vorschritts auf den NEUEN
//    Höhen summieren die Anteile dagegen nicht zu eins, und der Abfluss
//    wächst auf Flächen unbegrenzt (gemessen: alles lief in die Schranke).
//  - Sediment ist das wirklich Abgetragene (s. Ablagerung unten).
//  - Thermisch als stetiger, paarweise erhaltender Ausgleich über dem
//    Schüttwinkel (je Paar derselbe) statt fester Quanten je Nachbar (die sind eine Sprungfunktion
//    des Eingangs, #238 verlangt kleine Änderung ein, kleine aus).
//  - Der Abtrag sättigt weich bei der halben Stufe zum tiefsten Nachbarn
//    (stetig) statt hart am steilsten Empfänger (springt, wenn der steilste
//    wechselt, und ebnet ein).
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_height;
layout(set = 0, binding = 1) uniform sampler2D src_flux;
layout(set = 0, binding = 2, rg32f) uniform writeonly image2D dst_height;
layout(set = 0, binding = 3, rgba16f) uniform writeonly image2D dst_flux;
layout(set = 0, binding = 4, rgba16f) uniform image2D accum;
layout(push_constant, std430) uniform Params {
	vec4 size;     // xy Größe, z Texelweite in Welteinheiten, w Eigenfläche
	vec4 ero;      // x Stärke, y Abfluss-Exponent, z Verteil-Exponent, w Härte-Hub
	vec4 thermal;  // x Rate, y Schüttwinkel (tan), z frei, w Abfluss-Mittelung
	vec4 ero2;     // x Schüttwinkel als Vielfaches des Sim-Gefälles
	vec4 dep;      // x Transportkraft, y Hangkriechen, z Rate, w Deckel je Schritt (Anteil der Texelweite)
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
	// Schüttwinkel: je härter, desto steiler, und nie flacher als die
	// Sim-Fläche selbst (mal `ero2.x`). Mit dem festen Winkel allein rutschten
	// die Steilwände der Sim über mehrere Zellen ab: das Gebirge wurde weich,
	// und am Wandfuß lief alles in die Schranke.
	// Schüttwinkel je PAAR aus den Werten beider Texel, damit der Ausgleich
	// erhält: was das eine abgibt, bekommt das andere. Nie flacher als die
	// Sim-Fläche selbst (mal `ero2.x`). Mit dem festen Winkel allein rutschten
	// die Steilwände der Sim über mehrere Zellen ab: das Gebirge wurde weich,
	// und am Wandfuß lief alles in die Schranke.

	float stream = pc.size.w;
	float sed_in = 0.0;
	float out_sum = 0.0;   // Σ Gefälle^p zu tieferen Nachbarn, auf den neuen Höhen
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
		// Zufluss nach den Höhen des Vorschritts, zu denen die Normierung
		// des Nachbarn gehört: die Anteile summieren exakt zu eins.
		float old_sl = (hq.g - hc.g) / d;
		if (old_sl > 0.0) {
			float w = pow(old_sl, pc.ero.z) * fq.g;
			stream += w * fq.r;
			sed_in += w * fq.b;
		}
		float sl = (hq.r - h) / d;   // > 0: Nachbar liegt höher
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
	// Am Anfang einer Stufe kennt noch kein Nachbar seine Normierung, der
	// Zufluss ist null: das Texel behält den Abfluss, den es von der gröberen
	// Stufe mitbringt, statt ihn mit der Eigenfläche zu überschreiben. Eine
	// Mulde hält ihren Stand genauso.
	if (fc.g == 0.0) {
		stream = max(stream, fc.r);
	}
	stream = min(stream, STREAM_MAX);
	// Unter dieser Summe gilt das Texel als Mulde (Halb-Float trägt den
	// Kehrwert sonst nicht).
	bool pit = out_sum <= 1e-4;
	float inv = pit ? 0.0 : 1.0 / out_sum;

	// Stream-Power-Abtrag, weiches Gestein trägt stärker ab.
	float speed = min(steepest * steepest, 1.0);
	float k = pc.ero.x * (1.0 + pc.ero.w * (0.5 - hard) * 2.0);
	// Weich gesättigt bei der halben Stufe zum tiefsten Nachbarn: mit dem
	// harten Deckel des Vorbilds (bis auf dessen Höhe) fiel ein Texel in
	// starken Rinnen je Schritt ganz hinunter; es entstanden Ebenen und ein
	// Schachbrett, weil der Abfluss auf Ebenen nicht eindeutig ist.
	// Der Abtrag liest den Abfluss über die 3×3-Nachbarschaft gemittelt
	// (`thermal.w`): ohne das wächst auf Diagonalhängen ein Riefenmuster von
	// einem Texel Breite, das Gitter statt Gelände zeigt.
	float carve = mix(stream, stream_sum / max(count, 1.0), pc.thermal.w);
	float drop = max(h - lowest, 1e-7);
	float eroded = 0.5 * drop * (1.0 - exp(-2.0 * k * pow(carve, pc.ero.y) * speed / drop));
	float hn = h - eroded;
	// Hangkriechen: schwacher Ausgleich zum Nachbarmittel.
	hn += pc.dep.y * (h_sum / max(count, 1.0) - h);

	// Thermisch: Material über dem Schüttwinkel rutscht zum Nachbarn.
	float th = pc.thermal.x * (th_in - th_out);
	hn += th;

	// Ablagerung: das Abgetragene wandert mit dem Abfluss und bleibt liegen,
	// wo die Transportkraft nachlässt (Hangfuß, Mulde). Das Vorbild speist
	// das Sediment frei aus der Transportkraft; in unseren Einheiten
	// (Welteinheit = 100 m) schüttete das je Schritt mehrere Meter auf.
	// Hier trägt der Abfluss nur, was oben abgetragen wurde, und je Schritt
	// bleibt höchstens `dep.w` der Texelweite liegen.
	float sed = (fc.g == 0.0 ? fc.b : 0.0) + sed_in + eroded;
	float capacity = pc.dep.x * sqrt(stream) * speed;
	float deposit = min(max(sed - capacity, 0.0) * pc.dep.z, pc.dep.w * dx);
	hn += deposit;
	sed = min(sed - deposit, STREAM_MAX);

	imageStore(dst_height, p, vec4(hn, h, 0.0, 0.0));
	imageStore(dst_flux, p, vec4(stream, inv, sed, fc.a));
	imageStore(accum, p, vec4(acc.r + eroded, acc.g + deposit, acc.b + max(th, 0.0), hard));
}

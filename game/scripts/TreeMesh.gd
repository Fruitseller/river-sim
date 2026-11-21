extends RefCounted
## Baum-Mesh des Einzelbaum-Walds (#236), im Code erzeugt (kein Asset).
##
## EIN Mesh trägt beide Arten: `VERTEX`/`NORMAL` sind der Nadelbaum, `CUSTOM0`/
## `CUSTOM1` (xyz) der Laubbaum mit derselben Topologie. `tree.gdshader` mischt
## je Instanz nach dem Nadelbaum-Anteil. Diese Mischform zeichnet den fernen
## Wald und die Schatten; wandert die Baumgrenze, verwandelt sich der Baum,
## statt umzuspringen.
##
## Höhe 1 (die Instanz skaliert), Stamm bis unter den Boden (sitzt auch am Hang
## und auf dem gröberen Render-Gitter auf). Kronen als Drehkörper mit
## `SEGMENTS` Segmenten: Nadelbaum in vier Etagen mit sternförmig
## hängenden Astspitzen, Laubbaum als gelappte Kuppel mit kurzem Stamm.
## Nahsicht: `build_conifer` (diese Lathe, feiner) und `build_broadleaf`
## (Krone aus Laubbüscheln, eigene Topologie).
## `build_shadow` ist die Mischform in grob (6 Segmente, 4 Ringe, 3 Stammseiten,
## 54 Dreiecke): ferne Bäume (rund 20 Bildpunkte und weniger) und die
## Schattenkarte, wo die Form nur als Umriss zählt.
## `COLOR.r` ist die Verschattung im Baum (unten und innen dunkler),
## `COLOR.g` 1 = Krone, 0 = Stamm.

const SEGMENTS := 8
const TRUNK_SIDES := 5

# Kronenprofile (Höhe, Radius) von unten nach oben, gleiche Ringzahl.
# Nadelbaum: Etagen-Unterkante (ungerade Indizes) weit und sternförmig.
const CONIFER := [
	Vector2(0.10, 0.05), Vector2(0.13, 0.27), Vector2(0.33, 0.10), Vector2(0.36, 0.22),
	Vector2(0.55, 0.08), Vector2(0.58, 0.16), Vector2(0.75, 0.05), Vector2(0.78, 0.10),
	Vector2(0.92, 0.03),
]
const CONIFER_TOP := 1.0
# Laubbaum: Kuppel, unten eingezogen; der Stamm ist bis 0,3 sichtbar.
const BROADLEAF := [
	Vector2(0.28, 0.06), Vector2(0.31, 0.25), Vector2(0.40, 0.37), Vector2(0.50, 0.42),
	Vector2(0.60, 0.42), Vector2(0.70, 0.38), Vector2(0.79, 0.31), Vector2(0.87, 0.21),
	Vector2(0.93, 0.10),
]
const BROADLEAF_TOP := 0.96
const TRUNK_BOTTOM := -0.25
const TRUNK_TOP := 0.34
const TRUNK_RADIUS := 0.035

## `segments` Segmente je Ring, `ring_ids` die verwendeten Profilringe (für
## das Schattenmodell eine grobe Auswahl), `trunk_sides` Stammseiten.
static func build(segments := SEGMENTS, ring_ids: Array = [], trunk_sides := TRUNK_SIDES) -> ArrayMesh:
	if ring_ids.is_empty():
		ring_ids = range(CONIFER.size())
	var con_p := PackedVector3Array()
	var dec_p := PackedVector3Array()
	var color := PackedColorArray()
	var idx := PackedInt32Array()
	# Erwartete Außennormale je Dreieck (nur für die Windungsrichtung).
	var outward: Array[Vector3] = []

	# Stamm: gleich für beide Arten.
	var trunk0 := con_p.size()
	for s in trunk_sides:
		var a := TAU * s / trunk_sides
		var d := Vector3(cos(a), 0.0, sin(a))
		for y in [TRUNK_BOTTOM, TRUNK_TOP]:
			var p: Vector3 = d * TRUNK_RADIUS * (1.0 if y < 0.0 else 0.7) + Vector3(0, y, 0)
			con_p.append(p)
			dec_p.append(p)
			color.append(Color(0.55 if y < 0.0 else 0.8, 0.0, 0.0))
	for s in trunk_sides:
		var t := (s + 1) % trunk_sides
		var a := TAU * (s + 0.5) / trunk_sides
		_quad(idx, outward, trunk0 + 2 * s, trunk0 + 2 * t, trunk0 + 2 * t + 1, trunk0 + 2 * s + 1,
			Vector3(cos(a), 0.0, sin(a)))

	# Krone: Boden-Mittelpunkt, Ringe, Spitze.
	var bottom := con_p.size()
	con_p.append(Vector3(0, CONIFER[ring_ids[0]].x, 0))
	dec_p.append(Vector3(0, BROADLEAF[ring_ids[0]].x, 0))
	color.append(Color(0.35, 1.0, 0.0))
	var ring0 := con_p.size()
	var rings := ring_ids.size()
	for ri in rings:
		var r: int = ring_ids[ri]
		var cp: Vector2 = CONIFER[r]
		var bp: Vector2 = BROADLEAF[r]
		var star := r % 2 == 1  # Etagen-Unterkante des Nadelbaums
		for s in segments:
			var a := TAU * s / segments + r * 0.37
			var d := Vector3(cos(a), 0.0, sin(a))
			var cr := cp.y * ((1.0 if s % 2 == 0 else 0.7) if star else 1.0)
			var cy := cp.x - (0.035 if star and s % 2 == 0 else 0.0)
			# Laubkrone gelappt: drei Beulen, je Ring gegeneinander gedreht.
			var br := bp.y * (1.0 + 0.16 * sin(3.0 * a + r * 1.3) + 0.06 * sin(5.0 * a - r))
			con_p.append(d * cr + Vector3(0, cy, 0))
			dec_p.append(d * br + Vector3(0, bp.x, 0))
			# Unten und in den Etagen-Kehlen dunkler, Spitze hell.
			var h := float(r) / float(CONIFER.size() - 1)
			var shade := lerpf(0.45, 1.0, h)
			if not star and r % 2 == 0 and r > 0:
				shade *= 0.8
			color.append(Color(shade, 1.0, 0.0))
	var apex := con_p.size()
	con_p.append(Vector3(0, CONIFER_TOP, 0))
	dec_p.append(Vector3(0, BROADLEAF_TOP, 0))
	color.append(Color(1.0, 1.0, 0.0))

	for s in segments:
		var t := (s + 1) % segments
		_tri(idx, outward, bottom, ring0 + t, ring0 + s, Vector3(0, -1, 0))
	for r in rings - 1:
		var a0 := ring0 + r * segments
		var a1 := a0 + segments
		for s in segments:
			var t := (s + 1) % segments
			var mid := (con_p[a0 + s] + con_p[a1 + t]) * 0.5
			var n := Vector3(mid.x, 0.0, mid.z).normalized()
			# Profil-Normale (dy, −dr): nach unten weisende Etagen-Unterseiten.
			var dr := Vector2(con_p[a1 + s].x, con_p[a1 + s].z).length() \
				- Vector2(con_p[a0 + s].x, con_p[a0 + s].z).length()
			var dy := con_p[a1 + s].y - con_p[a0 + s].y
			_quad(idx, outward, a0 + s, a0 + t, a1 + t, a1 + s, n * dy + Vector3(0, -dr, 0))
	var last := ring0 + (rings - 1) * segments
	for s in segments:
		var t := (s + 1) % segments
		_tri(idx, outward, last + s, last + t, apex, Vector3(con_p[last + s].x, 0.3, con_p[last + s].z))

	_orient(idx, con_p, outward)
	var con_n := _foliage_normals(con_p, idx, color, 0.55)
	var dec_n := _foliage_normals(dec_p, idx, color, 0.62)

	return _make_mesh(con_p, con_n, dec_p, dec_n, color, idx)

## ArrayMesh aus beiden Formen (Nadelbaum in VERTEX/NORMAL, Laubbaum in
## CUSTOM0/CUSTOM1).
static func _make_mesh(con_p: PackedVector3Array, con_n: PackedVector3Array,
		dec_p: PackedVector3Array, dec_n: PackedVector3Array, color: PackedColorArray,
		idx: PackedInt32Array) -> ArrayMesh:
	var custom0 := PackedFloat32Array()
	var custom1 := PackedFloat32Array()
	for i in dec_p.size():
		custom0.append_array([dec_p[i].x, dec_p[i].y, dec_p[i].z, 0.0])
		custom1.append_array([dec_n[i].x, dec_n[i].y, dec_n[i].z, 0.0])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = con_p
	arrays[Mesh.ARRAY_NORMAL] = con_n
	arrays[Mesh.ARRAY_COLOR] = color
	arrays[Mesh.ARRAY_CUSTOM0] = custom0
	arrays[Mesh.ARRAY_CUSTOM1] = custom1
	arrays[Mesh.ARRAY_INDEX] = idx
	var fmt := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, fmt)
	mesh.custom_aabb = AABB(Vector3(-0.6, TRUNK_BOTTOM, -0.6), Vector3(1.2, 1.1 - TRUNK_BOTTOM, 1.2))
	return mesh

## Laubbaum der Nahsicht: Stamm und eine Krone aus BLOBS Laubbüscheln
## (Ikosaeder, einmal unterteilt, leicht verbeult). Eigene Topologie, also
## keine Mischform: CUSTOM0/1 tragen dieselbe Form wie VERTEX/NORMAL.
const BLOBS := [
	# Mitte (x, y, z), Radius — Höhe 1 wie die Lathe-Formen.
	[Vector3(0.00, 0.64, 0.00), 0.26], [Vector3(0.17, 0.53, 0.06), 0.20],
	[Vector3(-0.15, 0.56, -0.08), 0.21], [Vector3(0.03, 0.80, -0.04), 0.18],
	[Vector3(-0.05, 0.50, 0.18), 0.18], [Vector3(0.10, 0.70, -0.16), 0.17],
]

static func build_broadleaf() -> ArrayMesh:
	var p := PackedVector3Array()
	var color := PackedColorArray()
	var idx := PackedInt32Array()
	var outward: Array[Vector3] = []
	# Stamm, oben in die Krone hinein.
	for s in TRUNK_SIDES:
		var a := TAU * s / TRUNK_SIDES
		var d := Vector3(cos(a), 0.0, sin(a))
		p.append(d * TRUNK_RADIUS * 1.1 + Vector3(0, TRUNK_BOTTOM, 0))
		p.append(d * TRUNK_RADIUS * 0.6 + Vector3(0, 0.55, 0))
		color.append(Color(0.55, 0.0, 0.0))
		color.append(Color(0.8, 0.0, 0.0))
	for s in TRUNK_SIDES:
		var t := (s + 1) % TRUNK_SIDES
		var a := TAU * (s + 0.5) / TRUNK_SIDES
		_quad(idx, outward, 2 * s, 2 * t, 2 * t + 1, 2 * s + 1, Vector3(cos(a), 0.0, sin(a)))
	var ico := _icosphere()
	var verts: PackedVector3Array = ico[0]
	var faces: PackedInt32Array = ico[1]
	var crown_lo := 0.30
	var crown_hi := 0.98
	for b in BLOBS.size():
		var c: Vector3 = BLOBS[b][0]
		var r: float = BLOBS[b][1]
		var first := p.size()
		for v in verts:
			# Verbeulung: zwei Sinus-Lagen je Büschel verdreht.
			var bump := 1.0 + 0.12 * sin(5.0 * v.x + 3.0 * v.z + b * 1.7) \
				+ 0.08 * sin(7.0 * v.y - 4.0 * v.x + b)
			var q := c + v * r * bump
			p.append(q)
			# Unten und zur Stammachse dunkler (Selbstschatten der Krone).
			var h := clampf((q.y - crown_lo) / (crown_hi - crown_lo), 0.0, 1.0)
			var outer := clampf(0.5 + 0.5 * Vector2(q.x, q.z).normalized().dot(Vector2(v.x, v.z)), 0.0, 1.0)
			color.append(Color(lerpf(0.4, 1.0, h) * lerpf(0.75, 1.0, outer), 1.0, 0.0))
		for f in faces.size() / 3:
			var a := first + faces[3 * f]
			var bb := first + faces[3 * f + 1]
			var cc := first + faces[3 * f + 2]
			_tri(idx, outward, a, bb, cc, (p[a] + p[bb] + p[cc]) / 3.0 - c)
	_orient(idx, p, outward)
	var n := _foliage_normals(p, idx, color, 0.5)
	return _make_mesh(p, n, p, n, color, idx)

## Ikosaeder, einmal unterteilt (42 Ecken, 80 Dreiecke), Einheitskugel.
static func _icosphere() -> Array:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var v: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	for i in v.size():
		v[i] = v[i].normalized()
	var f := PackedInt32Array([0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
		1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
		4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1])
	var mid := {}
	var out := PackedInt32Array()
	for k in f.size() / 3:
		var a := f[3 * k]
		var b := f[3 * k + 1]
		var c := f[3 * k + 2]
		var ab := _midpoint(v, mid, a, b)
		var bc := _midpoint(v, mid, b, c)
		var ca := _midpoint(v, mid, c, a)
		out.append_array([a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca])
	return [PackedVector3Array(v), out]

# Array statt PackedVector3Array: Packed-Arrays kämen hier als Kopie an.
static func _midpoint(v: Array[Vector3], mid: Dictionary, a: int, b: int) -> int:
	var key := Vector2i(mini(a, b), maxi(a, b))
	if not mid.has(key):
		v.append(((v[a] + v[b]) * 0.5).normalized())
		mid[key] = v.size() - 1
	return mid[key]

static func _tri(idx: PackedInt32Array, outward: Array[Vector3], a: int, b: int, c: int,
		n: Vector3) -> void:
	idx.append_array([a, b, c])
	outward.append(n)

static func _quad(idx: PackedInt32Array, outward: Array[Vector3], a: int, b: int, c: int,
		d: int, n: Vector3) -> void:
	_tri(idx, outward, a, b, c, n)
	_tri(idx, outward, a, c, d, n)

## Godot zeichnet im Uhrzeigersinn gewundene Dreiecke als Vorderseite: das
## Kreuzprodukt (b − a) × (c − a) zeigt dann ins Innere.
static func _orient(idx: PackedInt32Array, p: PackedVector3Array, outward: Array[Vector3]) -> void:
	for t in outward.size():
		var a := p[idx[3 * t]]
		var b := p[idx[3 * t + 1]]
		var c := p[idx[3 * t + 2]]
		if (b - a).cross(c - a).dot(outward[t]) > 0.0:
			var tmp := idx[3 * t + 1]
			idx[3 * t + 1] = idx[3 * t + 2]
			idx[3 * t + 2] = tmp

## Glatte Normalen, für das Laub zur Kronenmitte hin aufgeweicht: das Licht
## fällt dann wie auf eine Laubwolke statt auf Facetten.
static func _foliage_normals(p: PackedVector3Array, idx: PackedInt32Array,
		color: PackedColorArray, soften: float) -> PackedVector3Array:
	var n := PackedVector3Array()
	n.resize(p.size())
	for t in idx.size() / 3:
		var a := p[idx[3 * t]]
		var b := p[idx[3 * t + 1]]
		var c := p[idx[3 * t + 2]]
		# Kreuzprodukt zeigt nach innen (s. _orient), also umdrehen.
		var fn := -(b - a).cross(c - a)
		for k in 3:
			n[idx[3 * t + k]] += fn
	var centre := Vector3(0, 0.55, 0)
	for i in p.size():
		var g := n[i].normalized()
		if color[i].g > 0.5:
			var radial := (p[i] - centre).normalized()
			g = g.lerp(radial, soften).normalized()
		n[i] = g
	return n

static func build_shadow() -> ArrayMesh:
	return build(6, [1, 3, 5, 7], 3)

## Nadelbaum der Nahsicht: alle Ringe, 10 Segmente.
static func build_conifer() -> ArrayMesh:
	return build(10)

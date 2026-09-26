extends RefCounted
## Eigene Studien-Geometrie, reproduzierbar ohne DCC-Datei oder Fremdmodell.
## Kronen bestehen aus überlappenden, unregelmäßigen Astgruppen in einer Surface.

static func tree(variant: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 116 + variant
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := 15 if variant == 0 else 11
	for lobe in count:
		var t := float(lobe) / count
		var angle := lobe * 2.39996
		var spread := 0.37 * sin(t * PI) if variant == 0 else 0.33 * (1.0 - t)
		var center := Vector3(cos(angle) * spread, 0.55 + t * 0.92, sin(angle) * spread)
		var radius := Vector3(0.26, 0.28, 0.26) * rng.randf_range(0.8, 1.2)
		if variant == 1:
			radius = Vector3(0.32 * (1.0 - t) + 0.04, 0.19, 0.32 * (1.0 - t) + 0.04)
		elif variant == 2:
			center *= 0.45
			radius *= 0.6
		var c := Color(0.16, 0.25, 0.085).lerp(Color(0.34, 0.42, 0.16), rng.randf())
		_ellipsoid(st, center, radius, c, lobe)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.92
	st.set_material(mat)
	var mesh := st.commit()
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.018
	trunk.bottom_radius = 0.055
	trunk.height = 0.9 if variant != 2 else 0.3
	trunk.radial_segments = 5
	trunk.rings = 1
	var bark := StandardMaterial3D.new()
	bark.albedo_color = Color(0.19, 0.16, 0.12)
	bark.roughness = 1.0
	var arrays := trunk.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i].y += trunk.height * 0.5
	arrays[Mesh.ARRAY_VERTEX] = verts
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(1, bark)
	return mesh

static func _ellipsoid(st: SurfaceTool, center: Vector3, radius: Vector3, color: Color, salt: int) -> void:
	for ring in 5:
		for segment in 8:
			var points: Array[Vector3] = []
			for corner in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1)]:
				var phi := float(ring + corner.x) / 5.0 * PI
				var theta := float(segment + corner.y) / 8.0 * TAU
				var normal := Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
				var irregular := 1.0 + 0.16 * sin(theta * 3.0 + phi * 5.0 + salt)
				points.append(normal * radius * irregular)
			for idx in [0, 1, 2, 0, 2, 3]:
				st.set_normal(points[idx].normalized())
				st.set_color(color * (0.82 + 0.18 * float(ring % 2)))
				st.set_uv(Vector2.ZERO)
				st.add_vertex(center + points[idx])

static func rock() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Ein zusammenhängender gebrochener Block, keine gestapelten Kugeln.
	var rings: Array[PackedVector3Array] = []
	for level in 4:
		var ring := PackedVector3Array()
		for segment in 8:
			var theta := float(segment) / 8.0 * TAU
			var radius := 0.9 - float(level) * 0.14 + 0.08 * sin(segment * 3.7)
			ring.append(Vector3(cos(theta) * radius + level * 0.08,
				level * 0.45 + 0.07 * sin(segment * 2.1), sin(theta) * radius * 0.7))
		rings.append(ring)
	for level in 3:
		for segment in 8:
			var next := (segment + 1) % 8
			_triangle(st, rings[level][segment], rings[level + 1][segment], rings[level + 1][next])
			_triangle(st, rings[level][segment], rings[level + 1][next], rings[level][next])
	for segment in 8:
		_triangle(st, rings[3][segment], rings[3][(segment + 1) % 8], Vector3(0.24, 1.38, 0))
		_triangle(st, rings[0][segment], Vector3.ZERO, rings[0][(segment + 1) % 8])
	var mat := ShaderMaterial.new()
	mat.shader = load("res://studies/flusstal/rock.gdshader")
	for channel in ["color", "normal", "roughness"]:
		mat.set_shader_parameter("study_rock_" + channel,
			load("res://studies/flusstal/assets/rock_" + channel + ".jpg"))
		mat.set_shader_parameter("study_ground_" + channel,
			load("res://studies/flusstal/assets/ground_" + channel + ".jpg"))
	st.set_material(mat)
	return st.commit()

static func _triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var normal := (b - a).cross(c - a).normalized()
	for p in [a, c, b]:
		st.set_normal(normal)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(p)

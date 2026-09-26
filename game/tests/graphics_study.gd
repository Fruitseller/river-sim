extends SceneTree
## Kleine Verhaltenswächter für #116, ohne Weltgenerierung oder Messlauf.

var failures := 0

func _initialize() -> void:
	var study = load("res://studies/flusstal/Flusstal.gd").new()
	study.N = 16
	study.half = 8.0
	study.step = 1.0
	study.sea = 0.0
	study.h_cache.resize(256)
	study.h_cache.fill(1.0)
	study.h_cache_dirty = false
	var raster := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	raster.fill(Color(0, 0, 0.5, 0.5))
	study.water_field._img = raster
	_check(study._dry_footprint(Vector2.ZERO, 0.5, raster), "Trockenes Land muss bebaubar sein")
	raster.set_pixel(8, 8, Color.RED)
	_check(not study._dry_footprint(Vector2.ZERO, 0.5, raster), "Raster-Fluss muss frei bleiben")
	raster.set_pixel(8, 8, Color.GREEN)
	_check(not study._dry_footprint(Vector2.ZERO, 0.5, raster), "See muss frei bleiben")
	raster.set_pixel(8, 8, Color(0, 0, 0.5, 0.5))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-1, 1, -1), Vector3(1, 1, -1), Vector3(0, 1, 1)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	study.river_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mask: Image = study._placement_water()
	_check(not study._dry_footprint(Vector2.ZERO, 0.5, mask), "Band ohne Rasterwasser muss frei bleiben")
	_check(raster.get_pixel(8, 8).r == 0.0, "Platzierung darf das Render-Wasserfeld nicht ändern")
	_check(not study._dry_footprint(Vector2(8, 8), 1.0, mask), "Weltgrenze muss frei bleiben")
	study.h_cache.fill(0.0)
	_check(not study._dry_footprint(Vector2(-4, -4), 0.5, raster), "Meer muss frei bleiben")
	var meshes = load("res://studies/flusstal/StudyMeshes.gd")
	var rock: ArrayMesh = meshes.rock()
	var geometry := rock.surface_get_arrays(0)
	var vertices: PackedVector3Array = geometry[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = geometry[Mesh.ARRAY_NORMAL]
	for i in range(0, vertices.size(), 3):
		var clockwise := (vertices[i + 2] - vertices[i]).cross(vertices[i + 1] - vertices[i])
		_check(clockwise.dot(normals[i]) > 0.0, "Fels-Normale muss zur Godot-Frontseite zeigen")
	_check(vertices == meshes.rock().surface_get_arrays(0)[Mesh.ARRAY_VERTEX], "Felsen müssen reproduzierbar sein")
	study.free()
	if failures > 0:
		quit(1)
		return
	print("GRAPHICS_STUDY_OK")
	quit(0)

func _check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		print("FAIL: ", message)

extends SceneTree
## Headless-Wächter für die Terrain-Kacheln (Issue #235):
##   godot --headless --path game --script res://tests/terrain_tiles.gd
##
## Braucht die GDExtension nicht. Geprüft wird der Flächen-Vertrag von
## scripts/TerrainTiles.gd, auf dem die Flussbänder stehen (sie nehmen ihre
## Höhen von genau dieser Fläche, SimRender `renderSurfaceHeight`):
##  - die Kacheln zusammen bilden dieselbe Dreiecksmenge wie das frühere
##    PlaneMesh (gleiche Punkte, Teilung entlang der Anti-Diagonale), auch mit
##    schmaler letzter Kachel;
##  - die Zahl der Quads ist (grid − 1)², keine Lücke, keine Doppelung;
##  - jede Kachel-AABB enthält alle ihre Vertices (sonst cullt Godot eine
##    sichtbare Kachel), auch bei Dichte 2 und 4;
##  - eine explizit gesetzte Kachelgröße gewinnt gegen `RS_TILE_QUADS`.

const TerrainTiles = preload("res://scripts/TerrainTiles.gd")
var failures := 0

func _init() -> void:
	# Kleine Gitter mit voller, schmaler und einzelner letzter Kachel.
	for case in [[5, 4], [9, 4], [20, 4], [37, 8]]:
		_check_against_plane_mesh(case[0], case[1])
	_check_aabb_and_density()
	if failures > 0:
		quit(1)
		return
	print("TERRAIN_TILES_OK")
	quit(0)

func _check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		print("FAIL: ", message)

func _build(grid: int, quads: int) -> Node3D:
	var t: Node3D = TerrainTiles.new()
	t.tile_quads = quads
	root.add_child(t)
	t.build(8.0, grid, StandardMaterial3D.new(), -1.0, 1.0)
	return t

## Dreiecke als Menge sortierter Eckpunkt-Schlüssel in Gitterindizes (das
## PlaneMesh summiert seine Positionen schrittweise auf, die Kacheln rechnen
## sie exakt; auf Weltkoordinaten unterschieden sie sich in der 4. Stelle).
static func _triangles(arrays: Array, out: Dictionary, grid: int) -> int:
	var cell := 8.0 / float(grid - 1)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var ix: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	@warning_ignore("integer_division")
	var n := ix.size() / 3
	for t in n:
		var pts := []
		for c in 3:
			var p := v[ix[t * 3 + c]]
			pts.append("%d,%d" % [roundi((p.x + 4.0) / cell), roundi((p.z + 4.0) / cell)])
		pts.sort()
		out[" ".join(pts)] = true
	return n

func _check_against_plane_mesh(grid: int, quads: int) -> void:
	var pm := PlaneMesh.new()
	pm.size = Vector2(8.0, 8.0)
	pm.subdivide_width = grid - 2
	pm.subdivide_depth = grid - 2
	var plane := {}
	_triangles(pm.get_mesh_arrays(), plane, grid)
	var t := _build(grid, quads)
	_check(t.tile_quads == quads, "explizite Kachelgröße %d muss gelten" % quads)
	var tiles := {}
	var count := 0
	for mi: MeshInstance3D in t.instances:
		count += _triangles(mi.mesh.surface_get_arrays(0), tiles, grid)
	_check(count == 2 * (grid - 1) * (grid - 1),
		"Gitter %d: %d Dreiecke statt %d (Lücke oder Doppelung)" % [grid, count, 2 * (grid - 1) * (grid - 1)])
	var missing := 0
	for k in plane:
		if not tiles.has(k):
			missing += 1
	_check(missing == 0 and tiles.size() == plane.size(),
		"Gitter %d: Kacheln weichen vom PlaneMesh ab (%d fehlen, %d statt %d)"
		% [grid, missing, tiles.size(), plane.size()])
	t.free()

func _check_aabb_and_density() -> void:
	var t := _build(20, 4)
	for d in [1, 2, 4]:
		for tile in t.tile_count():
			t.set_density(tile, d)
			var box: AABB = t.tile_aabb(tile).grow(1e-4)
			var v: PackedVector3Array = t.instances[tile].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			var r: Rect2i = t.tile_range(tile)
			_check(v.size() == (r.size.x * d + 1) * (r.size.y * d + 1),
				"Kachel %d, Dichte %d: falsche Vertexzahl" % [tile, d])
			for p in v:
				if not box.has_point(Vector3(p.x, (t.y_lo + t.y_hi) * 0.5, p.z)):
					_check(false, "Kachel %d, Dichte %d: Vertex %s außerhalb der AABB" % [tile, d, p])
					break
			_check(t.instances[tile].mesh.custom_aabb.is_equal_approx(t.tile_aabb(tile)),
				"Kachel %d: Mesh-AABB ist nicht die Kachel-AABB" % tile)
	t.free()

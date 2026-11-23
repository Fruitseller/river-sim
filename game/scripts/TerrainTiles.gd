extends Node3D

const TILE_QUADS := 64
var tile_quads := TILE_QUADS

func _init() -> void:
	if OS.get_environment("RS_TILE_QUADS").is_valid_int():
		tile_quads = maxi(8, OS.get_environment("RS_TILE_QUADS").to_int())
const MAX_DENSITY := 4

var world_size := 0.0
var grid := 0
var tiles_per_side := 0
var tile_density: PackedInt32Array = []
var instances: Array[MeshInstance3D] = []
var material: Material
var y_lo := -2.0
var y_hi := 40.0

func build(world: float, grid_points: int, mat: Material, aabb_y_lo: float, aabb_y_hi: float) -> void:
	world_size = world
	grid = grid_points
	material = mat
	y_lo = aabb_y_lo
	y_hi = aabb_y_hi
	for mi in instances:
		mi.queue_free()
	instances.clear()
	tiles_per_side = ceili(float(grid - 1) / tile_quads)
	tile_density.resize(tiles_per_side * tiles_per_side)
	tile_density.fill(1)
	for tz in tiles_per_side:
		for tx in tiles_per_side:
			var mi := MeshInstance3D.new()
			mi.name = "Tile_%d_%d" % [tx, tz]
			mi.material_override = material
			add_child(mi)
			instances.append(mi)
			_rebuild(tz * tiles_per_side + tx)

func tile_count() -> int:
	return instances.size()

func tile_index(tx: int, tz: int) -> int:
	return tz * tiles_per_side + tx

@warning_ignore("integer_division")
func tile_range(tile: int) -> Rect2i:
	var tx := tile % tiles_per_side
	var tz := tile / tiles_per_side
	var x0 := tx * tile_quads
	var z0 := tz * tile_quads
	var x1 := mini(x0 + tile_quads, grid - 1)
	var z1 := mini(z0 + tile_quads, grid - 1)
	return Rect2i(x0, z0, x1 - x0, z1 - z0)

func set_density(tile: int, density: int) -> void:
	density = clampi(density, 1, MAX_DENSITY)
	if tile_density[tile] == density:
		return
	tile_density[tile] = density
	_rebuild(tile)

func density(tile: int) -> int:
	return tile_density[tile]

func tile_aabb(tile: int) -> AABB:
	var r := tile_range(tile)
	var step := world_size / float(grid - 1)
	var half := world_size * 0.5
	return AABB(Vector3(-half + r.position.x * step, y_lo, -half + r.position.y * step),
		Vector3(r.size.x * step, y_hi - y_lo, r.size.y * step))

func _rebuild(tile: int) -> void:
	instances[tile].mesh = _grid_mesh(tile, tile_density[tile])

func _grid_mesh(tile: int, d: int) -> ArrayMesh:
	var r := tile_range(tile)
	var cell := world_size / float(grid - 1)
	var half := world_size * 0.5
	var xs := _axis(r.position.x, r.size.x, d)
	var zs := _axis(r.position.y, r.size.y, d)
	var w := xs.size() - 1
	var h := zs.size() - 1
	var verts := PackedVector3Array()
	verts.resize((w + 1) * (h + 1))
	var k := 0
	for j in h + 1:
		var z := -half + zs[j] * cell
		for i in w + 1:
			verts[k] = Vector3(-half + xs[i] * cell, 0.0, z)
			k += 1
	var idx := PackedInt32Array()
	idx.resize(w * h * 6)
	k = 0
	for j in range(h, 0, -1):
		var prevrow := (j - 1) * (w + 1)
		var thisrow := j * (w + 1)
		for i in range(w, 0, -1):
			idx[k] = prevrow + i
			idx[k + 1] = thisrow + i
			idx[k + 2] = thisrow + i - 1
			idx[k + 3] = prevrow + i - 1
			idx[k + 4] = prevrow + i
			idx[k + 5] = thisrow + i - 1
			k += 6
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.custom_aabb = tile_aabb(tile)
	return mesh

static func _axis(start: int, quads: int, d: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for q in quads * d:
		out.append(start + float(q) / d)
	out.append(start + quads)
	return out

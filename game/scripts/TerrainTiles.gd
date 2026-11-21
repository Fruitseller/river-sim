extends Node3D
## Terrain in Kacheln (#235): ersetzt das eine PlaneMesh über die ganze Insel.
##
## Jede Kachel ist eine eigene MeshInstance3D mit eigener AABB, damit Godot im
## Hauptpass und in jeder Schattenkaskade nur zeichnet, was im Frustum liegt.
## Vorher schaltete `extra_cull_margin = 1000` das Culling ab. Gemessen sind
## die Kacheln leistungsneutral (±0,7 ms, docs/perf-measurements.md § V): Die
## Bildzeit folgt den Pixeln, nicht den Vertices. Sie sind die Struktur für
## Objekte je Kachel (#236) und dichtere Kacheln nahe der Kamera (#238).
##
## Vertrag mit dem Rest (gilt für jede Kachel, damit Shader, Bänder und
## Raycast nichts von den Kacheln wissen müssen):
## - Vertices liegen in WELTkoordinaten (die Instanz steht im Ursprung). Der
##   Terrain-Vertex-Shader leitet seine UV wie bisher aus `VERTEX.xz` ab
##   (`world_uv`), er sieht keinen Unterschied zum PlaneMesh.
## - Bei Dichte 1 liegen die Vertices genau auf den Punkten des Render-Gitters
##   (`grid` Punkte je Seite, Abstand world_size / (grid − 1)), und jedes Quad
##   ist entlang der Anti-Diagonale geteilt wie Godots PlaneMesh. Die sichtbare
##   Fläche ist damit dieselbe wie vorher, und die Bänder, die ihre Höhen von
##   genau dieser Fläche nehmen (`sim.setRenderGrid`,
##   `RenderSupport.renderSurfaceHeight`), liegen weiter richtig.
## - Benachbarte Kacheln teilen ihre Randpunkte: keine Risse.
##
## Vorbereitung für #238 (Gelände-Verfeinerung): `set_density(tile, d)` baut
## eine Kachel mit d Vertices je Gitterabstand neu (d = 1, 2 oder 4). Die
## Randpunkte einer dichteren Kachel enthalten alle Punkte der Nachbarn; damit
## an der Grenze keine T-Fugen entstehen, muss der Verfeinerer am Rand auf die
## gröbere Nachbarfläche zurückfallen (Verschiebung am Rand null). Dichte > 1
## bricht den Bänder-Vertrag oben und gehört deshalb zur Verfeinerung selbst.

## Gitterabstände je Kachelseite. 64 ergibt bei 720 Punkten 12 × 12 Kacheln;
## die letzte Reihe ist schmaler (719 = 11 · 64 + 15). Kleiner heißt feineres
## Culling, aber mehr Zeichenaufrufe (je Kachel einer im Tiefen-Vorpass, einer
## im Hauptpass und einer je Kaskade, in der sie liegt); in der Totalen kosten
## die 144 Kacheln gemessen rund 0,4 ms. 64 statt 128, damit #238 die Dichte
## nahe der Kamera in kleinen Schritten heben kann.
const TILE_QUADS := 64
var tile_quads := TILE_QUADS
const MAX_DENSITY := 4

var world_size := 0.0
var grid := 0
var tiles_per_side := 0
var tile_density: PackedInt32Array = []
var instances: Array[MeshInstance3D] = []
var material: Material
## Höhenbereich der AABB in Welt-Y. Konservativ über die ganze Welt statt je
## Kachel: Gecullt wird vor allem nach x/z, und eine zu flache AABB ließe eine
## sichtbare Kachel verschwinden.
var y_lo := -2.0
var y_hi := 40.0

## Kacheln für ein Render-Gitter mit `grid_points` Punkten je Seite bauen.
func build(world: float, grid_points: int, mat: Material, aabb_y_lo: float, aabb_y_hi: float) -> void:
	world_size = world
	grid = grid_points
	material = mat
	y_lo = aabb_y_lo
	y_hi = aabb_y_hi
	for mi in instances:
		mi.queue_free()
	instances.clear()
	if OS.get_environment("RS_TILE_QUADS").is_valid_int(): # A/B ohne Umbau
		tile_quads = maxi(8, OS.get_environment("RS_TILE_QUADS").to_int())
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

## Zahl der Kacheln.
func tile_count() -> int:
	return instances.size()

## Kachel-Index aus Kachel-Koordinaten.
func tile_index(tx: int, tz: int) -> int:
	return tz * tiles_per_side + tx

## Gitterbereich einer Kachel: [x0, x1] × [z0, z1] in Render-Gitter-Punkten,
## beide Enden eingeschlossen (Nachbarn teilen den Rand).
@warning_ignore("integer_division")
func tile_range(tile: int) -> Rect2i:
	var tx := tile % tiles_per_side
	var tz := tile / tiles_per_side
	var x0 := tx * tile_quads
	var z0 := tz * tile_quads
	var x1 := mini(x0 + tile_quads, grid - 1)
	var z1 := mini(z0 + tile_quads, grid - 1)
	return Rect2i(x0, z0, x1 - x0, z1 - z0)

## Vertex-Dichte einer Kachel (1, 2 oder 4 Vertices je Gitterabstand).
func set_density(tile: int, density: int) -> void:
	density = clampi(density, 1, MAX_DENSITY)
	if tile_density[tile] == density:
		return
	tile_density[tile] = density
	_rebuild(tile)

func density(tile: int) -> int:
	return tile_density[tile]

## Welt-AABB einer Kachel (die Instanz steht im Ursprung).
func tile_aabb(tile: int) -> AABB:
	var r := tile_range(tile)
	var step := world_size / float(grid - 1)
	var half := world_size * 0.5
	return AABB(Vector3(-half + r.position.x * step, y_lo, -half + r.position.y * step),
		Vector3(r.size.x * step, y_hi - y_lo, r.size.y * step))

func _rebuild(tile: int) -> void:
	instances[tile].mesh = _grid_mesh(tile, tile_density[tile])

## Gitter-Mesh einer Kachel mit `d` Vertices je Gitterabstand.
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
	# Dreiecke in der Reihenfolge des alten PlaneMesh: von +z nach −z, in
	# jeder Zeile von +x nach −x (PlaneMesh legt seine Punkte gespiegelt an).
	# Die Reihenfolge kostet messbar: in der Gegenrichtung lag dieselbe Kachel
	# in `diorama` bei 3456×2104 um 0,9 ms über dem PlaneMesh, so herum gleich
	# (docs/perf-measurements.md § V).
	k = 0
	for j in range(h, 0, -1):
		var prevrow := (j - 1) * (w + 1)
		var thisrow := j * (w + 1)
		for i in range(w, 0, -1):
			# Wie PlaneMesh: Teilung entlang der Anti-Diagonale (prevrow+i ↔
			# thisrow+i−1), s. RenderSupport.renderSurfaceHeight.
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

## Gitterkoordinaten (in Render-Gitter-Abständen, auch gebrochen) entlang
## einer Kachelachse ab `start` über `quads` Abstände. Der letzte Punkt ist
## immer genau `start + quads`: Nachbarn teilen ihn exakt.
static func _axis(start: int, quads: int, d: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for q in quads * d:
		out.append(start + float(q) / d)
	out.append(start + quads)
	return out

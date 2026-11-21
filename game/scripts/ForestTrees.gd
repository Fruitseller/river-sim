extends Node3D
## Wald aus Einzelbäumen (#236). Nimmt die Entscheidung aus #152 zurück,
## Instanzbäume abzuschaffen; das Kronendach im Terrain-Shader bleibt als
## Waldboden (`tree_instances` dort).
##
## GPU-getrieben wie die Vegetation in Horizon Zero Dawn: ein Compute-Pass
## (`tree_place.glsl`) geht jedes Bild ein festes, verwackeltes Gitter je
## Stufe um die Kamera ab, liest Höhe, Verschiebung und Waldmaske aus
## denselben Texturen wie das Terrain-Material und schreibt nur die Bäume, die
## gerade stehen und zu sehen sind, in vier indirekte MultiMeshes (Nadel-
## und Laubbaum in voller Form nah, grobe Mischform fern und nur für die
## Schattenkarte). Die CPU
## schreibt keinen Transform; sie startet den Pass mit Kamera und Blenden. Im
## Zeitraffer lädt sie weiter nur die Waldmaske hoch (Main).
##
## Warum nicht Kacheln mit festen Instanzen (der erste Wurf, gemessen in
## docs/graphics-quality.md § Einzelbäume): jede Instanz kostet dort ihren
## Vertex-Shader, auch wenn ihr Baum gerade ausgedünnt oder ohne Wald ist. In
## `nah` waren das 42 Mio. Primitive im Hauptpass für rund 20.000 sichtbare
## Bäume, mit Schatten 134 Mio. Der Compute-Pass verwirft solche Bäume, bevor
## sie gezeichnet werden, und cullt gegen das Kamera-Frustum.
##
## Kartensymbol: die Baumgröße wächst mit dem Abstand d zur Kamera,
## k(d) = K_NEAR · (d / D_NEAR)^K_EXP (1 … K_MAX). Damit der Wald gleich dicht
## wirkt, dünnt er mit 1/k^THIN_EXP aus: jeder Baum hat einen Rang und
## schrumpft weg, sobald Rang · k^THIN_EXP gegen 1 geht. Stufe L trägt die Ränge
## [2^−(L+1), 2^−L) (die letzte [0, 2^−L)) mit dem Gitterabstand
## `BASE_SPACING · 2^((L+1)/2)`; ab `level_range(L)` zeigt sie keinen Baum mehr,
## dort endet ihr Fenster.
##
## Ohne RenderingDevice (Compatibility-Renderer, headless) gibt es keine
## Einzelbäume: `available()` ist falsch, Main zeigt das Kronendach von #152.

const TreeMesh = preload("res://scripts/TreeMesh.gd")
const SHADER := "res://shaders/tree.gdshader"
const PLACE_SHADER := "res://shaders/tree_place.glsl"

const LEVELS := 7
## Mittlerer Baumabstand über alle Stufen bei k = 1, Welteinheiten (1 ≈ 100 m).
const BASE_SPACING := 0.10
## Kartensymbol: in der Nahsicht (Abstand 16) etwa maßstäblich, im Diorama
## (≈ 150) gut fünffach.
const K_NEAR := 1.2
const D_NEAR := 16.0
const K_EXP := 0.64
const K_MAX := 12.0
## Ausdünnung: Dichte ∝ 1/k^THIN_EXP (2 hielte die Deckung genau gleich,
## etwas weniger lässt die Kronen in der Ferne überlappen: geschlossener Wald).
const THIN_EXP := 1.7
const TREE_HEIGHT := 0.22
## Krone, unter der die Waldmaske tragen muss (× k × Größe), Welteinheiten.
const CROWN_REACH := 0.07
## Schwelle der Waldmaske je Baum: MASK_LO + MASK_SPREAD · Zufall.
const MASK_LO := 0.22
const MASK_SPREAD := 0.33
## Ab hier grobe Form (je Baum ±15 % gestreut).
const LOD_DIST := 45.0
## Bäume werfen Schatten bis hier (Abstand zur Kamera); Schattenwerfer
## außerhalb des Bilds bis SHADOW_MARGIN Einheiten neben dem Frustum.
const SHADOW_RANGE := 400.0
const SHADOW_MARGIN := 3.0
## Kapazität je MultiMesh (16 Floats je Baum).
const CONIFER_CAP := 65536
const BROAD_CAP := 65536
const FAR_CAP := 131072
const SHADOW_CAP := 131072

## Diese Texturen liest der Pass vom Terrain-Material (Bindungen 0 … 5).
const TEXTURES := [&"height_tex", &"height_prev_tex", &"forest_tex", &"forest_prev_tex",
	&"relief_tex", &"relief_prev_tex"]

var terrain_mat: ShaderMaterial
var camera: Camera3D
var world_size: float
var n: int
var hscale: float
var material: ShaderMaterial
## [Nadelbaum nah, Laubbaum nah, grob fern, Schatten]: {mm, inst, cap, mesh}
var lists: Array[Dictionary] = []
# Nur auf dem Render-Thread benutzt.
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _params: RID
var _counts: RID
var _sampler: RID
var _uniform_set: RID
var _uniform_key: Array[RID] = []
## MultiMesh-RIDs für den Render-Thread, einmal in `setup` erfasst (`lists`
## leert `_exit_tree` auf dem Haupt-Thread).
var _mm_rids: Array[RID] = []
## relief_tex des letzten Bilds: tauscht Main die Backtextur, ist die neue in
## diesem Bild noch nicht gerendert (s. `_process`).
var _last_relief: RID

static func available() -> bool:
	return RenderingServer.get_rendering_device() != null

static func spacing(level: int) -> float:
	return BASE_SPACING * pow(2.0, (level + 1) * 0.5)

static func rank_lo(level: int) -> float:
	return 0.0 if level == LEVELS - 1 else pow(2.0, -(level + 1))

static func rank_hi(level: int) -> float:
	return pow(2.0, -level)

## Symbolfaktor, ab dem die Stufe keinen Baum mehr zeigt: Rang 2^−(L+1) ·
## k^THIN_EXP = 1. Die letzte Stufe zeigt immer welche.
static func level_k_end(level: int) -> float:
	if level == LEVELS - 1:
		return INF
	return pow(2.0, (level + 1) / THIN_EXP)

## Abstand dazu; INF, wenn die Stufe bis K_MAX Bäume zeigt.
static func level_range(level: int) -> float:
	var k := level_k_end(level)
	if k >= K_MAX:
		return INF
	return D_NEAR * pow(k / K_NEAR, 1.0 / K_EXP)

func setup(p_terrain_mat: ShaderMaterial, p_camera: Camera3D, p_world_size: float,
		p_n: int, p_hscale: float) -> void:
	terrain_mat = p_terrain_mat
	camera = p_camera
	world_size = p_world_size
	n = p_n
	hscale = p_hscale
	material = ShaderMaterial.new()
	material.shader = load(SHADER)
	var coarse := TreeMesh.build_shadow()
	# Nie von Godot gecullt: das Frustum prüft der Pass je Baum.
	var top := TREE_HEIGHT * 1.4 * K_MAX
	var aabb := AABB(Vector3(-world_size, -top, -world_size),
		Vector3(world_size * 2.0, hscale * 2.0 + top * 2.0, world_size * 2.0))
	var scenario := get_world_3d().scenario
	for spec in [[TreeMesh.build_conifer(), CONIFER_CAP, RenderingServer.SHADOW_CASTING_SETTING_OFF],
			[TreeMesh.build_broadleaf(), BROAD_CAP, RenderingServer.SHADOW_CASTING_SETTING_OFF],
			[coarse, FAR_CAP, RenderingServer.SHADOW_CASTING_SETTING_OFF],
			[coarse, SHADOW_CAP, RenderingServer.SHADOW_CASTING_SETTING_SHADOWS_ONLY]]:
		var mm := RenderingServer.multimesh_create()
		# Erst allozieren, dann das Mesh: erst dann füllt Godot den
		# Kommando-Puffer ([Indexzahl, Instanzen, 0, 0, 0], gemessen 4.7.2).
		RenderingServer.multimesh_allocate_data(mm, spec[1],
			RenderingServer.MULTIMESH_TRANSFORM_3D, false, true, true)
		RenderingServer.multimesh_set_mesh(mm, (spec[0] as Mesh).get_rid())
		RenderingServer.multimesh_set_custom_aabb(mm, aabb)
		var inst := RenderingServer.instance_create2(mm, scenario)
		RenderingServer.instance_geometry_set_material_override(inst, material.get_rid())
		RenderingServer.instance_geometry_set_cast_shadows_setting(inst, spec[2])
		lists.append({"mm": mm, "inst": inst, "cap": spec[1], "mesh": spec[0]})
		_mm_rids.append(mm)
	RenderingServer.call_on_render_thread(_create_pipeline)

func _create_pipeline() -> void:
	_rd = RenderingServer.get_rendering_device()
	var file: RDShaderFile = load(PLACE_SHADER)
	_shader = _rd.shader_create_from_spirv(file.get_spirv())
	_pipeline = _rd.compute_pipeline_create(_shader)
	_params = _rd.uniform_buffer_create(14 * 16)
	_counts = _rd.storage_buffer_create(16)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(ss)

func _exit_tree() -> void:
	for l in lists:
		RenderingServer.free_rid(l["inst"])
		RenderingServer.free_rid(l["mm"])
	lists.clear()
	if _rd != null:
		RenderingServer.call_on_render_thread(_free_pipeline)

func _free_pipeline() -> void:
	# Der Uniform-Satz hängt am Shader und fällt mit ihm.
	for rid in [_pipeline, _shader, _params, _counts, _sampler]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_pipeline = RID()
	_shader = RID()
	_params = RID()
	_counts = RID()
	_sampler = RID()
	_uniform_set = RID()

func _process(_delta: float) -> void:
	if OS.has_environment("RS_TREE_STATS"):
		_print_stats()
	# Angehaltener Renderloop (Leerlauf, Main): kein Bild, also auch kein
	# Pass. Sonst sammelten sich die Aufträge im nie abgeschickten Bild an.
	if lists.is_empty() or not RenderingServer.render_loop_enabled:
		return
	var tex_rids: Array[RID] = []
	for name in TEXTURES:
		var t: Texture2D = terrain_mat.get_shader_parameter(name)
		if t == null and String(name).begins_with("relief"):
			t = terrain_mat.get_shader_parameter(&"height_tex")  # Verschiebung aus
		if t == null:
			return  # vor dem ersten Frame: noch nichts zu platzieren
		tex_rids.append(t.get_rid())
	# Main tauscht die Backtextur der Verschiebung, und die neue rendert erst
	# NACH diesem Pass (SubViewport im selben Bild). Dann gilt hier noch der
	# zuletzt gerenderte Stand, also relief_prev_tex (Blende 0).
	var swapped := tex_rids[4] != _last_relief
	_last_relief = tex_rids[4]
	# Ohne Kronendach (Diagnose-Bühnen schalten es ab) auch keine Bäume:
	# leere Fenster, der Abschluss schreibt 0 Instanzen.
	var windows := _windows() if terrain_mat.get_shader_parameter(&"canopy_enabled") == true else []
	RenderingServer.call_on_render_thread(_dispatch.bind(_params_bytes(swapped), windows, tex_rids))

## Kamera, Blenden und Werte als std140-Block (s. `Params` im Compute-Shader).
func _params_bytes(relief_swapped := false) -> PackedByteArray:
	var eye := camera.global_position
	var m := terrain_mat
	var relief_on: bool = m.get_shader_parameter(&"relief_enabled") == true \
		and m.get_shader_parameter(&"relief_tex") != null
	var f := PackedFloat32Array([
		eye.x, eye.y, eye.z, hscale,
		_num(m, &"height_blend", 1.0), _num(m, &"overlay_blend", 1.0),
		0.0 if relief_swapped else _num(m, &"bake_blend", 1.0), 1.0 if relief_on else 0.0,
		_num(m, &"relief_height_code", 1.0), _num(m, &"relief_geometry_age", 1.0),
		_num(m, &"sim_year", 0.0), world_size,
		float(n), _num(m, &"conifer_lo", 0.3), _num(m, &"conifer_hi", 0.6), 0.0,
		K_NEAR, D_NEAR, K_EXP, K_MAX,
		THIN_EXP, TREE_HEIGHT, CROWN_REACH, MASK_LO,
		MASK_SPREAD, LOD_DIST, SHADOW_RANGE, SHADOW_MARGIN,
		float(CONIFER_CAP), float(BROAD_CAP), float(FAR_CAP), float(SHADOW_CAP),
	])
	# Frustum mit Normalen nach außen: ein Punkt mitten im Sichtkegel muss
	# innen liegen, sonst wird die Ebene umgedreht.
	var inside := eye - camera.global_transform.basis.z * (camera.near + 1.0)
	for plane: Plane in camera.get_frustum():
		var pl := plane
		if pl.distance_to(inside) > 0.0:
			pl = -pl
		f.append_array([pl.normal.x, pl.normal.y, pl.normal.z, pl.d])
	return f.to_byte_array()

static func _num(m: ShaderMaterial, name: StringName, fallback: float) -> float:
	var v: Variant = m.get_shader_parameter(name)
	return float(v) if v != null else fallback

## Je Stufe das Gitterfenster um die Kamera (erste Zelle, Größe), so weit die
## Stufe Bäume zeigt; außerhalb der Insel abgeschnitten.
func _windows() -> Array:
	var eye := camera.global_position
	var half := world_size * 0.5
	var out := []
	for level in LEVELS:
		var s := spacing(level)
		var cells := int(ceil(world_size / s))
		var reach := level_range(level)
		var lo := Vector2i.ZERO
		var hi := Vector2i(cells, cells)
		if reach < INF:
			# Horizontaler Abstand reicht: der echte ist nur größer.
			lo = Vector2i(int(floor((eye.x + half - reach) / s)), int(floor((eye.z + half - reach) / s)))
			hi = Vector2i(int(ceil((eye.x + half + reach) / s)), int(ceil((eye.z + half + reach) / s)))
			lo = lo.clamp(Vector2i.ZERO, Vector2i(cells, cells))
			hi = hi.clamp(Vector2i.ZERO, Vector2i(cells, cells))
		var size := hi - lo
		if size.x <= 0 or size.y <= 0:
			continue
		var pc := PackedByteArray()
		pc.resize(32)
		pc.encode_s32(0, lo.x)
		pc.encode_s32(4, lo.y)
		pc.encode_s32(8, size.x)
		pc.encode_s32(12, size.y)
		pc.encode_float(16, s)
		pc.encode_float(20, rank_lo(level))
		pc.encode_float(24, rank_hi(level))
		pc.encode_s32(28, level)
		out.append([pc, size])
	return out

## Render-Thread: Zähler leeren, je Stufe ein Durchlauf, dann die Zähler in
## die Kommando-Puffer (gedeckelt). Alles in EINER Compute-Liste vor dem Bild.
func _dispatch(params: PackedByteArray, windows: Array, tex_rids: Array[RID]) -> void:
	if not _pipeline.is_valid():
		return
	var rd_tex: Array[RID] = []
	for rid in tex_rids:
		var t := RenderingServer.texture_get_rd_texture(rid)
		if not t.is_valid():
			return
		rd_tex.append(t)
	if rd_tex != _uniform_key or not _rd.uniform_set_is_valid(_uniform_set):
		# Der alte Satz fiele sonst erst mit dem Shader (Ping-Pong der
		# Verschiebung: mehrmals je Sekunde ein neuer).
		if _uniform_set.is_valid() and _rd.uniform_set_is_valid(_uniform_set):
			_rd.free_rid(_uniform_set)
		_uniform_set = _make_uniform_set(rd_tex)
		_uniform_key = rd_tex
	_rd.buffer_update(_params, 0, params.size(), params)
	_rd.buffer_clear(_counts, 0, 16)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, _uniform_set, 0)
	for w in windows:
		var pc: PackedByteArray = w[0]
		var size: Vector2i = w[1]
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, (size.x + 7) / 8, (size.y + 7) / 8, 1)
	_rd.compute_list_add_barrier(cl)
	var fin := PackedByteArray()
	fin.resize(32)
	fin.encode_s32(28, -1)
	_rd.compute_list_set_push_constant(cl, fin, fin.size())
	_rd.compute_list_dispatch(cl, 1, 1, 1)
	_rd.compute_list_end()

func _make_uniform_set(rd_tex: Array[RID]) -> RID:
	var uniforms: Array[RDUniform] = []
	for i in rd_tex.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u.binding = i
		u.add_id(_sampler)
		u.add_id(rd_tex[i])
		uniforms.append(u)
	for i in _mm_rids.size():
		var mm := _mm_rids[i]
		uniforms.append(_storage(6 + i, RenderingServer.multimesh_get_buffer_rd_rid(mm)))
		uniforms.append(_storage(11 + i, RenderingServer.multimesh_get_command_buffer_rd_rid(mm)))
	uniforms.append(_storage(10, _counts))
	var ub := RDUniform.new()
	ub.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	ub.binding = 15
	ub.add_id(_params)
	uniforms.append(ub)
	return _rd.uniform_set_create(uniforms, _shader, 0)

static func _storage(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u

## Wie viele Bäume der letzte Pass je Liste [Nadelbaum nah, Laubbaum nah,
## fern, Schatten] geschrieben hat, vor dem Deckel (Diagnose; liest den Zähler zurück, Render-Thread).
func read_counts() -> PackedInt32Array:
	if not _counts.is_valid():
		return PackedInt32Array()
	return _rd.buffer_get_data(_counts).to_int32_array()

## `RS_TREE_STATS`: alle 30 Bilder die Baumzahlen je Liste.
func _print_stats() -> void:
	if Engine.get_process_frames() % 30 == 0:
		RenderingServer.call_on_render_thread(func() -> void:
			print("TREE_STATS counts=", read_counts()))

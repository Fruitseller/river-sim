extends RefCounted

const SHADER_DIR := "res://shaders/amplify/"
const FACTOR := 4
const OUTPUT_MIPS := 7

var params := {
	"steps_1": 48, "steps_2": 24,
	"erode_1": 4.0e-4, "erode_2": 3.0e-4, "erode_m": 0.75,
	"flow_p": 1.3,
	"hard_gain": 0.95,
	"hard_wave_a": 5.0, "hard_wave_b": 2.2, "hard_wave_c": 0.9,
	"hard_weight_a": 0.45, "hard_weight_b": 0.35, "hard_weight_c": 0.2,
	"thermal_rate": 0.04, "talus": 1.2, "talus_sim": 1.3,
	"stream_blur_1": 0.15, "stream_blur_2": 0.1, "creep": 0.0,
	"capacity": 0.1, "deposit_rate": 0.25, "deposit_cap": 0.02,
	"bound_down": 0.30, "bound_up": 0.20, "strength": 0.6,
	"strength_steep": 1.2, "steep_lo": 0.8, "steep_hi": 1.8,
	"region_floor": 0.3, "region_cells": 56.0,
	"mean_window": 3.0,
	"cavity_depth": 0.05,
	"map_erosion": 0.5, "map_deposit": 0.03, "map_scree": 0.08, "map_flow": 4096.0,
}

const MAX_SHARE_PER_FRAME := 0.25

var rd: RenderingDevice
var n := 0
var world_size := 0.0
var hscale := 0.0
var sea := 0.0
var pond_depth := 0.0
var height_code := 0.0
var slope_code := 0.0

var _shaders := {}
var _pipelines := {}
var _linear: RID
var _nearest: RID
var _rids: Array[RID] = []
var _sets := {}

var _sim_height: RID
var _sim_filled: RID
var _sim_protect: RID
var _height := [[], []]
var _flux := [[], []]
var _accum: Array[RID] = []
var _mean: RID
var _correction: RID
var _mask: RID
var _offset: RID
var _relief: Array[RID] = []
var _maps: Array[RID] = []
var _relief_mips := [[], []]
var _maps_mips := [[], []]
var _relief_tex: Array[Texture2DRD] = []
var _maps_tex: Array[Texture2DRD] = []
var _front := 0
var _valid := false

var _queue: Array = []
var _pending: Array = []
var _has_inputs := false
var _plan_cost := 0.0
var _allowance := 0.0
var _job_fade := false
var published_fade := false
var published := 0
var passes_run := 0

static func available() -> bool:
	return RenderingServer.get_rendering_device() != null

func setup(grid_n: int, world: float, height_scale: float, sea_level: float,
		pond: float, relief_height_code: float, relief_slope_code: float) -> bool:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		return false
	n = grid_n
	world_size = world
	hscale = height_scale
	sea = sea_level
	pond_depth = pond
	height_code = relief_height_code
	slope_code = relief_slope_code
	var common := FileAccess.get_file_as_string(SHADER_DIR + "common.glsl")
	for name in ["mask", "ingest", "refine", "step", "mean", "mean_solve", "bind", "encode"]:
		if not _compile(name, name, common, ""):
			return false
	if not _compile("mip_relief", "mip", common, "#define FORMAT rgba16f\n") \
			or not _compile("mip_maps", "mip", common, "#define FORMAT rgba8\n"):
		return false
	_linear = _sampler(RenderingDevice.SAMPLER_FILTER_LINEAR)
	_nearest = _sampler(RenderingDevice.SAMPLER_FILTER_NEAREST)
	var F := RenderingDevice
	_sim_height = _texture(n, F.DATA_FORMAT_R32_SFLOAT, 1, false)
	_sim_filled = _texture(n, F.DATA_FORMAT_R32_SFLOAT, 1, false)
	_sim_protect = _texture(n, F.DATA_FORMAT_R8_UNORM, 1, false)
	for level in 2:
		var size := n * (2 << level)
		for i in 2:
			_height[level].append(_texture(size, F.DATA_FORMAT_R32G32_SFLOAT, 1, true))
			_flux[level].append(_texture(size, F.DATA_FORMAT_R16G16B16A16_SFLOAT, 1, true))
		_accum.append(_texture(size, F.DATA_FORMAT_R16G16B16A16_SFLOAT, 1, true))
	_mean = _texture(n, F.DATA_FORMAT_R32_SFLOAT, 1, true)
	_correction = _texture(n, F.DATA_FORMAT_R32_SFLOAT, 1, true)
	_mask = _texture(n, F.DATA_FORMAT_R16_SFLOAT, 1, true)
	var fine := n * FACTOR
	_offset = _texture(fine, F.DATA_FORMAT_R16G16_SFLOAT, 1, true)
	for i in 2:
		_relief.append(_texture(fine, F.DATA_FORMAT_R16G16B16A16_SFLOAT, OUTPUT_MIPS, true))
		_maps.append(_texture(fine, F.DATA_FORMAT_R8G8B8A8_UNORM, OUTPUT_MIPS, true))
		for mip in OUTPUT_MIPS:
			_relief_mips[i].append(_keep(rd.texture_create_shared_from_slice(
				RDTextureView.new(), _relief[i], 0, mip, 1)))
			_maps_mips[i].append(_keep(rd.texture_create_shared_from_slice(
				RDTextureView.new(), _maps[i], 0, mip, 1)))
		var relief_tex := Texture2DRD.new()
		relief_tex.texture_rd_rid = _relief[i]
		_relief_tex.append(relief_tex)
		var maps_tex := Texture2DRD.new()
		maps_tex.texture_rd_rid = _maps[i]
		_maps_tex.append(maps_tex)
	return true

func submit(heights: PackedByteArray, filled: PackedByteArray, protect: PackedByteArray,
		immediate: bool, fade := false) -> void:
	if not _pending.is_empty():
		if filled.is_empty():
			filled = _pending[1]
		if protect.is_empty():
			protect = _pending[2]
	if immediate:
		_queue.clear()
		_pending.clear()
		_begin(heights, filled, protect, fade)
		while not _queue.is_empty():
			_run(_queue.pop_front())
		_publish()
	elif _queue.is_empty():
		_begin(heights, filled, protect, fade)
	else:
		_pending = [heights, filled, protect, fade]

func advance(may_publish: bool, delta: float, seconds: float) -> bool:
	if _queue.is_empty():
		return false
	_allowance = minf(_allowance + _plan_cost * delta / maxf(seconds, 0.001),
		_plan_cost * MAX_SHARE_PER_FRAME)
	while not _queue.is_empty() and _allowance > 0.0:
		var next: Dictionary = _queue[0]
		if next["output"] and not may_publish:
			return false
		_allowance -= next["cost"]
		_run(_queue.pop_front())
	if not _queue.is_empty():
		return false
	_publish()
	if not _pending.is_empty():
		var p := _pending
		_pending = []
		_begin(p[0], p[1], p[2], p[3])
	return true

func busy() -> bool:
	return not _queue.is_empty()

func running_fade() -> bool:
	return _job_fade

func has_result() -> bool:
	return _valid

func has_inputs() -> bool:
	return _has_inputs

func relief_texture() -> Texture2DRD:
	return _relief_tex[_front]

func previous_relief_texture() -> Texture2DRD:
	return _relief_tex[1 - _front]

func maps_texture() -> Texture2DRD:
	return _maps_tex[_front]

func previous_maps_texture() -> Texture2DRD:
	return _maps_tex[1 - _front]

func read_cell_lift() -> PackedFloat32Array:
	if not _valid:
		return PackedFloat32Array()
	var bytes := rd.texture_get_data(_relief_mips[_front][2], 0)
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGBAH, bytes)
	img.convert(Image.FORMAT_RF)
	return img.get_data().to_float32_array()

func read_raw(what: String) -> PackedByteArray:
	match what:
		"offset": return rd.texture_get_data(_offset, 0)
		"maps": return rd.texture_get_data(_maps_mips[_front][0], 0)
		"relief": return rd.texture_get_data(_relief_mips[_front][0], 0)
		"mean": return rd.texture_get_data(_mean, 0)
		"correction": return rd.texture_get_data(_correction, 0)
		"height": return rd.texture_get_data(_height[1][int(params["steps_2"]) % 2], 0)
		"flux": return rd.texture_get_data(_flux[1][int(params["steps_2"]) % 2], 0)
	return PackedByteArray()

func free_resources() -> void:
	if rd == null:
		return
	for tex in _relief_tex + _maps_tex:
		tex.texture_rd_rid = RID()
	_relief_tex.clear()
	_maps_tex.clear()
	for key in _sets:
		if rd.uniform_set_is_valid(_sets[key]):
			rd.free_rid(_sets[key])
	_sets.clear()
	_rids.reverse()
	for rid in _rids:
		if rid.is_valid():
			rd.free_rid(rid)
	_rids.clear()
	rd = null

func _begin(heights: PackedByteArray, filled: PackedByteArray, protect: PackedByteArray,
		fade: bool) -> void:
	_job_fade = fade
	if not heights.is_empty():
		rd.texture_update(_sim_height, 0, heights)
	if not filled.is_empty():
		rd.texture_update(_sim_filled, 0, filled)
	if not protect.is_empty():
		rd.texture_update(_sim_protect, 0, protect)
	_has_inputs = true
	_queue = _plan()
	_plan_cost = 0.0
	for job in _queue:
		_plan_cost += job["cost"]
	_allowance = 0.0

func _plan() -> Array:
	var plan: Array = []
	var s1 := n * 2
	var s2 := n * 4
	var dx1 := world_size / float(n - 1) / 2.0
	var dx2 := dx1 / 2.0
	var p := params
	plan.append(_pass("mask", "mask", n,
		[_tex(0, _sim_protect, _nearest), _tex(1, _sim_height, _nearest), _img(2, _mask)],
		[n, sea, 0, 0]))
	plan.append(_pass("ingest", "ingest", s1,
		[_tex(0, _sim_height, _nearest), _img(1, _height[0][0]), _img(2, _flux[0][0]),
			_img(3, _accum[0])],
		[s1, s1, n, hscale, 4.0, world_size / float(n - 1), 0, 0] + _hardness()))
	var steps_1: int = p["steps_1"]
	for i in steps_1:
		plan.append(_step(0, i, s1, dx1, 4.0, p["erode_1"], p["stream_blur_1"]))
	var from := steps_1 % 2
	plan.append(_pass("refine", "refine_%d" % from, s2,
		[_tex(0, _height[0][from], _nearest), _tex(1, _flux[0][from], _linear),
			_tex(2, _accum[0], _linear), _img(3, _height[1][0]), _img(4, _flux[1][0]),
			_img(5, _accum[1])],
		[s2, s2, FACTOR, 0] + _hardness()))
	var steps_2: int = p["steps_2"]
	for i in steps_2:
		plan.append(_step(1, i, s2, dx2, 1.0, p["erode_2"], p["stream_blur_2"]))
	var last := steps_2 % 2
	var fin: RID = _height[1][last]
	var tag := "%d" % last
	plan.append(_pass("mean", "mean_" + tag, n,
		[_tex(0, fin, _nearest), _tex(1, _sim_height, _linear), _img(2, _mean)],
		[n, FACTOR, hscale, 0]))
	plan.append(_pass("mean_solve", "mean_solve", n,
		[_tex(0, _mean, _nearest), _img(1, _correction)], [n, p["mean_window"], 0, 0]))
	plan.append(_pass("bind", "bind_" + tag, s2,
		[_tex(0, fin, _nearest), _tex(1, _sim_height, _linear), _tex(2, _sim_filled, _linear),
			_tex(3, _mask, _linear), _tex(4, _correction, _linear), _img(5, _offset),
			_tex(6, _flux[1][last], _nearest)],
		[s2, s2, hscale, sea, p["bound_down"], p["bound_up"], p["strength"], pond_depth]
			+ [p["strength_steep"], p["steep_lo"], p["steep_hi"], p["region_cells"],
				p["region_floor"], n, 0, 0]))
	var back := 1 - _front if _valid else _front
	var enc := _pass("encode", "encode_%s_%d" % [tag, back], s2,
		[_tex(0, _offset, _nearest), _tex(1, _flux[1][last], _nearest), _tex(2, _accum[1], _nearest),
			_img(3, _relief_mips[back][0]), _img(4, _maps_mips[back][0])],
		[s2, s2, hscale, p["cavity_depth"], height_code, slope_code, 0, 0,
			p["map_erosion"], p["map_deposit"], p["map_scree"], p["map_flow"]])
	enc["output"] = true
	plan.append(enc)
	var size := s2
	for mip in range(1, OUTPUT_MIPS):
		size = maxi(size / 2, 1)
		for kind in ["relief", "maps"]:
			var views: Array = _relief_mips[back] if kind == "relief" else _maps_mips[back]
			var m := _pass("mip_" + kind, "mip_%s_%d_%d" % [kind, back, mip], size,
				[_tex(0, views[mip - 1], _linear), _img(1, views[mip])], [size, size, 0, 0])
			m["output"] = true
			plan.append(m)
	return plan

func _hardness() -> Array:
	var p := params
	return [1.0 / p["hard_wave_a"], 1.0 / p["hard_wave_b"], 1.0 / p["hard_wave_c"], 0,
		p["hard_weight_a"], p["hard_weight_b"], p["hard_weight_c"], 0]

func _step(level: int, i: int, size: int, dx: float, area: float, erode: float,
		blur: float) -> Dictionary:
	var p := params
	var src := i % 2
	var dst := 1 - src
	return _pass("step", "step_%d_%d" % [level, src], size,
		[_tex(0, _height[level][src], _nearest), _tex(1, _flux[level][src], _nearest),
			_img(2, _height[level][dst]), _img(3, _flux[level][dst]), _img(4, _accum[level])],
		[size, size, dx, area,
			erode, p["erode_m"], p["flow_p"], p["hard_gain"],
			p["thermal_rate"], p["talus"], 0, blur,
			p["talus_sim"], 0, 0, 0,
			p["capacity"], p["creep"], p["deposit_rate"], p["deposit_cap"]])

func _publish() -> void:
	if _valid:
		_front = 1 - _front
	_valid = true
	published += 1
	published_fade = _job_fade

func _run(job: Dictionary) -> void:
	var size: int = job["size"]
	var groups := (size + 7) / 8
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipelines[job["shader"]])
	rd.compute_list_bind_uniform_set(list, _uniform_set(job), 0)
	var pc: PackedByteArray = job["pc"]
	rd.compute_list_set_push_constant(list, pc, pc.size())
	rd.compute_list_dispatch(list, groups, groups, 1)
	rd.compute_list_end()
	passes_run += 1

func _pass(shader: String, key: String, size: int, uniforms: Array, pc: Array) -> Dictionary:
	return {
		"shader": shader, "key": key, "size": size, "uniforms": uniforms,
		"pc": PackedFloat32Array(pc).to_byte_array(),
		"cost": float(size) * float(size) / 1.0e6 * (1.0 if shader == "step" else 0.5),
		"output": false,
	}

func _uniform_set(job: Dictionary) -> RID:
	var key: String = job["key"]
	if not _sets.has(key):
		_sets[key] = rd.uniform_set_create(job["uniforms"], _shaders[job["shader"]], 0)
	return _sets[key]

func _tex(binding: int, texture: RID, sampler: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(sampler)
	u.add_id(texture)
	return u

func _img(binding: int, texture: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(texture)
	return u

func _compile(name: String, file: String, common: String, defines: String) -> bool:
	var source := RDShaderSource.new()
	source.source_compute = "#version 450\n" + defines + common + "\n" \
		+ FileAccess.get_file_as_string(SHADER_DIR + file + ".glsl")
	var spirv := rd.shader_compile_spirv_from_source(source)
	if spirv.compile_error_compute != "":
		push_error("Verfeinerung: %s.glsl übersetzt nicht: %s" % [file, spirv.compile_error_compute])
		return false
	var shader := rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		return false
	_shaders[name] = _keep(shader)
	_pipelines[name] = _keep(rd.compute_pipeline_create(shader))
	return true

func _sampler(filter: int) -> RID:
	var state := RDSamplerState.new()
	state.min_filter = filter
	state.mag_filter = filter
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	return _keep(rd.sampler_create(state))

func _texture(size: int, format: int, mips: int, storage: bool) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.format = format
	fmt.width = size
	fmt.height = size
	fmt.mipmaps = mips
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	if storage:
		fmt.usage_bits |= RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	return _keep(rd.texture_create(fmt, RDTextureView.new(), []))

func _keep(rid: RID) -> RID:
	_rids.append(rid)
	return rid

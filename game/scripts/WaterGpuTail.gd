extends Node

var blur_masks: PackedFloat32Array
var prime_blend := 1.0
var blur_vp: Array[SubViewport] = []
var blur_mat: Array[ShaderMaterial] = []
var state_vp: Array[SubViewport] = []
var ewma_mat: Array[ShaderMaterial] = []
var state_index := 0
var primed := false
var _size := 0
var _raw_tex: ImageTexture

func setup(sim: Object, size: int) -> void:
	_size = size
	blur_masks = sim.waterTailBlurMasks()
	var pass_count: int = sim.waterTailBlurPassCount()
	prime_blend = sim.waterTailPrimeBlend()
	var blur_shader: Shader = load("res://shaders/water_field_blur.gdshader")
	var ewma_shader: Shader = load("res://shaders/water_field_ewma.gdshader")
	var upstream: Texture2D = null
	for pass_index in pass_count:
		var mat := ShaderMaterial.new()
		mat.shader = blur_shader
		mat.set_shader_parameter("blur_channels",
			Vector2(blur_masks[pass_index * 2], blur_masks[pass_index * 2 + 1]))
		if upstream != null:
			mat.set_shader_parameter("src", upstream)
		var vp := _make_field_viewport(true)
		vp.add_child(_make_field_rect(mat))
		add_child(vp)
		blur_vp.append(vp)
		blur_mat.append(mat)
		upstream = vp.get_texture()
	for _state_index in 2:
		var mat := ShaderMaterial.new()
		mat.shader = ewma_shader
		mat.set_shader_parameter("fresh", upstream)
		var vp := _make_field_viewport(false)
		vp.add_child(_make_field_rect(mat))
		add_child(vp)
		state_vp.append(vp)
		ewma_mat.append(mat)

func _make_field_viewport(clear_each_pass: bool) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(_size, _size)
	vp.disable_3d = true
	vp.use_hdr_2d = true
	vp.transparent_bg = true
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS if clear_each_pass \
		else SubViewport.CLEAR_MODE_NEVER
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	return vp

func _make_field_rect(mat: ShaderMaterial) -> ColorRect:
	var rect := ColorRect.new()
	rect.size = Vector2(_size, _size)
	rect.material = mat
	return rect

func update(raw: PackedByteArray, blend: float) -> void:
	_upload_raw(raw)
	var previous := state_index
	state_index = 1 - state_index
	var mat := ewma_mat[state_index]
	mat.set_shader_parameter("state", state_vp[previous].get_texture())
	mat.set_shader_parameter("blend", blend if primed else prime_blend)
	primed = true
	for vp in blur_vp:
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	state_vp[state_index].render_target_update_mode = SubViewport.UPDATE_ONCE

func _upload_raw(raw: PackedByteArray) -> void:
	var img := Image.create_from_data(_size, _size, false, Image.FORMAT_RGBA8, raw)
	if _raw_tex == null:
		_raw_tex = ImageTexture.create_from_image(img)
		blur_mat[0].set_shader_parameter("src", _raw_tex)
	else:
		_raw_tex.update(img)

func current_texture() -> Texture2D:
	return state_vp[state_index].get_texture()

func previous_texture() -> Texture2D:
	return state_vp[1 - state_index].get_texture()

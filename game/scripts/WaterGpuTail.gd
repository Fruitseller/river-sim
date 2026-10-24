extends Node
## GPU-Kette des Wasserfeld-Schwanzes (Issue #95): die abschaltbare GPU-Fassung
## der Schwanzstufen des Raster-Wasserfelds — räumlicher Blur (max(Kern, Blur))
## und zeitliche EWMA — als SubViewport-Kette über den beiden Rechen-Shadern
## `water_field_blur.gdshader` und `water_field_ewma.gdshader`.
##
## Der Pass-Plan (Pass-Zahl, Kanal-Masken, Priming) kommt als DATEN von der
## Brücke (`SimNode.waterTail*`), Quelle ist `SimRender.WaterTailPlan` — dieselbe
## Quelle, aus der der CPU-Pfad (`WaterFieldRenderer`) seine Pass-Zahlen nimmt.
## In diesem Skript steht deshalb keine Kalibrierzahl: Masken, Pass-Zahl und
## Priming reisen über `setup()`, die Blende je Tick über `update()` (Frame-
## Protokoll, `water_blend` aus `RenderState.frame`).
##
## Die Kette gehört Main UND dem Vertragstest (`game/tests/water_gpu_tail.gd`)
## — EINE Implementierung, kein Parallelbau: der Test vergleicht ihr Ergebnis
## gegen den CPU-Pfad und belegt die Framerate-Unabhängigkeit der EWMA.
##
## Godot rendert SubViewports vor dem Hauptviewport; hängt ein Pass dennoch
## einen Frame zurück, konvergiert die Kette trotzdem — sie wird nur um Frames
## träger, nicht falsch.

## Kanal-Masken der Blur-Pässe (2 Werte je Pass, R dann G) — von der Brücke.
var blur_masks: PackedFloat32Array
## Blende des ersten Ticks (Priming) — von der Brücke.
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
	# Erst R und G glätten, dann nur noch G: der See-Kanal braucht zwei Pässe
	# (er muss den seichten Ufersaum überdecken), der Fluss-Kanal einen — die
	# Maske je Pass sagt das als Datum, nicht als Literal hier.
	var upstream: Texture2D = null   # erster Pass liest die CPU-Rohtextur
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
		# CLEAR_MODE_NEVER: diese beiden Targets SIND das EWMA-Gedächtnis.
		var vp := _make_field_viewport(false)
		vp.add_child(_make_field_rect(mat))
		add_child(vp)
		state_vp.append(vp)
		ewma_mat.append(mat)

func _make_field_viewport(clear_each_pass: bool) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(_size, _size)
	vp.disable_3d = true
	# Half-Float-Target: in 8 Bit bliebe die EWMA bei kleinem `blend` STEHEN, weil
	# das Inkrement bl*(ziel − zustand) unter 1/255 rundet (bei 0.15 schon ab
	# ~0.026 Abstand). Der Zustand braucht die Auflösung, die Eingabe nicht.
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

## Ein Durchlauf der GPU-Kette. `blend` hat dieselbe Bedeutung wie im CPU-Pfad:
## 1 = frischen Zustand sofort übernehmen (Sprung, Sculpting), klein = weich
## blenden im Zeitraffer; er reist im Frame (`water_blend`). Der ERSTE Tick
## übernimmt das Feld vollständig (Priming aus SimRender, s. `prime_blend`).
func update(raw: PackedByteArray, blend: float) -> void:
	_upload_raw(raw)
	# Ping-Pong: aus dem aktuellen Zustand lesen, in das andere Target schreiben.
	# Dasselbe Target zu lesen und zu beschreiben ist undefiniert.
	var previous := state_index
	state_index = 1 - state_index
	var mat := ewma_mat[state_index]
	mat.set_shader_parameter("state", state_vp[previous].get_texture())
	mat.set_shader_parameter("blend", blend if primed else prime_blend)
	primed = true
	# GENAU EIN Durchlauf je Textur-Update (nicht je Frame): sonst hinge die
	# Glättungsrate an der Bildrate. Das gelesene Zustands-Target bleibt dabei
	# bewusst auf UPDATE_DISABLED.
	for vp in blur_vp:
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	state_vp[state_index].render_target_update_mode = SubViewport.UPDATE_ONCE

## Taktet die Kette NOCH EINMAL, ohne Daten oder Uniformen zu ändern: ein
## Render-Wiederholung mit unveränderten Uniformen liefert dasselbe Ergebnis
## (idempotent). Der Vertragstest fasst damit nach, wenn ein UPDATE_ONCE
## verloren ging (der Readback blieb unverändert), bevor er die Kette als
## hängend meldet — Produktionscode ruft das nicht.
func retick() -> void:
	for vp in blur_vp:
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	state_vp[state_index].render_target_update_mode = SubViewport.UPDATE_ONCE

## Rohfeld (RGBA8, ungeblurt — `SimNode` mit `setDeferWaterTail(true)`) in den
## ersten Blur-Pass laden. Neues Image je Upload: der alte Stand bleibt damit
## für einen noch ausstehenden Read des Renderers unverändert (separater
## Render-Thread) — dieselbe Sorgfalt wie `FieldTexture` in Main.gd, hier ohne
## dessen Vorgänger-/Spiegel-Features und bewusst ohne Preload von Main.gd
## (das hätte einen Preload-Zyklus Main ↔ WaterGpuTail zur Folge).
func _upload_raw(raw: PackedByteArray) -> void:
	var img := Image.create_from_data(_size, _size, false, Image.FORMAT_RGBA8, raw)
	if _raw_tex == null:
		_raw_tex = ImageTexture.create_from_image(img)
		blur_mat[0].set_shader_parameter("src", _raw_tex)
	else:
		_raw_tex.update(img)

## Zustand des letzten Ticks (das zuletzt beschriebene Ping-Pong-Ziel).
func current_texture() -> Texture2D:
	return state_vp[state_index].get_texture()

## Vorgängerstand (das andere Ping-Pong-Ziel): es wird erst vom NÄCHSTEN
## Durchlauf beschrieben — `Main.gd` blendet im Zeitraffer darüber hinüber.
func previous_texture() -> Texture2D:
	return state_vp[1 - state_index].get_texture()

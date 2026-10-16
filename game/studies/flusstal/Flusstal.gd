extends "res://scripts/Main.gd"
## Bildstudie #116, seit Spec #156 Mess- und Referenzbühne, kein
## Produktionsweg: die einzige Variante `baseline` IST die Anwendung (Main.gd
## erbt alles). Die Variante `prototype` legte die nicht übernommenen
## PBR-Materialien der ersten Runde darüber; #174 D hat sie durch die
## prozedurale Materialverteilung ersetzt und mit ihren Texturen entfernt.
## Geblieben sind die Debug-Ansichten der Kalibrierung (`RS_STUDY_DEBUG`).
##
## Alle Hebel der zweiten Runde sind Produktion und gelten in beiden
## Varianten: `light` (tiefe Sonne, Schatten, Luftperspektive, Talnebel,
## Wolkenschatten) seit #151 in scripts/Lighting.gd, `frame` (Ozean ohne
## Streifen, Schelf-Farbe, Brandung) seit #155 in shaders/ocean.gdshader,
## `geometry` (Render-Gitter in Sim-Auflösung, grobe Erosionsrinnen und
## geschärfte Grate als echte Verschiebung) seit #153 in Main.gd und
## shaders/relief_bake.gdshader, `canopy` (Kronendach statt Instanzbäumen)
## seit #152 in shaders/terrain.gdshader. Die Studie dient als Mess- und
## Vergleichsbühne (scripts/graphics-matrix.sh) und für die Debug-Ansichten
## der Kalibrierung (`RS_STUDY_DEBUG`).
var study_variant := OS.get_environment("RS_STUDY_VARIANT")
var study_debug := OS.get_environment("RS_STUDY_DEBUG")
## Studien-Fassung des Terrain-Shaders nur für die Debug-Ansichten.
var study_enabled := not study_debug.is_empty()
var study_mode := OS.get_environment("RS_STUDY_MODE")
var study_output := OS.get_environment("RS_STUDY_OUTPUT")
var study_elapsed := 0.0
var study_frames := 0
var study_last_draw := 0
var study_intervals: Array[float] = []
var study_start_yaw := 0.0
## Bedienung in der Messung (`RS_STUDY_UI`, Glas-Weichzeichner #174 E). Leer:
## aus wie bisher (Punkt 47 misst die Landschaft). `plain`: Bedienung ohne
## Weichzeichner, `glass`: mit. `ab`: alle drei Zustände (`AB_STATES`) in
## Blöcken von `AB_BLOCK_FRAMES` Bildern im SELBEN Prozess, die Reihenfolge je
## Runde um einen Zustand gedreht; so verteilt sich Drift (Fremdlast, Takt,
## Wärme) gleich auf alle Zustände. Runde 0 wärmt nur (Shader, Pipelines) und
## zählt nicht; die ersten `AB_SKIP_FRAMES` Bilder eines Blocks auch nicht.
## `RS_STUDY_ROUNDS` setzt die Zahl gezählter Runden (Standard 8).
var study_ui := OS.get_environment("RS_STUDY_UI")
const AB_STATES := ["hidden", "plain", "glass"]
const AB_BLOCK_FRAMES := 90
const AB_SKIP_FRAMES := 12
var ab_rounds := maxi(1, int(OS.get_environment("RS_STUDY_ROUNDS"))) if OS.has_environment("RS_STUDY_ROUNDS") else 8
var ab_frame := 0
var ab_blocks: Dictionary = {} # "runde:zustand" -> Array[float] (Bildintervalle in ms)
# Hauptthread-Zeit je abgeholtem Hintergrund-Schritt (Main.last_apply_usec, ms).
var study_applies := 0
var study_apply_ms: Array[float] = []
# Wartezeit des Hauptthreads auf Hintergrund-Schritte bei Messbeginn (ms).
var study_wait_start := -1.0
# Frame-Abstände der Frames, die einen Schritt hochgeladen haben (ms).
var study_drawn_applies := 0
var study_apply_intervals: Array[float] = []

func _ready() -> void:
	# Nur die dokumentierte Variante ist gültig: ein Tippfehler oder eine leere
	# Umgebung landete früher still im Prototyp (Review zu #121); `prototype`
	# gibt es seit #174 D nicht mehr und bricht ebenfalls laut ab.
	if study_variant != "baseline":
		push_error("RS_STUDY_VARIANT muss 'baseline' sein, ist: '" + study_variant
			+ "' ('prototype' ist mit #174 D entfernt). Start über scripts/graphics-study.sh.")
		get_tree().quit(1)
		return
	if not _reject_levers():
		get_tree().quit(1)
		return
	super._ready()
	if sim == null:
		get_tree().quit(1)
		return
	study_start_yaw = cam_yaw
	if not study_ui in ["", "plain", "glass", "ab"]:
		push_error("RS_STUDY_UI muss leer, plain, glass oder ab sein, ist: '" + study_ui + "'")
		get_tree().quit(1)
		return
	# Ohne Studienmodus (interaktiver Start) ist die Bedienung wie in Main da.
	var ui_state := "glass"
	if not study_mode.is_empty():
		ui_state = {"": "hidden", "plain": "plain", "glass": "glass", "ab": "plain"}[study_ui]
	_study_set_ui(ui_state)
	if not study_mode.is_empty():
		active_fps_cap = 0
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		RenderingServer.frame_post_draw.connect(_study_drawn)
	print("STUDY ", JSON.stringify({"variant": study_variant, "debug": study_debug,
		"seed": sim_seed, "year": sim.currentYear(),
		"viewport": str(get_viewport().size), "quality": render_quality,
		"terrain_grid": terrain_grid,
		"target": str(cam_target), "distance": cam_dist, "yaw": cam_yaw,
		"pitch": cam_pitch, "mode": study_mode}))

## `RS_STUDY_LEVERS` gibt es nicht mehr: alle Hebel sind Produktion (#152).
## Ein alter Aufruf scheitert laut, statt still dasselbe Bild zu liefern.
func _reject_levers() -> bool:
	var raw := OS.get_environment("RS_STUDY_LEVERS")
	if raw.is_empty():
		return true
	push_error("RS_STUDY_LEVERS='%s': alle Hebel sind Produktion, die Studie hat keine mehr" % raw)
	return false

## Zur Laufzeit gebaute Studien-Fassung eines Produktions-Shaders: Godot 4.7
## lehnt #include einer Datei mit shader_type ab, deshalb wird das Define vor
## die Quelle gestellt (der Präprozessor läuft auf dem zusammengesetzten Code;
## alle Uniform-Namen bleiben gleich, gesetzte Werte bleiben am Material).
static func study_shader(path: String) -> Shader:
	var shader := Shader.new()
	shader.code = "#define FLUSSTAL_STUDY\n" + FileAccess.get_file_as_string(path)
	return shader

func _setup_scene() -> void:
	super._setup_scene()
	if not study_enabled:
		return
	terrain_mat.shader = study_shader("res://shaders/terrain.gdshader")
	terrain_mat.set_shader_parameter("study_debug",
		{"protect": 1, "forest": 2, "cavity": 3}.get(study_debug, 0))

## Die Debug-Ansicht der Schutzmaske liest sie im Terrain-Shader.
func _update_protect_mask(bytes: PackedByteArray) -> void:
	super._update_protect_mask(bytes)
	if study_enabled:
		terrain_mat.set_shader_parameter("protect_tex", protect_tex)

func _update_brush() -> void:
	if not study_mode.is_empty():
		brush_mi.visible = false
	else:
		super._update_brush()

func _process(delta: float) -> void:
	if not study_mode.is_empty():
		# Echte gerenderte Standbilder messen; Main darf den Renderloop nicht anhalten.
		last_activity_msec = Time.get_ticks_msec()
		study_elapsed += delta
		if study_mode == "orbit":
			cam_yaw = study_start_yaw + maxf(0, study_elapsed - 2.0) * 0.08
			_update_camera()
		elif study_mode == "simulation" and study_elapsed > 2.0:
			year_rate = 60.0
	super._process(delta)
	if study_elapsed > 2.0 and study_wait_start < 0.0:
		study_wait_start = sim.stepWaitMilliseconds()
	if step_applies != study_applies:
		study_applies = step_applies
		if study_elapsed > 2.0:
			study_apply_ms.append(last_apply_usec / 1000.0)
	if study_mode == "shot":
		# Gleiche Wasser-Animationsphase unabhängig von Shader-Kompilierzeiten.
		u_time = 1.0
		for mat in [terrain_mat, ocean_mat, river_mat, river_prev_mat]:
			if mat != null:
				mat.set_shader_parameter("u_time", u_time)
		# Wolkenkörper mitnehmen: Main.gd takten sie selbst, hier im Shot-Modus
		# sonst nicht — Körper und Schatten drifteten auseinander und die
		# Aufnahmen wären nicht reproduzierbar (Review zu #174 D).
		for mat in Lighting.cloud_body_materials(cloud_bodies):
			mat.set_shader_parameter("u_time", u_time)

## Bedienung auf einen Messzustand stellen: `hidden` (keine Bedienung), `plain`
## (Bedienung ohne Weichzeichner) oder `glass` (mit).
func _study_set_ui(state: String) -> void:
	for child in get_children():
		if child is CanvasLayer:
			child.visible = state != "hidden"
	get_tree().call_group(GLASS_BACKDROP_GROUP, "set_visible", state == "glass")

## Zustand des Blocks `block` (0-basiert): je Runde um einen Zustand gedreht.
@warning_ignore("integer_division")
static func _ab_state(block: int) -> String:
	var states := AB_STATES.size()
	return AB_STATES[(block % states + block / states) % states]

@warning_ignore("integer_division")
func _study_drawn_ab(now: int) -> void:
	if study_elapsed <= 2.0 or study_last_draw == 0:
		study_last_draw = now
		return
	var interval := float(now - study_last_draw) / 1000.0
	study_last_draw = now
	var block := ab_frame / AB_BLOCK_FRAMES
	var in_block := ab_frame % AB_BLOCK_FRAMES
	var round_index := block / AB_STATES.size()
	if in_block == 0:
		_study_set_ui(_ab_state(block))
	elif in_block >= AB_SKIP_FRAMES and round_index > 0:
		var key := "%d:%s" % [round_index, _ab_state(block)]
		if not ab_blocks.has(key):
			ab_blocks[key] = []
		ab_blocks[key].append(interval)
	ab_frame += 1
	if round_index > ab_rounds:
		RenderingServer.frame_post_draw.disconnect(_study_drawn)
		_study_report_ab()
		get_tree().quit()

@warning_ignore("integer_division")
static func _median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]

## p95 eines Blocks (wie `p95_ms` in STUDY_TIMING: Index (n − 1) · 0,95).
static func _p95(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[int((sorted.size() - 1) * 0.95)]

## Eine JSON-Zeile `STUDY_UI_AB`: je Zustand Median der Block-Mediane und der
## Block-p95 (je Block eine Zahl, dann der Median über die Runden), dazu Mittel
## und p95 aller Bilder gepoolt; außerdem die gepaarten Unterschiede JE RUNDE
## (plain − hidden, glass − plain, glass − hidden) für Median UND p95 des Blocks,
## mit Median, Minimum und Maximum über die Runden. Der gepoolte p95 verträgt
## Fremdlast schlecht (einzelne Ausreißer-Blöcke ziehen ihn hoch); der Median
## der gepaarten Block-Unterschiede nicht.
func _study_report_ab() -> void:
	var per_state := {}
	var medians := {} # zustand -> Array[float] je Runde
	var p95s := {} # zustand -> Array[float] je Runde
	for state in AB_STATES:
		var pooled: Array[float] = []
		var block_medians: Array[float] = []
		var block_p95s: Array[float] = []
		for r in range(1, ab_rounds + 1):
			var values: Array = ab_blocks.get("%d:%s" % [r, state], [])
			pooled.append_array(values)
			block_medians.append(_median(values))
			block_p95s.append(_p95(values))
		medians[state] = block_medians
		p95s[state] = block_p95s
		pooled.sort()
		var total := 0.0
		for v in pooled:
			total += v
		per_state[state] = {"median_of_blocks_ms": _median(block_medians),
			"p95_of_blocks_ms": _median(block_p95s),
			"mean_ms": total / pooled.size(),
			"p95_ms": pooled[int((pooled.size() - 1) * 0.95)],
			"frames": pooled.size()}
	var deltas := {}
	for pair in [["plain", "hidden"], ["glass", "plain"], ["glass", "hidden"]]:
		for metric in [["", medians], ["p95_", p95s]]:
			var d: Array[float] = []
			for r in ab_rounds:
				d.append(metric[1][pair[0]][r] - metric[1][pair[1]][r])
			var sorted := d.duplicate()
			sorted.sort()
			deltas["%s_minus_%s_%sms" % [pair[0], pair[1], metric[0]]] = {"median": _median(d),
				"min": sorted[0], "max": sorted.back(), "per_round": d}
	print("STUDY_UI_AB ", JSON.stringify({"states": per_state, "deltas": deltas,
		"rounds": ab_rounds, "block_frames": AB_BLOCK_FRAMES, "skip_frames": AB_SKIP_FRAMES,
		"viewport": str(get_viewport().size), "mode": study_mode, "quality": render_quality,
		"seed": sim_seed, "year": sim.currentYear(), "target": str(cam_target),
		"distance": cam_dist, "yaw": study_start_yaw, "pitch": cam_pitch,
		"blur": glass_material != null}))

func _study_drawn() -> void:
	var now := Time.get_ticks_usec()
	study_frames += 1
	if study_ui == "ab":
		_study_drawn_ab(now)
		return
	if study_elapsed > 2.0 and study_last_draw != 0:
		var interval := float(now - study_last_draw) / 1000.0
		study_intervals.append(interval)
		if step_applies != study_drawn_applies:
			study_apply_intervals.append(interval)
	study_drawn_applies = step_applies
	study_last_draw = now
	var finished := study_frames >= 60 if study_mode == "shot" else study_elapsed >= 12.0
	if not finished:
		return
	RenderingServer.frame_post_draw.disconnect(_study_drawn)
	# Wartezeit IM Messfenster: vor jedem weiteren Sim-Aufruf ablesen, die
	# warten selbst auf einen noch rechnenden Schritt.
	var waited: float = sim.stepWaitMilliseconds() - maxf(study_wait_start, 0.0)
	# Bei Movie-Läufen schreibt Godot selbst den Film; kein zusätzliches PNG
	# (Review zu #121, konsistent mit dem Timing-Zweig darunter).
	if not study_output.is_empty() and Engine.get_write_movie_path().is_empty():
		var err := get_viewport().get_texture().get_image().save_png(study_output + ".png")
		if err != OK:
			push_error("Studienaufnahme konnte nicht gespeichert werden")
			get_tree().quit(1)
			return
	if not study_intervals.is_empty() and Engine.get_write_movie_path().is_empty():
		study_intervals.sort()
		var total := 0.0
		var over_budget := 0
		for interval in study_intervals:
			total += interval
			if interval > 33.3:
				over_budget += 1
		# Hochladen der Hintergrund-Schritte (nur Betrieb `simulation`):
		# Median und Maximum der Hauptthread-Zeit je Schritt.
		study_apply_ms.sort()
		var apply_median: float = study_apply_ms[study_apply_ms.size() / 2] \
			if not study_apply_ms.is_empty() else 0.0
		var apply_max: float = study_apply_ms.back() if not study_apply_ms.is_empty() else 0.0
		# Die Frames mit Hochladen selbst: ihr längster Abstand ist die Frage,
		# ob das Hochladen das Budget sprengt.
		study_apply_intervals.sort()
		var apply_frame_median: float = study_apply_intervals[study_apply_intervals.size() / 2] \
			if not study_apply_intervals.is_empty() else 0.0
		var apply_frame_max: float = study_apply_intervals.back() \
			if not study_apply_intervals.is_empty() else 0.0
		print("STUDY_TIMING ", JSON.stringify({"rendered_frames": study_intervals.size(),
			"mean_ms": total / study_intervals.size(),
			"p95_ms": study_intervals[int((study_intervals.size() - 1) * 0.95)],
			"p99_ms": study_intervals[int((study_intervals.size() - 1) * 0.99)],
			"max_ms": study_intervals.back(), "over_budget_frames": over_budget,
			"viewport": str(get_viewport().size), "mode": study_mode,
			"quality": render_quality, "terrain_grid": terrain_grid,
			"seed": sim_seed, "year": shown_year, "target": str(cam_target),
			"distance": cam_dist, "yaw": study_start_yaw, "pitch": cam_pitch,
			"variant": study_variant,
			"steps_applied": study_apply_ms.size(), "apply_median_ms": apply_median,
			"apply_max_ms": apply_max, "step_wait_ms": waited,
			"apply_frame_median_ms": apply_frame_median, "apply_frame_max_ms": apply_frame_max,
			"movie": false }))
	get_tree().quit()

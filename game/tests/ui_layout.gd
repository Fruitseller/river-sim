extends SceneTree
## Headless-Wächter der Bedienung (Issue #174, Paket E):
##   godot --headless --path game --script res://tests/ui_layout.gd
##
## Geprüft wird, was ohne Auge prüfbar ist; ob es aussieht wie Vorlage B/C,
## entscheidet der Projekteigner am Bild (Abnahmebogen #174, Punkte 41–45).
##  - Layout: oben links Titel/Jahr/Tempo und Werkzeugpalette, oben rechts die
##    Zeitsprünge, unten rechts Diagnose/Welt/Kamera/Seed, unten Mitte die
##    Tastenhilfe; jede Spalte UI_MARGIN von ihrem Rand, im Grundzustand
##    überlappt keine, auch im kleinen Standardfenster; die Diagnose klappt
##    auf und wieder zu, ohne
##    einen leeren Streifen zu hinterlassen;
##  - ein gemeinsames Theme, keine Overrides an einzelnen Controls;
##  - jedes Werkzeug trägt sein gezeichnetes Icon, Taste 1–6 hebt den
##    aktiven Knopf hervor; Tempo-Leiste ⏸ ▶ ⏩;
##  - Kamera-Presets auf F1–F3 (auch weich angefahren): Diorama rahmt das
##    Land, Tal und Nah zielen auf den größten Lauf, nie aufs Meer;
##  - Pinselkuppel: Rand auf der Fläche, Scheitel im Profil (1 − d²)^p.
## Erzeugt einen `SimNode` samt Produktionswelt (Laufzeit wie `smoke.gd`).

const BuildStamp = preload("res://scripts/BuildStamp.gd")
const Main = preload("res://scripts/Main.gd")
const UiIcon = preload("res://scripts/UiIcon.gd")
const WINDOW := Vector2(1152, 648)

var failures := 0
var main: Node
var started := false

func _initialize() -> void:
	if not ClassDB.class_exists("SimNode"):
		print("FAIL: SimNode nicht registriert (godot --headless --path game --import)")
		quit(1)
		return
	var probe: Object = ClassDB.instantiate("SimNode")
	if not BuildStamp.check(probe):
		quit(1)
		return
	probe.free()
	main = Main.new()
	root.add_child(main)

func _process(_delta: float) -> bool:
	if started or main == null or not main.is_node_ready():
		return false
	started = true
	_run()
	return false

func _run() -> void:
	# Das Headless-Fenster ist 64 × 64 Pixel groß; geprüft wird das Layout im
	# kleinsten Fenster, das ein Spieler sieht (Godots Standardgröße). Die
	# Spalten hängen an der Vollbild-Ebene `hud`, also genügt deren Größe.
	main.hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	main.hud.size = WINDOW
	# Layout und Anpassung der Spalten laufen verzögert (minimum_size_changed).
	await _frames(3)
	_check_theme()
	_check_corners("Start")
	await _check_debug_toggle()
	_check_tools()
	_check_speed()
	_check_camera_presets()
	_check_brush_dome()
	main.queue_free()
	if failures > 0:
		quit(1)
		return
	print("UI_LAYOUT_OK")
	quit(0)

func _frames(n: int) -> void:
	for i in n:
		await process_frame

func _check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		print("FAIL: ", message)

func _controls(node: Node, out: Array[Control]) -> Array[Control]:
	for child in node.get_children():
		if child is Control:
			out.append(child)
		_controls(child, out)
	return out

func _check_theme() -> void:
	var theme: Theme = load(Main.UI_THEME)
	_check(theme != null and main.hud.theme == theme, "Bedienung hängt am gemeinsamen Theme")
	for c in _controls(main.hud, []):
		for name in ["panel", "normal", "pressed", "hover"]:
			_check(not c.has_theme_stylebox_override(name),
				"%s überschreibt Stilbox %s" % [c.get_path(), name])
		_check(not c.has_theme_color_override("font_color"), "%s überschreibt font_color" % c.get_path())
		_check(not c.has_theme_font_size_override("font_size"), "%s überschreibt font_size" % c.get_path())
		_check(not c.has_theme_constant_override("separation"), "%s überschreibt separation" % c.get_path())
		if c is PanelContainer:
			_check(c.get_theme_stylebox("panel") == theme.get_stylebox("panel", "PanelContainer"),
				"Panel %s nimmt das Glas-Panel des Themes" % c.get_path())
		if c is Label and c.theme_type_variation != &"":
			_check(theme.get_type_variation_base(c.theme_type_variation) == &"Label",
				"Label-Variante %s steht im Theme" % c.theme_type_variation)

## Die vier Spalten in Bauordnung: oben links, oben rechts, unten rechts, unten Mitte.
## Überlappung nur im Grundzustand: die aufgeklappte Diagnose ist im kleinen
## Standardfenster höher als der freie Platz unter der Zeitsprung-Leiste.
func _check_corners(when: String, overlap := true) -> void:
	var vp: Vector2 = main.hud.get_rect().size
	var cols: Array = main.hud.get_children()
	_check(cols.size() == 4, "%s: vier Randspalten (%d)" % [when, cols.size()])
	if cols.size() != 4:
		return
	var m: float = Main.UI_MARGIN
	var r: Array[Rect2] = []
	for c in cols:
		r.append((c as Control).get_global_rect())
	_check(r[0].position.is_equal_approx(Vector2(m, m)), "%s: oben links bei %s" % [when, r[0]])
	_check(is_equal_approx(r[1].end.x, vp.x - m) and is_equal_approx(r[1].position.y, m),
		"%s: oben rechts bei %s (Fenster %s)" % [when, r[1], vp])
	_check(r[2].end.is_equal_approx(vp - Vector2(m, m)), "%s: unten rechts bei %s (Fenster %s)" % [when, r[2], vp])
	_check(is_equal_approx(r[3].end.y, vp.y - m)
		and is_equal_approx(r[3].get_center().x, vp.x * 0.5), "%s: unten Mitte bei %s" % [when, r[3]])
	for i in 4:
		_check(r[i].size.x > 0 and r[i].size.y > 0, "%s: Spalte %d hat Inhalt" % [when, i])
		for j in range(i + 1, 4):
			_check(not overlap or not r[i].intersects(r[j]), "%s: Spalten %d und %d überlappen (%s / %s, Fenster %s)"
				% [when, i, j, r[i], r[j], vp])

func _check_debug_toggle() -> void:
	var column: Control = main.hud.get_child(2)
	var closed := column.size
	_check(not main.debug_panel.visible, "Diagnose startet zugeklappt")
	var toggle: Button = null
	for c in _controls(column, []):
		if c is Button and c.text == "Diagnose-Ansicht":
			toggle = c
	_check(toggle != null, "Knopf Diagnose-Ansicht unten rechts")
	if toggle == null:
		return
	toggle.button_pressed = true
	await _frames(3)
	_check(main.debug_panel.visible and column.size.y > closed.y, "Diagnose klappt auf")
	_check_corners("Diagnose offen", false)
	toggle.button_pressed = false
	await _frames(3)
	_check(not main.debug_panel.visible and column.size.is_equal_approx(closed),
		"Diagnose klappt zu ohne leeren Streifen (%s → %s)" % [closed, column.size])

func _check_tools() -> void:
	_check(main.tool_buttons.size() == Main.TOOLS.size(), "Ein Knopf je Werkzeug")
	for t in mini(main.tool_buttons.size(), Main.TOOLS.size()):
		var icons: Array = main.tool_buttons[t].get_children().filter(func(c): return c is UiIcon)
		var id: String = Main.TOOLS[t]["icon"]
		_check(icons.size() == 1 and icons[0].icon_id == id and UiIcon.has_icon(id),
			"%s trägt das gezeichnete Icon %s" % [Main.TOOLS[t]["name"], id])
	var key := InputEventKey.new()
	key.keycode = KEY_3
	key.pressed = true
	main._unhandled_input(key)
	_check(main.current_tool == 2, "Taste 3 wählt das dritte Werkzeug")
	for t in main.tool_buttons.size():
		_check(main.tool_buttons[t].button_pressed == (t == 2),
			"Nur das aktive Werkzeug ist hervorgehoben (Knopf %d)" % t)
	main.current_tool = 0
	main.tool_buttons[0].button_pressed = true

func _check_speed() -> void:
	main._set_rate(0.0)
	_check(main.pause_button.button_pressed and not main.play_button.button_pressed, "⏸ aktiv in der Pause")
	var last: float = main.last_rate
	main._faster()
	var i := Main.SPEEDS.find(last)
	_check(main.year_rate == Main.SPEEDS[(i + 1) % Main.SPEEDS.size()],
		"⏩ schaltet von %s auf die nächste Stufe (%s)" % [last, main.year_rate])
	_check(main.play_button.button_pressed and not main.pause_button.button_pressed, "▶ aktiv im Zeitraffer")
	_check(main.rate_label.text.contains("%d J./Sek." % int(main.year_rate)), "Tempo steht in J./Sek. da")
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.pressed = true
	main._unhandled_input(space)
	_check(main.year_rate == 0.0, "Leertaste pausiert")
	main._unhandled_input(space)
	_check(main.year_rate == main.last_rate and main.year_rate > 0.0, "Leertaste spielt das letzte Tempo")
	main._set_rate(0.0)

func _check_camera_presets() -> void:
	_check(Main.CAMERA_PRESETS.size() == 3, "Drei Kamera-Presets (Diorama, Tal, Nah)")
	var h: PackedFloat32Array = main.sim.heights()
	var n: int = main.N
	# Rahmen-Rechnung an einer bekannten Form: ein Landquadrat der halben
	# Kartenbreite, Draufsicht. Zielt auf seine Mitte und braucht für die
	# halbe Füllung doppelt so viel Abstand wie für die volle.
	var sq := PackedFloat32Array()
	sq.resize(101 * 101)
	for j in 101:
		for i in 101:
			sq[j * 101 + i] = 0.5 if (i >= 25 and i <= 75 and j >= 25 and j <= 75) else 0.0
	var full := Main.frame_land(sq, 101, 0.1, 100.0, 0.0, PI * 0.5 - 1e-4, 60.0, 1.0, 1.0)
	var half_fill := Main.frame_land(sq, 101, 0.1, 100.0, 0.0, PI * 0.5 - 1e-4, 60.0, 1.0, 0.5)
	_check(not full.is_empty() and Vector2(full["target"].x, full["target"].z).length() < 1e-3,
		"Rahmen zielt auf die Mitte der Land-Box")
	if not full.is_empty():
		# Kante 25 Einheiten von der Mitte, halber FOV 30° → d = 25 / tan 30°
		# (das Ziel liegt auf der Landhöhe, gemessen wird von dort).
		_check(absf(full["dist"] - 25.0 / tan(deg_to_rad(30.0))) < 0.05,
			"Rahmen: Land-Box füllt das Bild (dist %.2f)" % full["dist"])
		_check(absf(half_fill["dist"] - 2.0 * full["dist"]) < 0.1,
			"Rahmen: halbe Füllung, doppelter Abstand")
	_check(Main.frame_land(PackedFloat32Array([0.0, 0.0, 0.0, 0.0]), 2, 0.1, 10.0, 0.0, 0.6, 55.0,
		1.0, 0.85).is_empty(), "Ohne Land kein Rahmen")

	main.cam_target = Vector3(10.0, 0.0, -12.0)
	for c in Main.CAMERA_PRESETS.size():
		var p: Dictionary = Main.CAMERA_PRESETS[c]
		main._apply_camera_preset(c, false)
		# Pitch aus der Tabelle; nur eine verdeckte Sichtlinie hebt ihn an.
		_check(main.cam_pitch >= p["pitch"] - 1e-6 and main.cam_pitch < 1.3 + 1e-6,
			"Preset %s setzt den Pitch (%.2f)" % [p["id"], main.cam_pitch])
		var t: Vector3 = main.cam_target
		var gx: float = (t.x + main.half) / main.step
		var gz: float = (t.z + main.half) / main.step
		if p.has("fill"):
			_check_diorama_fill(p, h, n)
			continue
		_check(is_equal_approx(main.cam_dist, p["dist"]), "Preset %s setzt die Distanz" % p["id"])
		_check(main._sample_h(gx, gz) > main.sea, "Preset %s blickt auf Land, nicht aufs Meer" % p["id"])
		_check(is_equal_approx(t.y, main._surface_y_at(t)), "Preset %s: Ziel auf der Fläche" % p["id"])
		var r: Dictionary = Main.river_view(h, main.sim.flowArea(), main.sim.receivers(), n,
			main.sea, main.world_size, p["upstream"])
		_check(not r.is_empty(), "Preset %s findet den größten Lauf" % p["id"])
		if r.is_empty():
			continue
		var mouth: int = r["mouth"]
		var mi := mouth % n
		var mj := mouth / n
		# Auslass = Küste ODER Kartenrand: ohne Randabstand (#175) läuft der
		# größte Lauf mancher Welt über den Rand ab (so die CI-Welt).
		var outlet := mi == 0 or mj == 0 or mi == n - 1 or mj == n - 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var i: int = clampi(mi + d.x, 0, n - 1)
			var j: int = clampi(mj + d.y, 0, n - 1)
			outlet = outlet or h[j * n + i] <= main.sea
		_check(h[mouth] > main.sea and outlet,
			"Preset %s: Mündung ist Landzelle an Küste oder Kartenrand" % p["id"])
		var mouth_pos := Vector2(mi * main.step - main.half, mj * main.step - main.half)
		var cam_dir := Vector2(sin(main.cam_yaw), cos(main.cam_yaw))
		_check(cam_dir.dot(mouth_pos - Vector2(t.x, t.z)) > 0.0,
			"Preset %s: Kamera steht auf der Mündungsseite" % p["id"])
		var eye: Vector3 = main.cam.position
		_check(eye.y > main._surface_y_at(eye), "Preset %s: Kamera über dem Gelände" % p["id"])
		# Schräg talaufwärts, nicht senkrecht von oben: die Sichtlinie ist in
		# den Prüfwelten frei (auf der CI-Welt mündet der Lauf am Kartenrand;
		# draußen liegt nur Meer, kein geklemmtes Randgelände).
		_check(main.cam_pitch < p["pitch"] + 0.3,
			"Preset %s bleibt schräg (pitch %.2f)" % [p["id"], main.cam_pitch])
		var blocked: float = main.sight_block(t, main.cam_yaw, p["pitch"], main.cam_dist)
		if blocked >= 0.0: # Protokoll: wo die Sichtlinie bei Tabellen-Pitch anstößt
			var cpp := cos(float(p["pitch"]))
			var eye0: Vector3 = t + Vector3(sin(main.cam_yaw) * cpp, sin(float(p["pitch"])),
				cos(main.cam_yaw) * cpp) * main.cam_dist
			var hit: Vector3 = t.lerp(eye0, blocked)
			print("UI_CAMERA_SIGHT %s blocked t %.2f at (%.1f, %.1f) ray %.2f ground %.2f target_y %.2f"
				% [p["id"], blocked, hit.x, hit.z, hit.y, main._surface_y_at(hit), t.y])
		print("UI_CAMERA_PRESET %s target (%.1f, %.1f) yaw %.2f pitch %.2f mouth (%.1f, %.1f)"
			% [p["id"], t.x, t.z, main.cam_yaw, main.cam_pitch, mouth_pos.x, mouth_pos.y])
	# Taste: F2 fährt „Tal" weich an; nach der Fahrt steht die Kamera dort.
	var want: Dictionary = main.camera_preset_view(1)
	main._apply_camera_preset(0, false)
	var key := InputEventKey.new()
	key.keycode = KEY_F2
	key.pressed = true
	main._unhandled_input(key)
	_check(main.camera_tween != null and main.camera_tween.is_valid(), "F2 startet eine Kamerafahrt")
	if main.camera_tween != null:
		main.camera_tween.custom_step(Main.CAMERA_PRESET_SECONDS + 1.0)
	_check(is_equal_approx(main.cam_dist, want["dist"]) and is_equal_approx(main.cam_pitch, want["pitch"])
		and main.cam_target.is_equal_approx(want["target"])
		and is_zero_approx(wrapf(main.cam_yaw - want["yaw"], -PI, PI)),
		"F2 endet auf dem Preset Tal (dist %.2f, pitch %.2f)" % [main.cam_dist, main.cam_pitch])

## Diorama: nachgemessen mit Godots eigener Projektion. Die Landzellen reichen
## in der knapperen Bildrichtung bis `fill` (sofern die Distanz nicht am
## Zoom-Deckel hängt), alle liegen vor der Kamera und im Bild.
func _check_diorama_fill(p: Dictionary, h: PackedFloat32Array, n: int) -> void:
	var vp: Vector2 = main.get_viewport().get_visible_rect().size
	var reach := 0.0
	var behind := 0
	for j in range(0, n, 4):
		for i in range(0, n, 4):
			if h[j * n + i] <= main.sea:
				continue
			var w := Vector3(i * main.step - main.half, h[j * n + i] * Main.HSCALE, j * main.step - main.half)
			if main.cam.is_position_behind(w):
				behind += 1
				continue
			var s: Vector2 = main.cam.unproject_position(w) / vp * 2.0 - Vector2.ONE
			reach = maxf(reach, maxf(absf(s.x), absf(s.y)))
	var capped: bool = is_equal_approx(main.cam_dist, Main.CAM_DIST_MIN) \
		or is_equal_approx(main.cam_dist, main.world_size * 4.0)
	_check(behind == 0, "Diorama: alles Land vor der Kamera (%d dahinter)" % behind)
	_check(absf(reach - p["fill"]) < 0.02 or (capped and reach < 1.0),
		"Diorama: Land füllt das Bild zu %.2f (Soll %.2f, dist %.1f)" % [reach, p["fill"], main.cam_dist])
	print("UI_CAMERA_PRESET diorama dist %.1f fill %.3f target (%.1f, %.1f)"
		% [main.cam_dist, reach, main.cam_target.x, main.cam_target.z])

func _check_brush_dome() -> void:
	# Landzelle nahe der Mitte als Zentrum.
	var h: PackedFloat32Array = main.sim.heights()
	var n: int = main.N
	var cell := -1
	for j in range(n / 3, 2 * n / 3):
		for i in range(n / 3, 2 * n / 3):
			if h[j * n + i] > main.sea + 0.1:
				cell = j * n + i
				break
		if cell >= 0:
			break
	_check(cell >= 0, "Testwelt braucht Land in der Mitte")
	if cell < 0:
		return
	var gx := float(cell % n)
	var gz := float(cell / n)
	var center := Vector3(gx * main.step - main.half, 0.0, gz * main.step - main.half)
	center.y = main._surface_y(gx, gz)
	var radius := 2.0
	var t0 := Time.get_ticks_usec()
	var dome: Array = main.brush_dome(center, radius, Main.BRUSH_FALLOFF_POWER)
	var dome_us := Time.get_ticks_usec() - t0
	var verts: PackedVector3Array = dome[0]
	var colors: PackedColorArray = dome[1]
	var segments: int = Main.BRUSH_DOME_RINGS * Main.BRUSH_DOME_SEGMENTS \
		+ Main.BRUSH_DOME_MERIDIANS * Main.BRUSH_DOME_RINGS * 2
	_check(verts.size() == 2 * segments and colors.size() == verts.size(),
		"Kuppel aus Linienpaaren (%d Punkte)" % verts.size())
	if verts.is_empty():
		return
	# Rand (Punkt 0, d = 1): auf der sichtbaren Fläche plus Lift.
	var rim := verts[0] + center
	var rim_surface: float = main._surface_y((rim.x + main.half) / main.step, (rim.z + main.half) / main.step)
	_check(absf(rim.y - (rim_surface + Main.BRUSH_DOME_LIFT)) < 1e-3,
		"Kuppelrand liegt auf der Fläche (y %.3f, Fläche %.3f)" % [rim.y, rim_surface])
	_check(absf(Vector2(verts[0].x, verts[0].z).length() - radius) < 1e-3, "Rand im Pinselradius")
	# Scheitel (letzter Punkt des letzten Meridians, d = 0): Lift + r · Höhe.
	var apex := verts[verts.size() - 1]
	_check(absf(apex.y - (Main.BRUSH_DOME_LIFT + radius * Main.BRUSH_DOME_HEIGHT)) < 1e-3,
		"Scheitel trägt das volle Profil (y %.3f)" % apex.y)
	# Profil: die Spitzhacke (p = 4) ist bei halbem Radius niedriger als p = 2.
	_check(Main.brush_weight(0.5, 4.0) < Main.brush_weight(0.5, 2.0)
		and is_equal_approx(Main.brush_weight(0.5, 2.0), 0.5625)
		and Main.brush_weight(1.0, 2.0) == 0.0, "Profil (1 − d²)^p")
	# Keine Leistungsbehauptung, nur das Protokoll: Kosten eines Kuppel-Baus
	# auf diesem Rechner (gebaut wird nur bei Änderung, s. Main.brush_key).
	print("UI_BRUSH_DOME_US ", dome_us)

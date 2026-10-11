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
##  - Kamera-Presets auf F1–F3 (auch weich angefahren);
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
	var look := Vector3(10.0, 0.0, -12.0)
	for c in Main.CAMERA_PRESETS.size():
		var p: Dictionary = Main.CAMERA_PRESETS[c]
		main.cam_target = look
		main._apply_camera_preset(c, false)
		_check(is_equal_approx(main.cam_dist, p["dist"]) and is_equal_approx(main.cam_pitch, p["pitch"]),
			"Preset %s setzt Distanz und Pitch" % p["id"])
		if p.get("centered", false):
			_check(main.cam_target.is_equal_approx(Vector3.ZERO), "Diorama blickt auf die Inselmitte")
		else:
			_check(is_equal_approx(main.cam_target.x, look.x) and is_equal_approx(main.cam_target.z, look.z)
				and is_equal_approx(main.cam_target.y, main._surface_y_at(look)),
				"Preset %s behält den Blickpunkt auf der Fläche" % p["id"])
	# Taste: F2 fährt „Tal" weich an; nach der Fahrt steht die Kamera dort.
	var key := InputEventKey.new()
	key.keycode = KEY_F2
	key.pressed = true
	main._unhandled_input(key)
	_check(main.camera_tween != null and main.camera_tween.is_valid(), "F2 startet eine Kamerafahrt")
	if main.camera_tween != null:
		main.camera_tween.custom_step(Main.CAMERA_PRESET_SECONDS + 1.0)
	_check(is_equal_approx(main.cam_dist, Main.CAMERA_PRESETS[1]["dist"])
		and is_equal_approx(main.cam_pitch, Main.CAMERA_PRESETS[1]["pitch"]),
		"F2 endet auf dem Preset Tal (dist %.2f, pitch %.2f)" % [main.cam_dist, main.cam_pitch])

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

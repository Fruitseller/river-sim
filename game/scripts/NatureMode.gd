extends Node3D
## Mutter-Natur-Prototyp (Issue #223): Anzeige und Bedienung des Versuchs.
##
## Regeln und Zustand leben in SimCore (`SimGame.NatureGame`, getragen von der
## Welt-Sitzung); dieses Skript liest nur `sim.natureState()` und zeichnet:
## Häuser und Felder als Klötzchen in Zustandsfarben, die Eingriffe des
## Spielers, ein Panel je Siedlung (Zustand, Grund, Vorrat, Bevölkerung,
## Ernteverlauf), Budget, Versuchsende und Neustart. Gestartet wird es von
## `Main.gd` (`RS_NATURE=1` oder `-- --nature`), der Sandkasten bleibt sonst
## unverändert. Spielanleitung: docs/nature-prototype.md.

## Tempo des Versuchs (Issue #223: 5 J./Sek.); 1 J./Sek. zum Vergleich.
const RATES := [1.0, 5.0]
const DEFAULT_RATE := 5.0
## Erlaubte Werkzeuge (Rohwerte von BrushTool, == NatureGame.allowedTools).
const ALLOWED_MODES := [0, 1, 5]
const PICKAXE_MODE := 5

const STATUS_COLORS := [
	Color(0.93, 0.91, 0.84), # stabil
	Color(0.95, 0.78, 0.30), # unterversorgt
	Color(0.92, 0.45, 0.22), # Abwanderung
	Color(0.35, 0.35, 0.37), # verlassen
]
const STATUS_VARIATIONS := [&"OkLabel", &"WarnLabel", &"AlertLabel", &"StatsLabel"]
const BRUSH_MESSAGES := {
	1: "Dieses Werkzeug ist im Versuch gesperrt (erlaubt: Anheben, Absenken, Spitzhacke).",
	2: "Zu nah an Häusern oder Feldern — Mutter Natur wirkt über den Fluss, nicht direkt.",
	3: "Eingriffsbudget aufgebraucht.",
	4: "Der Versuch ist beendet — Neustart unten links.",
}

var main: Node
var sim: Object
var state: Dictionary = {}
var houses_mm: MultiMeshInstance3D
var fields_mm: MultiMeshInstance3D
var edits_mm: MultiMeshInstance3D
var year_label: Label
var budget_bar: ProgressBar
var budget_label: Label
var message_label: Label
var end_label: Label
var settlement_labels: Array = [] # je Siedlung [Kopf, Zustand, Zahlen, Verlauf]
var announced_outcome := 0
var message_until := 0

func setup(main_node: Node) -> void:
	main = main_node
	sim = main.sim
	state = sim.natureState()
	_restrict_tools()
	_build_markers()
	_build_panel()
	main.last_rate = DEFAULT_RATE # Leertaste / ▶ spielt 5 J./Sek.
	main._set_rate(0.0)           # Start pausiert: erst umsehen
	refresh()
	print("NATURE_MODE n=", main.N, " settlements=", state.get("settlement_count", 0))

## Werkzeugleiste auf die erlaubten Werkzeuge kürzen, Spitzhacke wählen und
## den Radius-Regler auf die Deckelung des Versuchs setzen
## (NatureGame.maxBrushCells == Spitzhacken-Breite).
func _restrict_tools() -> void:
	var tools: Array = main.get_script().get_script_constant_map()["TOOLS"]
	for t in tools.size():
		main.tool_buttons[t].visible = ALLOWED_MODES.has(tools[t]["mode"])
		if tools[t]["mode"] == PICKAXE_MODE:
			main.current_tool = t
			main.tool_buttons[t].set_pressed_no_signal(true)
	var cap: float = main.pick_radius_cap
	main.radius_slider.min_value = cap * 0.4
	main.radius_slider.step = cap * 0.1
	main.radius_slider.max_value = cap
	main.radius_slider.value = cap

func _cell_pos(k: int, lift: float) -> Vector3:
	var gx := float(k % main.N)
	var gz := float(k / main.N)
	var x: float = gx * main.step - main.half
	var z: float = gz * main.step - main.half
	return Vector3(x, main._surface_y(gx, gz) + lift, z)

func _multimesh(mesh: PrimitiveMesh) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	mesh.material = mat
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mi)
	return mi

func _build_markers() -> void:
	var cell: float = main.step
	var house := BoxMesh.new()
	house.size = Vector3(cell * 0.75, cell * 0.9, cell * 0.75)
	houses_mm = _multimesh(house)
	var field := BoxMesh.new()
	field.size = Vector3(cell * 0.92, cell * 0.06, cell * 0.92)
	fields_mm = _multimesh(field)
	var edit := BoxMesh.new()
	edit.size = Vector3(cell * 0.3, cell * 0.3, cell * 0.3)
	edits_mm = _multimesh(edit)

func _build_panel() -> void:
	var corner: VBoxContainer = main._corner(Control.PRESET_BOTTOM_LEFT)
	var vb: VBoxContainer = main._panel(corner)
	vb.custom_minimum_size = Vector2(380, 0)
	main._label(vb, "MUTTER NATUR — VERSUCH", &"SectionLabel")
	var help: Label = main._label(vb, "Ziel: Talheim zum Aufgeben bringen. Häuser und Felder "
		+ "sind tabu — lenke den Fluss um (Spitzhacke) oder staue ihn (Anheben). "
		+ "Leertaste: Pause/Weiter.", &"HintLabel")
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	year_label = main._label(vb, "", &"YearLabel")
	budget_label = main._label(vb, "", &"StatsLabel")
	budget_bar = ProgressBar.new()
	budget_bar.show_percentage = false
	budget_bar.custom_minimum_size = Vector2(0, 8)
	budget_bar.max_value = 1.0
	vb.add_child(budget_bar)
	for s in state.get("settlement_count", 0):
		vb.add_child(HSeparator.new())
		var head: Label = main._label(vb, "", &"StatusLabel")
		var status: Label = main._label(vb, "", &"OkLabel")
		var numbers: Label = main._label(vb, "", &"StatsLabel")
		var history: Label = main._label(vb, "", &"StatsLabel")
		settlement_labels.append([head, status, numbers, history])
	message_label = main._label(vb, "", &"WarnLabel")
	message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	end_label = main._label(vb, "", &"TitleLabel")
	end_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	end_label.visible = false
	var row := HBoxContainer.new()
	vb.add_child(row)
	var group := ButtonGroup.new()
	for r in RATES:
		var b: Button = main._mk_button("%d J./Sek." % int(r), true, group)
		b.set_pressed_no_signal(r == DEFAULT_RATE)
		b.pressed.connect(func(): main._set_rate(r))
		row.add_child(b)
	var restart: Button = main._mk_button("Neustart", false, null)
	restart.tooltip_text = "Derselbe Startzustand, neues Budget"
	restart.pressed.connect(_restart)
	row.add_child(restart)

func _restart() -> void:
	main._nature_restart()
	announced_outcome = 0
	end_label.visible = false
	message_label.text = ""

## Nach jedem hochgeladenen Frame (Main._apply_frame) und nach Strichen:
## Spielstand neu lesen und zeichnen. Läuft nie, während ein Schritt rechnet.
func refresh() -> void:
	state = sim.natureState()
	if state.is_empty():
		return
	_update_markers()
	_update_panel()
	var outcome: int = state["outcome"]
	if outcome != 0 and announced_outcome == 0:
		announced_outcome = outcome
		main._set_rate(0.0)
		end_label.visible = true
		if outcome == 1:
			end_label.text = "Talheim ist verlassen — Mutter Natur gewinnt nach %d Jahren." \
				% state["year"]
		else:
			end_label.text = "Talheim hat %d Jahre gehalten — Versuch verloren." % state["year"]
		print("NATURE_OUTCOME ", outcome, " year=", state["year"], " strokes=", state["strokes"])

## Ergebnis des letzten Pinselstrichs anzeigen (gesperrt, Budget …).
func after_stroke() -> void:
	var r: int = sim.natureLastBrushResult()
	if BRUSH_MESSAGES.has(r):
		message_label.text = BRUSH_MESSAGES[r]
		message_until = Time.get_ticks_msec() + 2500
	refresh()

func _update_markers() -> void:
	var house_xf: Array = []
	var house_col: Array = []
	var field_xf: Array = []
	var field_col: Array = []
	for s in state["settlement_count"]:
		var st: Dictionary = state["settlements"][s]
		var col: Color = STATUS_COLORS[st["status"]]
		var cell: float = main.step
		for k in st["houses"]:
			house_xf.append(Transform3D(Basis(), _cell_pos(k, cell * 0.45)))
			house_col.append(col.darkened(0.25) if st["repairing"] else col)
		var water: PackedFloat32Array = st["field_water"]
		var flooded: PackedByteArray = st["field_flooded"]
		var fields: PackedInt32Array = st["fields"]
		for f in fields.size():
			field_xf.append(Transform3D(Basis(), _cell_pos(fields[f], cell * 0.04)))
			if flooded[f] != 0:
				field_col.append(Color(0.22, 0.45, 0.85))
			elif st["status"] == 3:
				field_col.append(Color(0.45, 0.40, 0.33))
			else:
				# trocken (braun) → bewässert (grün)
				field_col.append(Color(0.62, 0.48, 0.25).lerp(Color(0.30, 0.62, 0.22), water[f]))
	_fill(houses_mm, house_xf, house_col)
	_fill(fields_mm, field_xf, field_col)
	var edit_xf: Array = []
	var edit_col: Array = []
	var repaired: PackedInt32Array = state["repaired"]
	for k in state["edited"]:
		edit_xf.append(Transform3D(Basis(), _cell_pos(k, main.step * 0.2)))
		edit_col.append(Color(0.95, 0.95, 0.95) if repaired.has(k) else Color(0.85, 0.25, 0.75))
	_fill(edits_mm, edit_xf, edit_col)

func _fill(mi: MultiMeshInstance3D, xf: Array, col: Array) -> void:
	var mm := mi.multimesh
	mm.instance_count = xf.size()
	for i in xf.size():
		mm.set_instance_transform(i, xf[i])
		mm.set_instance_color(i, col[i])

func _update_panel() -> void:
	year_label.text = "Jahr %d von %d" % [state["year"], state["trial_years"]]
	var budget: float = state["budget"]
	var left: float = state["budget_left"]
	budget_bar.value = left / budget if budget > 0.0 else 0.0
	budget_label.text = "Eingriffsbudget %d %%  ·  %d Striche" % [int(round(100.0 * left / budget)),
		state["strokes"]]
	if Time.get_ticks_msec() > message_until:
		message_label.text = ""
	for s in state["settlement_count"]:
		var st: Dictionary = state["settlements"][s]
		var labels: Array = settlement_labels[s]
		labels[0].text = "%s%s" % [st["name"], "  (Ziel)" if st["target"] else ""]
		var line: String = st["status_label"]
		if st["problem"] != 0:
			line += " — " + st["problem_label"]
		if st["repairing"]:
			line += " · baut deinen Eingriff zurück"
		labels[1].text = line
		labels[1].theme_type_variation = STATUS_VARIATIONS[st["status"]]
		labels[2].text = "Wasser %d %%  ·  Vorrat %.1f J.  ·  Leute %d %%  ·  %d schlechte J. in Folge" \
			% [int(round(100.0 * st["water"])), st["reserve"], int(round(100.0 * st["population"])),
				st["bad_streak"]]
		# Ernte in % des Bedarfs, älteste zuerst (letzte 12 Jahre).
		var parts: Array = []
		for h in st["harvests"]:
			parts.append(str(int(round(100.0 * h))))
		labels[3].text = "Ernten (%% vom Bedarf): " + (" · ".join(parts) if parts.size() > 0 else "—")

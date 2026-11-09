extends RefCounted
## Prüfungen des Mutter-Natur-Prototyps (Issue #223) an einem `Main.gd`, das
## mit RS_NATURE=1 gestartet wurde. Läuft in CI als Teil von
## `tests/ui_layout.gd` (der Bedienungs-Schritt; eine eigene CI-Stufe hätte
## eine Änderung an der Workflow-Datei gebraucht) und lokal allein über
## `tests/nature_mode.gd`.
##
## Geprüft wird, was ohne Auge prüfbar ist: Versuchskarte statt Sandkasten,
## Spielstand über die Brücke, gesperrte Striche, ein Durchstich am niedrigen
## Sattel trocknet Talheim aus, Jahre laufen über `sim.step`, Häuser/Felder
## werden gezeichnet, Neustart stellt den Anfang wieder her. Die Regeln selbst
## prüfen die headless XCTests (`NatureGameTests`); ob der Versuch Spaß macht,
## prüft kein Test.

const Main = preload("res://scripts/Main.gd")

static func _talheim(state: Dictionary) -> Dictionary:
	for s in state["settlement_count"]:
		if state["settlements"][s]["target"]:
			return state["settlements"][s]
	return {}

static func run(main: Node, check: Callable) -> void:
	var sim: Object = main.sim
	check.call(main.nature != null, "Main startet den Versuchsmodus")
	check.call(sim.natureActive(), "SimNode trägt den Versuch")
	check.call(main.N == 128, "Versuchskarte n=128 statt Sandkasten (N=%d)" % main.N)
	var state: Dictionary = sim.natureState()
	check.call(state.get("settlement_count", 0) == 3, "drei Siedlungen")
	check.call(state.get("year", -1) == 0 and state.get("outcome", -1) == 0, "Jahr 0, Versuch läuft")
	check.call(main.year_rate == 0.0 and main.last_rate == 5.0, "Start pausiert, ▶ spielt 5 J./Sek.")
	var talheim := _talheim(state)
	check.call(talheim.get("name", "") == "Talheim", "Zielsiedlung Talheim")
	check.call(talheim.get("water", 0.0) > 0.8, "Talheim startet bewässert")

	# Gesperrte Werkzeuge sind ausgeblendet, die Spitzhacke ist gewählt.
	var tools: Array = Main.TOOLS
	for t in tools.size():
		var allowed: bool = [0, 1, 5].has(tools[t]["mode"])
		check.call(main.tool_buttons[t].visible == allowed, "Werkzeug %s sichtbar=%s" % [tools[t]["name"], allowed])
	check.call(tools[main.current_tool]["mode"] == 5, "Spitzhacke gewählt")

	# Strich auf ein Haus: abgelehnt, Gelände unverändert.
	var house: int = talheim["houses"][0]
	var h0: PackedFloat32Array = sim.heights()
	sim.brush(5, float(house % main.N), float(house / main.N), 1.0, 1.0, 0.0)
	check.call(sim.natureLastBrushResult() == 2, "Strich am Haus abgelehnt (%d)" % sim.natureLastBrushResult())
	check.call(sim.heights() == h0, "abgelehnter Strich ändert nichts")
	sim.brush(2, 112.0, 70.0, 1.0, 1.0, 0.0)
	check.call(sim.natureLastBrushResult() == 1, "Glätten im Versuch gesperrt")

	# Versuch A: Durchstich am niedrigen Sattel (NatureScenario.lowSaddleCut).
	var x := 78.0
	while x >= 68.0:
		sim.brush(5, x, 52.0, 1.0, 1.0, 0.0)
		check.call(sim.natureLastBrushResult() == 0, "Hieb bei x=%d ausgeführt" % int(x))
		x -= 2.0
	sim.recomputeFlow()
	main._render_frame(Main.FRAME_SETTLED)
	state = main.nature.state
	talheim = _talheim(state)
	check.call(talheim["water"] < 0.4, "Durchstich trocknet Talheim aus (Wasser %.2f)" % talheim["water"])
	check.call(state["budget_left"] < state["budget"], "Budget verbraucht")
	check.call((state["edited"] as PackedInt32Array).size() > 0, "Eingriffe markiert")

	# Jahre laufen über die gemeinsame Sim-Zeit.
	sim.step(1.5)
	sim.step(1.5)
	main._render_frame(Main.FRAME_SETTLED)
	state = main.nature.state
	check.call(state["year"] == 3, "3 Sim-Jahre = 3 Spieljahre (%d)" % state["year"])
	talheim = _talheim(state)
	check.call((talheim["harvests"] as PackedFloat32Array).size() == 3, "Ernteverlauf je Jahr")

	# Markierungen: ein Klötzchen je Haus und Feldzelle.
	var houses := 0
	var fields := 0
	for s in state["settlement_count"]:
		houses += (state["settlements"][s]["houses"] as PackedInt32Array).size()
		fields += (state["settlements"][s]["fields"] as PackedInt32Array).size()
	check.call(main.nature.houses_mm.multimesh.instance_count == houses, "Häuser gezeichnet")
	check.call(main.nature.fields_mm.multimesh.instance_count == fields, "Felder gezeichnet")

	# Neustart: derselbe Anfang.
	main._nature_restart()
	state = main.nature.state
	check.call(state["year"] == 0 and state["strokes"] == 0, "Neustart setzt Jahr und Striche zurück")
	check.call(is_equal_approx(state["budget_left"], state["budget"]), "Neustart füllt das Budget")
	check.call(sim.heights() == h0, "Neustart: bit-gleicher Startzustand")


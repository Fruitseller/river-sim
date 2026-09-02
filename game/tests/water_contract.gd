## Vertragstabelle der Brücke (SimNode.waterContractNames/Values) als
## Dictionary (Name → Wert) — der EINE Helfer für die Godot-Vertragstests
## (Review zu #105: water_geometry.gd und river_ribbons.gd führten ihn
## doppelt). Ein fehlender Name fällt beim Zugriff im Aufrufer laut auf
## (Dictionary-Fehler), nicht still.
static func fetch(sim: Object) -> Dictionary:
	var names: PackedStringArray = sim.waterContractNames()
	var values: PackedFloat64Array = sim.waterContractValues()
	var out := {}
	for i in names.size():
		out[names[i]] = values[i]
	return out

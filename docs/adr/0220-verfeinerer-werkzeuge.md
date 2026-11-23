# Offline-Werkzeuge der Gelände-Verfeinerung: Dump, Lauf, Echtzeit-Aufnahme

Für Offline-Entwicklung, Stabilitätsnachweis und Kosten der Verfeinerung (#238) gibt es drei Werkzeuge mit festem Dateivertrag.

`tools/amplify_dump.gd` schreibt eine Zeitraffer-Folge echter Sim-Daten, headless, die Sim rechnet auf der CPU:
`RS_SEED=1337 RS_STEP=20000 AMPLIFY_DUMP=/abs/ordner AMPLIFY_TICKS=12 AMPLIFY_TICK_YEARS=15 godot --headless --path game --script res://tools/amplify_dump.gd`.
Je Takt `t`: `heights_<t>.f32` (n², Float32, Sim-Höhe 0…1), `filled_<t>.f32` (Seespiegel), `protect_<t>.u8` (Schutzmaske), `flow_<t>.u8`, `surface_<t>.rgba`, `cover_<t>.rgba`, `water_<t>.rgba`, dazu einmal `meta.json` (n, Weltgröße, Überhöhung, Meeresspiegel, Tümpeltiefe und Codes aus dem Kalibrier-Register). Takt 0 ist der eingeschwungene Stand (`FRAME_SETTLED`), danach Zeitraffer-Takte wie in `Main._process`. Die Overlay-Drossel (0,30 s) läuft über die Uhr des Aufrufers; das Werkzeug rückt die Uhr je Takt um eine Sekunde vor, damit jeder Frame alle Overlays mitbringt.

`tools/amplify_run.gd` fährt den Verfeinerer über einen Dump und braucht ein RenderingDevice, also ein Fenster (nicht `--headless`):
`AMPLIFY_DUMP=/abs/dump AMPLIFY_OUT=/abs/aus godot --path game --script res://tools/amplify_run.gd`.
`AMPLIFY_PARAMS` (JSON) überschreibt Werte aus `TerrainAmplifier.params`, `AMPLIFY_TICKS` begrenzt die Takte, `AMPLIFY_WRITE` wählt die Felder (Standard `offset,maps`). Je Takt `offset_<t>.rg16f` (fein: r Abweichung in Welteinheiten, g Maske), `maps_<t>.rgba`, dazu `run.json` mit den Zeiten; die Zeit bis zum Rücklesen ist die Auftragskosten, weil der Rückweg auf die GPU wartet.

`tools/timelapse_capture.gd` nimmt den Zeitraffer in Echtzeit Bild für Bild aus dem Fenster auf (Flimmer-Nachweis):
`RS_SEED=1337 RS_STEP=20000 RS_RATE=60 CAPTURE_OUT=/abs/ordner CAPTURE_SECONDS=12 godot --path game --resolution 1728x1052 --script res://tools/timelapse_capture.gd`.
Godots Movie-Modus (`--write-movie`) taugt dafür nicht: er rechnet die Bilder in fester Bildzeit, die Sim tickt und die Überblenden laufen aber auf der echten Uhr (`Main._now`), im Film springt der Stand deshalb, statt zu gleiten. Ausgabe `<nr>.jpg` und `stamps.txt` (Sekunden je Bild); `scripts/look/zeitraffer-video.sh` baut daraus das Video.

Betrifft: `game/tools/amplify_dump.gd`, `game/tools/amplify_run.gd`, `game/tools/timelapse_capture.gd`, `TerrainAmplifier.params`

# Zeitraffer-Frame-Zeiten als interleaved A/B ohne start.sh

`scripts/timelapse-timing.sh` misst Frame-Zeiten im Zeitraffer (Messprotokoll `docs/perf-measurements.md` §L). Mit mehreren Spielordnern läuft je Runde jeder einmal, die Reihenfolge wechselt von Runde zu Runde (A B, B A, …), damit eine Lastspitze anderer Prozesse beide Stände gleich trifft. Ein Vergleichsstand ist eine Kopie von `game/` samt `bin/` und importiertem `.godot/`.

Gemessen wird mit der Flusstal-Bühne im Betrieb `simulation` (60 J./Sek. ab Sekunde 2, Frame-Abstände über 10 s), maximiert, wie AGENTS.md für Bildraten verlangt. Bewusst ohne `scripts/start.sh`: dessen Build-Stempel-Prüfung lehnt jeden Vergleichsstand ab, dessen Quellen nicht die des Arbeitsverzeichnisses sind.

Zwei Godots teilen sich die GPU; solche Läufe sind keine saubere Messung. `RS_TIMING_EXCLUSIVE=1` wartet vor jedem Lauf, bis kein fremdes Godot läuft (höchstens `RS_TIMING_EXCLUSIVE_MAX`, Standard 600 s); ohne den Schalter steht die Zahl fremder Godot-Prozesse als `foreign_godot` in jeder Ergebniszeile, dazu das Lastmittel: auf einem belasteten Rechner gehören beide zum Ergebnis. Mit externem Monitor startet Godot dort; `RS_TIMING_SCREEN` wählt den Bildschirm (eingebauter Bildschirm des Referenz-Macs z. B. Index 1, maximiert 3456×2104), die Viewport-Größe steht in jeder Zeile. Weitere Schalter (Runden, Seed, Jahr, Kamera, Qualität, Ausgabe) im Skript.

Betrifft: `scripts/timelapse-timing.sh` (`wait_exclusive`, `foreign_godot`)

# Logbuch des visuellen Hill-Climbers

Ablauf und Regeln: `docs/look-hillclimb.md`. Ausgangsstand: Commit 705db55
(Aufnahmen und `game/`-Kopie lokal unter `.tools/look/base/`, gitignoriert).
Urteile stehen als `A x B y GLEICH z` (A = Vergleichsstand, B = neuer Stand),
Bewerter DeepSeek V4.1 Flash, wo nicht anders angegeben.

Befund am Ausgangsstand (Orchestrator, von Auge gegen d/e/f):

- Wasser: einheitlich blaue, flache Bänder mit breitem hellem Milchrand,
  ohne Bett, Böschung und Tiefenverlauf.
- Wald: wenige Noppen-Flecken in `nah`, in `tal` ein gleichförmiger
  Noppenteppich ohne Lichtungen und Farbvariation.
- Fels und Hänge: glatte, weichgezeichnete Flächen; Schnee als
  geschlossene weiße Kappe.
- Küste: breite, unscharfe Sandkleckse, kein Brandungssaum.
- Licht: flaches, kühles Mittagslicht, kein Dunst.

## Problem 1: Wasser liegt im Gelände

| Nr. | Hypothese | Urteil | Ergebnis | Kernsatz |
| --- | --- | --- | --- | --- |
| 1 | Flussbett im Render eingeschnitten: Relief-Bake hebt das Land außerhalb des Wasser-Kerns um `bankLift` 0,6 (Böschung, echte Geometrie), Schutzmaske zweistufig, Tiefenverlauf quer zum Band | A 1 B 3 GLEICH 5 (Implementer), Gegenprobe Orchestrator 5 Läufe: A 4 B 4 GLEICH 7 | verworfen | In `nah` gewinnt der Einschnitt 4/5 („sichtbar eingetieft, beschattete Böschung“). In `diorama` und `tal` ist er nicht zu sehen; die A-Stimmen dort begründen mit Wald und Schnee, die sich gar nicht geändert haben (Rauschen), eine nennt zu Recht den hellen Saum, den die angestrahlte Böschung samt beigem Bankmaterial um die Flüsse legt. Schranken waren grün (660 Tests, Hash `95cf93ca1b40985c` unverändert, 19,2 → 18,9 ms). Patch als Grundlage für Nr. 2 aufgehoben (`.tools/look/it01/patch.diff`). |
| 2 | Auf Nr. 1 aufbauend: heller Saum weg (Bank nur knapp über dem Wasserspiegel, `barLift` 0,42, Schutzmaske dreistufig; dunkle Böschung; schmalere Sandbänke mit Kante; dunkler Raster-Ufersaum), Binnenwasser spiegelt schwächer, Stromschnellen-Schaum aus dem Gefälle | Implementer (nicht blind, s. u.): A 9 B 2 GLEICH 4, A 5 B 3 GLEICH 7, A 4 B 1 GLEICH 10. Orchestrator mit blindem Bewerter, 5 Läufe: A 1 B 3 GLEICH 11 | verworfen | `nah` 3× B („Tiefenwirkung: dunkleres Zentrum, hellere Flachwassersäume“), `diorama` und `tal` 9× GLEICH von 10: bei 8 px Flussbreite trägt der Einschnitt nicht. Dunkleres Wasser las ein Lauf als „flauer“, breite helle Bänke las er als „Ufer“. Schranken grün (660 Tests, Hash unverändert); Bildraten-A/B unbrauchbar, weil der Bildschirm schlief. |

Befund zum Werkzeug (2026-11-19): Der Bewerter war bis hierher nicht
zuverlässig blind, er hat als Agent die echten Pfade gelesen. `judge.sh`
ist korrigiert und nachgeeicht (`docs/look-hillclimb.md` § Eichung,
Nachtrag); die Urteile zu Nr. 1 und 2 oben sind mit dem korrigierten
Bewerter bestätigt (Nr. 2) bzw. in der Richtung gleich (Nr. 1).

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
| 3 | Auf Nr. 1+2 aufbauend: scharfe Uferlinie für alles Binnenwasser (Band und Raster), nasser Streifen, Kiesstreifen innen, Strömungsstreifen, Schaum, gesättigter Türkis-zu-Tiefblau-Verlauf, dunkle Fassung in der Übersicht | Implementer: A 3 B 8 GLEICH 4, A 1 B 9 GLEICH 5, A 5 B 8 GLEICH 2. Orchestrator, 5 Läufe: A 4 B 9 GLEICH 2 | verworfen | Erstmals wirkt die Änderung in allen drei Aufnahmen (`diorama` 3 B, `tal` 3 B, `nah` 3 B), aber 4 A-Stimmen: „helltürkise, uniforme Bänder mit scharf abgesetztem hellem Sandrand, die flach aufliegen“. Der gemalte Saum liest sich als Band, nicht als Tiefe. Schranken grün (660 Tests, Hash unverändert, 19,2 gegen 19,2 ms). |

Drei Verwerfungen am selben Problem → strukturelle Eskalation (Regel 6).
Lehre aus Nr. 1 bis 3: Echte Geometrie (Böschung) wirkt in `nah`, trägt aber
nicht in die Ferne; gemalte Säume (Türkis, Kies, Schaum) tragen in die Ferne,
lesen sich aber wieder als aufgelegtes Band. Stand Nr. 3 liegt als Patch
unter `.tools/look/it03/patch.diff`.

## Problem 1, strukturelle Eskalation

| Nr. | Hypothese | Urteil | Ergebnis | Kernsatz |
| --- | --- | --- | --- | --- |
| 4 | Tiefe ist echt statt gemalt: Relief-Bake senkt das Bett unter den Bändern ab (U-Profil, `ReliefRender.bedDepth` 0,9, tiefer je breiter der Lauf), Terrain malt dort Kies; das Band rechnet je Pixel die Wassersäule (Bandfläche minus gerendertes Gelände) und daraus Deckkraft (Beer–Lambert, `WaterRender.ribbonAbsorption` 1,6), Farbe und Uferlinie. Alle gemalten Säume aus Nr. 1–3 und dem #174-Querprofil (Wasserlinie, nasses Ufer, Kies-/Türkis-Streifen, Schaum, Strömungsstreifen, Bogen-Tiefe) entfernt; Land-Anhebung 0,6 → 0,45 | Implementer, 3 Läufe: A 3 B 7 GLEICH 5, A 3 B 4 GLEICH 8, Endstand A 3 B 6 GLEICH 6 | verworfen (Regel) | `nah` 4 B von 5 („helle Flachwasser-/Uferzone, Verlauf von tief zu flach, lesen sich als eingebettete Gewässer mit Bett“); `diorama` 2 B, 3 GLEICH; `tal` 2 A („breitere, flachere Wasserbänder“, „milchiger“). Schranken grün (660 Tests, Hash unverändert, Bildrate 19,5/21,0 → 19,5/21,3 ms Mittel/p95). Die Säule aus dem Tiefenpuffer kostete gemessen 1,2 ms je Bild und ist durch die Höhe aus der Backtextur ersetzt. |


Zweitbewerter nach Nr. 4 (Gemini 4 Hydrogen, blind, derselbe Prompt, je ein
Urteil pro Aufnahme gegen den Ausgangsstand): Stand Nr. 3 gewinnt 3/3
(„tiefes Blaugrün in der Mitte, hellere Flachwasser-Ränder, klar definierte
Sandbänke“), Stand Nr. 4 gewinnt 2/3 und verliert `tal` („blasser, flacher,
graublaue Bänder“). Gemini widerspricht DeepSeek damit bei Nr. 3 deutlich,
nennt aber dieselbe Schwäche wie dessen A-Stimmen: „zu grelle helle
Flusslinien“. Folge: Nr. 4 (echte Tiefe) bleibt verworfen, der Arbeitsbaum
steht wieder auf Nr. 3, und Nr. 5 nimmt genau diese Schwäche weg.

| Nr. | Hypothese | Urteil | Ergebnis | Kernsatz |
| --- | --- | --- | --- | --- |
| 5 | Stand Nr. 3 entschärft: kein Cyan (olivgrüner Flachwasserton), Kies nur am Gleithang und unterbrochen, matter Schaum nur an Gefällestufen, kein weißer Seerand, dunkles Ufer | Implementer, 3 Läufe: A 3 B 7 GLEICH 5, A 2 B 7 GLEICH 6, A 2 B 6 GLEICH 7 | verworfen | `nah` durchgehend 4 B von 5; `diorama` und `tal` überwiegend GLEICH, dort bleibt „flache blaue Bänder mit hellen Sandrändern“. Schranken grün bis auf p95: 20,6 → 21,1 ms (kommt aus Nr. 3, Mittel unverändert 19,3 → 19,2 ms). Patch: `.tools/look/it05/patch.diff`. |

### Befund zu Problem 1 nach fünf Versuchen (davon einer strukturell)

Mit Einzelschritten am Wasser ist `B_BEHALTEN` nicht erreichbar. Begründung:

- Die Richtung stimmt in jedem Versuch ab Nr. 3 (B 6 bis 9 von 15, `nah`
  stets 4 von 5, Gemini 3/3 für Nr. 3). Es scheitert an den A-Stimmen: Sobald
  sich zwei Stände sichtbar, aber mäßig unterscheiden, vergibt DeepSeek 2 bis
  4 A-Stimmen von 15, teils mit Gründen, die sich gar nicht geändert haben
  (Wald, Schnee). Erlaubt ist 1. Dieselbe Streuung zeigt die Eichzeile
  `performance` gegen `balanced` (4/6/5).
- In `diorama` und `tal` ist ein Fluss 8 bis 10 px breit. Solange Wald, Fels
  und Licht dort „weit hinter der Referenz“ liegen, urteilt der Bewerter
  GLEICH, egal wie das Wasser aussieht.
- Echte Tiefe (Nr. 4) ist ehrlicher, trägt bei flachem Blick aber schlechter
  als gemalte: schmale Läufe werden milchig. Der Depth-Buffer-Weg kostete
  gemessen 1,2 ms je Frame.

Entscheidung: Der Wasser-Stand Nr. 5 wird NICHT committet, sondern als Patch
aufgehoben. Der Arbeitsbaum geht zurück auf den Ausgangsstand. Wenn die
flächigen Probleme (Wald, Fels, Licht) behalten sind, wird der Patch als
eigene Iteration gegen den dann besseren Stand erneut geprüft.

Nachtrag 2026-11-19: Der Wasser-Stand Nr. 5 liegt auf Wunsch des Eigners als
eigener Draft-PR #230 (Branch `look-water`, Vorher-Nachher-Bilder unter
`docs/look-water/`); dort entscheidet das Auge, nicht der Bewerter.

## Problem 2: Wald als Flächen mit Lichtungen

| Nr. | Hypothese | Urteil | Ergebnis | Kernsatz |
| --- | --- | --- | --- | --- |
| 6 | Wald trägt als Fläche: mehr Deckung, dunkles Tannengrün gegen die Wiese, Variation in zwei Skalen (Bestände, Kronen), unregelmäßige Ränder und Lichtungen. Dach hebt nach einer über 4×4 Zellen geglätteten Maske an, Nadelkronen als flache Kuppeln, Kronen stehen nach dem Bestandsrauschen in Gruppen; nur Render (`CanopyRender`, `ForestCanopyMask`, `terrain.gdshader`) | Orchestrator, 5 Läufe: A 0 B 10 GLEICH 5. Implementer am Endstand mit Perf-Umbau: A 2 B 10 GLEICH 3 und A 1 B 11 GLEICH 3; Stand vor gegen nach Perf-Umbau: A 0 B 0 GLEICH 9 | **behalten** | `nah` 5 B von 5 („dichtere, gruppierte Waldflächen“), `diorama` 3 B, `tal` 2 B und 3 GLEICH. A-Stimmen des Implementers kommen aus `tal` („dunkle Kronenschatten und Binnenkontrast“ im alten Stand). Schranken: 661 Tests, Hash `95cf93ca1b40985c` unverändert, Vertragstests grün; `pickaxe_repro` ist rot (`FAIL_INFILL 0.0069 → 0.0067`), am Ausgangsstand mit denselben Zahlen, also nicht von hier. Bildrate zuerst rot (19,2 → 19,6 ms Mittel, mehr Waldfläche), nach Umbau grün: 19,2/20,5 → 18,9/19,7 ms Mittel/p95, weil unter vollem Kronendach das Bodenmaterial und das Erosionsdetail nicht mehr gerechnet werden (Letzteres nicht bit-genau, von Auge gleich). Der Eigner hatte vorab entschieden, den Wald auch mit Einbuße zu behalten. |

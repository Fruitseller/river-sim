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

## Problem 3: Fels, Hänge und Schnee mit Struktur

Vergleichsstand ab hier: Stand nach Nr. 6 (`.tools/look/keep1/`).

| Nr. | Hypothese | Urteil | Ergebnis | Kernsatz |
| --- | --- | --- | --- | --- |
| 7 | Gestein statt Knete: im Relief-Bake eine zweite, feinere Rinnenschar (Felsrippen, ~120 m, voll auf Steilflanken, halb auf Grashängen) und grobe Felsbänke (Schichtstufen im 80-m-Abstand); im Terrain-Shader folgt der Schnee der Form (Rinnen und Schultern, Rippen und Wände aper, ausgefranste Schneegrenze), die Grenze Fels ↔ Wiese franst aus, Grashänge tragen Felsköpfe und Schuttstreifen. Ausgleich der Kosten: Pixel-Rinnendetail 2 statt 3 Oktaven | Orchestrator, 5 Läufe gegen Nr. 6: A 0 B 14 GLEICH 1. Implementer am Endstand: A 1 B 11 GLEICH 3 | **behalten** | `diorama` 5 B, `tal` 5 B, `nah` 4 B: „Felsgrate und Hänge haben sichtbare Struktur und Schatten, die Schneefelder wirken gebrochener statt wie gleichmäßiger Zuckerguss“. Schranken: 661 Tests (Orchestrator nachgefahren), Hash `95cf93ca1b40985c` unverändert, Vertragstests grün (`pickaxe_repro` rot wie am Ausgangsstand), Bildrate 18,8/19,7 → 18,0/19,1 ms Mittel/p95. Lehre: Zeilen im Terrain-Fragmentshader kosten Bildzeit auch unausgeführt (bis +1,4 ms); Struktur gehört in den Bake. |

## Problem 4: Küste, Strand und Flachwasser

Vergleichsstand: Stand nach Nr. 7 (`.tools/look/keep2/`).

| Nr. | Hypothese | Urteil | Ergebnis | Kernsatz |
| --- | --- | --- | --- | --- |
| 8 | Küste liest sich als Küste: Brandung als weißer, unterbrochener Strich an der scharfen Wasserlinie (fällt vor Mündungen über die Sedimentfahne weg), kräftiger Türkis-Verlauf nach Wassertiefe mit früherem Knick, sattes dunkles Tiefblau; Strand schmaler (`beachMaxWidthCells` 5 → 4) mit nassem dunklem Sand am Wasser, hellem trockenem dahinter und scharfer Rückkante | Orchestrator, 5 Läufe gegen Nr. 7: A 1 B 10 GLEICH 3 (ein Lauf ohne Urteil). Implementer am Endstand: A 1 B 12 GLEICH 2 | **behalten** | `diorama` 4 B, `tal` 4 B und 1 A, `nah` 2 B und 2 GLEICH: „kräftigeres, tief abgestuftes Wasser mit türkisfarbenem Flachwasser und dunklem Tiefwasser, klarere Uferkanten“. Die A-Stimme begründet mit den Flüssen in den Tälern, die sich nicht geändert haben. Schranken: 661 Tests, Hash `95cf93ca1b40985c` unverändert, Vertragstests grün (`pickaxe_repro` wie gehabt), Bildrate 18,0/19,1 → 18,0/19,1 ms. Rest: einzelne trockene Sandflächen auf Terrassen hinter dem Strand; an tiefen Mündungsrinnen stößt dunkles Meer ohne Türkis an den Sand. |

## Problem 5: Licht und Atmosphäre

Vergleichsstand: Stand nach Nr. 8 (`.tools/look/keep3/`).

| Nr. | Hypothese | Urteil | Ergebnis | Kernsatz |
| --- | --- | --- | --- | --- |
| 9 | Tiefere, wärmere Sonne (38° → 30°, Energie 2,4), kühleres Umgebungslicht, AgX-Kontrast 1,38, Sättigung 1,12, weniger Nebel, blauerer Himmel; nur `Lighting.gd` | Implementer: A 0 B 10 GLEICH 5. Orchestrator, 5 Läufe: A 2 B 8 GLEICH 5 | verworfen | Zusammen A 2 B 18 GLEICH 10: es fehlt an B. `diorama` und `tal` je zur Hälfte GLEICH, Licht und Dunst kommen in der Totalen kaum an; in `nah` decken fast schwarze Schlagschatten ganze Hänge zu, Wiesen gelboliv. Schranken grün (661 Tests, Hash unverändert, Bildrate 18,0/19,1 gegen 18,0/19,1 ms). Zweitbewerter Gemini nicht verfügbar (Antigravity 1.4.5 läuft nicht mit dieser T3-Version). |
| 10 | Wie Nr. 9 (Sonne 30°, warm, Energie 2,4), dazu: Schatten über kühleres Himmelslicht geöffnet (Umgebungslicht 0,48, Himmelsanteil 0,80), AgX-Kontrast 1,45, Sättigung 1,15, Himmel oben tiefer blau mit hellerem Horizont, satteres Grün für Wiese, Talboden, Bewuchs und Trockenrasen (Literale in `terrain.gdshader`) | Orchestrator, 5 Läufe gegen Nr. 8: A 0 B 13 GLEICH 2. Implementer, zwei Läufe: A 1 B 11 GLEICH 3 und A 1 B 10 GLEICH 4 | **behalten** | `tal` 5 B, `diorama` 4 B, `nah` 4 B: „durch die kräftigere, gerichtete Beleuchtung und die tieferen Schatten deutlich plastischer“. Verworfener Zwischenstand: offene Schatten plus dichter Dunst las der Bewerter als „flauer und milchiger“ (A 4 B 5 GLEICH 6), er belohnt Kontrast. Schranken: 661 Tests und Hash vom Orchestrator nachgefahren, Vertragstests grün (`pickaxe_repro` wie gehabt), Bildrate 18,0/19,1 gegen 18,0/19,1 ms. Offen: Dunst trägt weiter kaum zur Tiefenstaffelung bei. |

## Problem 1, Wiederprüfung auf dem neuen Stand

Vergleichsstand: Stand nach Nr. 10 (`.tools/look/keep4/`).

| Nr. | Hypothese | Urteil | Ergebnis | Kernsatz |
| --- | --- | --- | --- | --- |
| 11 | Wasser-Stand Nr. 5 (PR #230) von Hand auf den Stand mit Wald, Fels, Küste und Licht portiert und nachgezogen: Böschung im Bake neben Rippen und Bänken, scharfe Uferlinie, Tiefenverlauf, Kies am Gleithang; Böschung hebt im Wasser-Kern nie an, Bake mit 60 statt 180 Abgriffen je Pixel | Implementer, Endstand, zwei Läufe: A 2 B 5 GLEICH 8 und A 3 B 8 GLEICH 4, zusammen A 5 B 13 GLEICH 12. Zwischenstände A 4 B 4 GLEICH 7, A 11 B 3 GLEICH 1, A 7 B 3 GLEICH 4, A 3 B 6 GLEICH 6 | verworfen | `nah` 9 B von 10, `diorama` und `tal` überwiegend GLEICH oder A: „blassgraue, trocken wirkende Rinnen“ gegen „breiter, blauer und als Wasser im Bett lesbar“. Das ist ein echter Fehler: Mit der Böschung verschwinden in der Totalen schmale Läufe und ein Hochtalsee oder werden von Landstreifen überdeckt (mit `bankLift` 0 sind sie wieder da); Ursache nicht gefunden. Schmalere Sandbänke las der Bewerter als „Bänder ohne Ufersaum“. Schranken grün (661 Tests, Hash unverändert, Bildrate 18,0/19,1 → 18,0/19,3 ms). Patch: `.tools/look/it11/patch.diff`. |

### Befund zu Problem 1 nach sechs Versuchen

Problem 1 gilt für diesen Kletterer als **nicht erreichbar**. Begründung:

- Sechs Versuche, davon einer strukturell (Nr. 4, echte Tiefe) und einer auf
  dem verbesserten Stand (Nr. 11); Zweitmeinungen von zwei Herstellern liegen
  vor (GLM, DeepSeek). Die Nahsicht gewinnt jedes Mal (4 bis 5 von 5), die
  Totalen nie.
- Der Grund ist nicht mehr nur Bewerter-Rauschen: Die Böschung im Relief-Bake
  setzt an der Schutzmaske an, und bei Läufen von ein bis zwei Zellen Breite
  deckt das angehobene Land das Wasser zu. Was in `nah` als Bett liest,
  löscht in `diorama` und `tal` schmale Läufe.
- Ein Ansatz, der trägt, braucht eine Böschung aus der Band-Geometrie selbst
  (Querschnitt je Lauf mit bekannter Breite) statt aus der Zellmaske, und
  wahrscheinlich breitere sichtbare Läufe in der Totalen. Das berührt die
  Band-Geometrie und die Übergabe Band ↔ Raster und ist ein eigenes Vorhaben.

PR #230 trägt denselben Fehler in der Totalen und bleibt als Anschauung für
die Nahsicht offen.

## Problem 1, zweiter Anlauf (2026-11-20, auf Wunsch des Eigners)

Der Befund „nicht erreichbar“ oben ist damit überholt. Vergleichsstand:
Stand nach Nr. 10 (`.tools/look/keep4/`). Ab Nr. 14 gilt die gelockerte
Regel (`docs/look-hillclimb.md` § Regel: über 30 Urteile B − A ≥ 10, A ≤ 6,
in keiner Aufnahme mehr A als B; Bildrate bis 4 % schlechter erlaubt).
Implementer ab Nr. 14 mit Effort high.

| Nr. | Hypothese | Urteil | Ergebnis | Kernsatz |
| --- | --- | --- | --- | --- |
| 12 | Der Fluss wird durch Bewuchs eingebettet statt durch Geländeform: Galeriewald bis ans Ufer (5–14 Zellen), schmalerer kahler Korridor, keine dunkle Konturlinie | Implementer, deckender Saum: A 5 B 10 GLEICH 0 und A 5 B 7 GLEICH 3; mit durchsichtigem Saum (nicht abgegeben) A 1 B 13 GLEICH 1 | verworfen | Der dunkle Ufersaum der Bänder IST die Konturlinie, und er verdeckt nur, dass die Bänder über dem Gelände schweben (Issue #233). Ohne Saum gewinnt der Stand, zeigt aber das Schweben. Das breite Gehölzband fraß die Lichtungen aus Nr. 6 („Baumkugeln gleichmäßig über nahezu alle Hänge“). Bildrate 18,1/19,1 → 16,8/17,9 ms. |
| 13 | Das Band schwebt an der Wurzel nicht mehr, damit kann die Kontur weg: Bandkanten folgen dem Gelände nach unten statt Gelände plus `riverLift`; neuer Wächter `RibbonFloatTests`; Saum 0,6 → 0,12; Gehölzband 3–7 Zellen | Implementer: A 1 B 9 GLEICH 5 und A 2 B 7 GLEICH 6. Orchestrator, 10 Läufe: A 5 B 12 GLEICH 13 (`tal` 3/3) | verworfen, auch nach neuer Regel | Schwebende Messpunkte auf der Produktionswelt 98,3 % → 0,1 %. Der Bewerter sieht das Ende des Schwebens nicht als Gewinn: „Wasser als flaches, hellblau-graues Band statt als eingesenkter Wasserkörper“. In `tal` wuchs die Talmitte zu. Stand bleibt als Grundlage für Nr. 14 im Arbeitsbaum. |
| 14 | Das Wasser selbst lebt (auf Nr. 12+13): Lauf-Größen je Band-Vertex (Kolk ↔ Riffel aus Bogenstärke und Gefälle, Weißwasser an Stufen, Engstellen, Zusammenflüssen); Petrol im Kolk, heller Riffel, Strömungsstriche und fleckiger Schaum, Flüsse spiegeln weniger Himmel, Seen zur Mitte tiefblau; Raster-Wasser zieht mit; Galeriewald nur an Bändern und Seen (2,5–5 Zellen), Grundwald wieder mit voller Sperre | Implementer, 10 Läufe: A 3 B 18 GLEICH 9. Orchestrator, 10 Läufe: A 4 B 21 GLEICH 4 (`diorama` 1/5, `tal` 2/7, `nah` 1/9) | **behalten** (Nr. 12–14 als ein Commit) | „Bei X liest sich der Fluss als Körper im Gelände — Kiesbänke, helle Flachwasserzonen, weiße Stromschnellen und sichtbares Bett —, während Y ihn als gleichmäßig flaches, deckend blaues Band über die Talsohle legt.“ A-Stimmen: „breite helle Sand-/Sedimentschleier“, „teils grelle Glanzspur“. Ein blauerer Ton verlor `diorama` 0/3 gegen Petrol 3/3. Schranken grün (667 Tests, Hash unverändert, Bildrate 18,2/19,3 → 18,0/19,1 ms). |

Lehren: Sechs Versuche scheiterten, weil sie das Bett formen oder bemalen
wollten, während das Band tatsächlich über dem Gelände lag und eine dunkle
Kontur das verdeckte. Erst Ursache (Geometrie), dann Fassung (Bewuchs), dann
Oberfläche (Wechsel entlang des Laufs) trug. Der Bewerter belohnt den
Geometrie-Fix allein nicht; behalten wurde das Paket.

Rest-Schwächen am Wasser: Weißwasser spärlicher und weicher als in
Referenz f; manche Schaumstriche an Gefällestufen zu lang und gleichmäßig;
grauer Ring um Raster-Seen (schon vorher); Wolkenspiegelung auf Seen kaum
sichtbar; `diorama` bleibt meist GLEICH (Läufe 8–10 px breit); der Messlauf
`RiverUphill` rechnet noch mit Bandhöhe minus `riverLift`.

Vorher-Nachher: `docs/look-hillclimb/wasser-{diorama,tal,nah}-vorher-nachher.jpg`.

## Rest-Schwächen nach Nr. 14 (ab 2026-11-20, Implementer GPT-6.2 Sol, Effort high)

Vergleichsstand: Stand nach Nr. 14 (`.tools/look/keep5/`).

| Nr. | Hypothese | Urteil | Ergebnis | Kernsatz |
| --- | --- | --- | --- | --- |
| 15 | Wasser-Reste: gruppierte, kürzere Schaumfahnen; feuchter Boden und fleckiger Kies statt grauem Ring um Raster-Seen; ruhiger Himmelsverlauf auf Seen; stärkerer Himmelsreflex in der Totalen (verworfen, bevor abgegeben) | Implementer, 10 Läufe: A 4 B 3 GLEICH 23 (`diorama` 0/0, `tal` 1/0, `nah` 3/3) | verworfen | Der Bewerter sieht den Unterschied nicht (23 GLEICH). In `nah` hebt sich beides auf: „klar abgesetzte Gischtflecken“ gegen „harte, zackige Weißsplitter“ und eine Wasserfläche, die „stärker mit der Wiese verschwimmt“ (weiches See-Ufer). Schranken grün (667 Tests, Hash unverändert, 17,83 → 17,86 ms). Patch: `.tools/look/it15/patch.diff`. |

## Abschluss (2026-11-20)

Behalten: Nr. 6 (Wald), Nr. 7 (Fels, Hänge, Schnee), Nr. 8 (Küste), Nr. 10
(Licht), Nr. 14 (Wasser, mit Nr. 12 und 13). Verworfen: Nr. 1 bis 5 und 11
(Wasser), Nr. 9 (Licht, erster Anlauf). Die Tabelle darunter ist der Stand
vor Nr. 14; die Zahlen am Endstand mit Wasser stehen bei Nr. 14.

| Prüfung | Ergebnis |
| --- | --- |
| Endstand gegen Ausgangsstand 705db55, `judge.sh`, 5 Läufe | A 0 B 15 GLEICH 0, `B_BEHALTEN` |
| Zweitbewerter Gemini 4 Neon (blind, ein Urteil je Aufnahme, Endstand mit Wasser) | gegen Ausgangsstand 705db55: Endstand 3/3 („Wasser liegt … glaubwürdig im Talbett“ gegen „flaches, gleichförmig dunkelblaues Band“). Gegen den Stand vor Nr. 14: `nah` Endstand, `diorama` und `tal` GLEICH |
| Endstand mit Wasser (Nr. 14), vom Orchestrator gefahren | 667 Tests, 81 übersprungen, 0 Fehler; Hash `95cf93ca1b40985c`; smoke, water_geometry, river_ribbons, water_uniforms, lighting, relief, canopy, ui_layout, graphics_study grün |
| SimCore-Pflichtsuite | 661 Tests, 79 übersprungen, 0 Fehler |
| Godot-Vertragstests | smoke, river_ribbons, water_geometry, water_uniforms, lighting, relief, canopy, ui_layout, water_gpu_tail grün; `pickaxe_repro` rot (`FAIL_INFILL 0.0069 → 0.0067`), am Ausgangsstand ebenso |
| `simperf --hash` | `95cf93ca1b40985c`, unverändert |
| Bildrate (Zeitraffer-A/B, 3456×2104, je Iteration gegen den Stand davor) | 19,2/20,5 → 18,0/19,1 ms Mittel/p95 über alle vier Iterationen |

Kontaktbögen (Ausgangsstand, Endstand, Referenz): `docs/look-hillclimb/kontaktbogen-{diorama,tal,nah}.jpg`.

Offen:

- Wasser im Gelände: mit Nr. 14 behalten; Rest-Schwächen s. zweiter Anlauf.
- `pickaxe_repro` ist auf main rot und gehört in ein eigenes Issue.
- Küste: trockene Sandflächen auf Terrassen hinter dem Strand; dunkles Meer
  ohne Türkis an tiefen Mündungsrinnen.
- Licht: Dunst trägt kaum zur Tiefenstaffelung; `diorama` gewinnt am wenigsten.
- Wald: Kronen in der Nahsicht weiter als runde Noppen lesbar („Ballon-Bäume“).
- Der Prüfpunkt nach fünf behaltenen Iterationen (Zweitmeinung zum Diff) ist
  mit Nr. 14 erreicht (fünf); die Zweitmeinung zum Diff steht aus.

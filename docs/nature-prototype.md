# Mutter-Natur-Prototyp (Issue #223)

Gameplay-Experiment auf der bestehenden Flusssimulation: Der Spieler ist Mutter
Natur und will eine Siedlung zum Aufgeben bringen, ohne Häuser oder Felder
direkt anzufassen. Er verändert mit wenigen, begrenzten Geländeeingriffen den
Fluss; Wassermangel oder Aufstau bringen die Siedlung über Jahre an ihr Ende.

Der Prototyp ist vom Sandkasten getrennt. Ohne Schalter startet das Spiel wie
bisher.

**Stand:** technisch umgesetzt und headless geprüft. Den echten Spieltest mit
Maus und Bildschirm hat noch niemand gemacht (s. „Spieltest — ausstehend").
Die Frage, ob der Loop Spaß macht, ist damit noch offen.

## Starten

```sh
"$(git rev-parse --show-toplevel)"/scripts/build.sh release   # Extension bauen (wie immer)
RS_NATURE=1 ./scripts/start.sh --maximized
# gleichwertig: ./scripts/start.sh --maximized -- --nature
```

Ohne `RS_NATURE=1` bzw. `-- --nature` startet der Sandkasten unverändert.

## Spielanleitung

- **Ziel:** Talheim (das mittlere Dorf am Hauptfluss) gibt auf. Hält Talheim
  300 Spieljahre, ist der Versuch verloren.
- **Start:** pausiert. Leertaste oder ▶ spielt mit **5 J./Sek.**, unten links
  lässt sich auf 1 J./Sek. umschalten.
- **Werkzeuge:** nur Spitzhacke (Taste 6, Durchstiche), Absenken (2) und
  Anheben (1, Dämme). Die übrigen sind ausgeblendet und gesperrt.
  Pinselradius höchstens 3 Zellen.
- **Budget:** jede Erdbewegung (Σ |Δh| eines Strichs) geht vom
  Eingriffsbudget ab (Balken unten links). Leer heißt: keine Eingriffe mehr.
- **Tabu:** Striche direkt an Häusern oder Feldern werden abgelehnt (Meldung im
  Panel). Wer gewinnen will, muss über den Fluss gehen.
- **Anzeige:**
  - Häuser sind Klötzchen in der Zustandsfarbe (hell = stabil, gelb =
    unterversorgt, orange = Abwanderung, grau = verlassen; dunkler = die Leute
    sind beim Ausbessern).
  - Felder sind flache Platten: grün = bewässert, braun = trocken, blau =
    überflutet.
  - Eigene Eingriffe sind violette Würfel, gerade ausgebesserte weiß.
  - Das Panel zeigt je Siedlung Zustand und Grund (Wassermangel/Überflutung),
    Wasser %, Vorrat in Jahresrationen, Bevölkerung %, schlechte Jahre in
    Folge und die Ernten der letzten 12 Jahre (in % vom Bedarf).
- **Ende:** Banner im Panel, das Spiel pausiert. „Neustart" stellt denselben
  Startzustand bit-gleich wieder her, mit frischem Budget.

## Die Karte

`SimGame.NatureScenario`: ein entworfenes Tal, kein gesuchter Seed. Das Raster
hat 128 × 128 Zellen bei der Produktions-Zellgröße (`world` wächst mit `n`).
Die Physik ist `SimConfig.production`, mit 200 Jahren Einlauf und ohne
Tektonik. Sie hat eine eigene Generierung mit vorgegebenem Relief
(`Terrain.generate(seed:relief:)`).

- Im Norden liegt ein Bergkessel, er entwässert ins **Haupttal**.
- Westlich daneben, durch einen schmalen Rücken getrennt, liegt ein **0,025
  tieferes Nebental**. Der Rücken hat zwei Sättel:
  - den **niedrigen** bei Zeile 52 (Kamm +0,012 über der Talsohle) und
  - den **hohen** bei Zeile 40 (+0,030).
- Unterhalb der Sättel ist das Haupttal schmal. Was östlich davon fällt,
  entwässert über den Kartenrand. Talheim lebt deshalb fast nur vom Wasser,
  das über die Sättel hinweg kommt.
- **Oberau** liegt oberhalb beider Sättel und bleibt versorgt. **Talheim**
  (Ziel) liegt unterhalb am Hauptfluss. **Westfurt** im Nebental hat seinen
  eigenen Bach und bekommt bei einer Umleitung mehr Wasser.

## Regeln und Näherungen

Alle Zahlen sind ein erster Versuch und keine validierte Balance. Sie stehen
kommentiert in `SimCore/Sources/SimGame/` (`SettlementRules`, `NatureGame`).

| Regel | Wert | Näherung |
| --- | --- | --- |
| Wasseranschluss eines Feldes | D8-Abfluss (`area`, in Zellen) im Umkreis 4 Zellen, voll ab 700 Zellen, Gerinne unter 40 zählen nicht | `area` ist ein Abfluss-GEWICHT (Regen × Fläche, Landmittel 1), keine Durchflussmenge |
| Überflutung | Füllstand `hf` der Priority-Flood > 0,01 über dem Boden | Ein Aufstau steht sofort auf Überlaufhöhe. Keine Füllbilanz, keine Flutwelle, kein Dammbruch |
| Ernte je Kopf | 1,25 × bewässerte Feldfläche (überflutet = 0) | Kein Saisonmodell. Die Leute bewirtschaften dieselben Felder, auch wenn weniger Leute da sind |
| Vorrat | Start 1,5, höchstens 2,0 Jahresrationen | |
| Abwanderung | 45 % je fehlender Jahresration, verlassen unter 20 % | Wer geht, kommt im Prototyp nicht zurück, sobald die Siedlung verlassen ist |
| Erholung | gutes Jahr: Vorrat +0,25, ab Vorrat 0,5 Bevölkerung +4 %/Jahr | |
| Überflutete Häuser | 0,35 Jahresrationen Reparatur je Jahr | |
| Zeit | gemeinsame Sim-Zeit; Jahr = zeitgewichtetes Mittel der Messungen nach jedem Schritt | Mehrjährige Schritte schließen jedes Jahr einzeln ab, alle mit der Messung vom Schrittende |
| Budget | 2,5 Erdbewegung | |
| Pinsel | Radius ≤ 3 Zellen, Abstand zu Häusern/Feldern ≥ Radius + 1,5 Zellen | |
| Versuchsdauer | 300 Jahre | |

**Gegenreaktion „Ausbessern":** Nach zwei schlechten Jahren in Folge (und mit
mindestens 30 % Bevölkerung) bauen die Leute jedes Jahr alle Spieler-Eingriffe
im Umkreis von 24 Zellen um ihr Dorf zurück. Das sind 0,03 Höhe je Zelle und
Jahr bei voller Bevölkerung, Richtung Ausgangshöhe. Es kostet 0,1
Jahresrationen je Jahr. Zurückgebaut wird nur, was der Spieler verändert hat.
Was der umgeleitete Fluss seither selbst eingetieft hat, müssen sie
mitabtragen. Erreichbar ist der niedrige Sattel, der hohe nicht.

## Reproduzierbare Versuche

Gemessen headless, wenn nicht anders angegeben in Ein-Jahres-Schritten
(`SimCoreTests/NatureScenarioDiagnostic.swift`,
`RS_MEASURE=1 swift test -c release --package-path SimCore --filter testNatureExperimentsDiagnostic`).
Die Eingriffe stehen als Daten in `NatureScenario` (`lowSaddleCut`,
`highSaddleCut`, `damBelowTalheim`). Die Wächter dazu sind
`SimCoreTests/NatureGameTests.swift`.

| Versuch | Eingriff | Kosten | Verlauf Talheim |
| --- | --- | --- | --- |
| 0: nichts tun | — | 0 | 300 Jahre stabil, alle drei Siedlungen ≥ 90 % Bevölkerung |
| A: niedriger Sattel | 6 Spitzhacken-Hiebe quer durch den Sattel | 0,68 | Wasser 0,91 → 0,23. Jahr 1–2 unterversorgt, Vorrat 1,5 → 0. Nach Jahr 2 schütten die Talheimer den Durchstich zu, der Fluss kehrt zurück, Talheim erholt sich |
| B: hoher Sattel | 12 Hiebe (doppelte Lage) | 1,36 | Wasser → 0,49 (unterhalb des Sattels sammelt das Tal noch etwas). Außerhalb der Reichweite, also keine Reparatur. Ab Jahr 4 Abwanderung, verlassen in **Jahr 13** |
| C: Damm unter Talheim | 16 Anheben-Striche, Stärke 3 | 2,55 (überzieht das Budget mit dem letzten Strich) | 94 % der Felder überflutet. Ab Jahr 2 graben die Talheimer den Damm ab, in Jahr 3 sind die Felder trocken. Talheim verliert 22 % der Leute und überlebt |
| C ohne Gegenreaktion | wie C, Ausbessern aus | 2,72 | Felder bleiben 90 % überflutet, verlassen in **Jahr 5** |
| wirkungsloser Eingriff | 6 Hiebe auf der Ost-Abdachung | > 0 | keine Änderung der Versorgung (±0,02), 20 Jahre stabil |

Die Entscheidung, die das Spiel stellt: **A** ist billig, aber reparierbar.
Wer nach A nachlegt, trifft eine Siedlung mit leerem Vorrat; die
„Zermürbung" ist ungetestet, aber angelegt. **B** ist teuer, aber endgültig.
Nach A bleiben 1,82 Budget, genug für B.

Weitere Belege (Wächter):

- Ein Totalausfall-Jahr vertreibt niemanden. Beim zweiten beginnt die
  Abwanderung, nach 5 Totalausfall-Jahren ist eine Siedlung verlassen. Bei
  halber Ernte dauert es länger als 8 Jahre.
- Gute Jahre füllen Vorrat und Bevölkerung wieder auf.
- Dieselbe Versorgungsgeschichte ergibt denselben Verlauf, egal ob sie in
  1/60-Jahres-Schritte (5 J./Sek. bei 60 Bildern/s), 0,2er-, 0,25er-, ganze
  oder mehrjährige Schritte zerlegt ist.
- Neustart ist bit-gleich (Fingerprint), auch über die Brücke
  (`game/tests/NatureChecks.gd`).
- Hintergrund- und synchroner Schritt buchen dieselben Spieljahre
  (`NatureSessionTests`).

Laufzeit: Ein Sim-Schritt auf der 128er-Karte kostet ~4–5 ms (60 × 5 Jahre in
0,27 s). 5 J./Sek. ist damit für die Sim kein Lastfall.

## Befund zur Überflutung

Der Weg „Wasser hinlenken/aufstauen" ist **mechanisch vorhanden und
demonstriert** (Versuch C). Die vorhandene Entwässerung reicht dafür:
Priority-Flood füllt das Becken hinter einem Damm bis zur Überlaufhöhe, und der
Spiel-Messwert ist genau dieser Füllstand. Ohne Gegenreaktion hat die
Produktionsphysik den Damm bis zur Aufgabe Talheims in Jahr 5 nicht von selbst
durchbrochen (90 % der Felder durchgehend überflutet). Länger ist das nicht
gemessen.

Offen bleibt:

- **Spielbar ist er im Standard-Budget nur knapp.** Ein Damm, der Talheims
  Felder flutet, kostet fast das ganze Budget. Er muss in Reichweite der
  Talheimer stehen, weil das Tal weiter unten zu stark fällt, und wird deshalb
  in zwei Jahren abgetragen. Ein Damm außerhalb der Reichweite (Zeile ≥ 90)
  müsste rund 0,04 hoch sein und ist im Budget nicht drin (nicht gemessen,
  aus der Talneigung abgeschätzt).
- **Der See ist eine Darstellung, keine Bilanz.** Er steht nach dem Nachzug
  sofort auf Überlaufhöhe (`snapWaterLevel`). Danach folgt der gezeigte
  Seespiegel `hf` ratenbegrenzt mit τ = 350 J. (`lakeLevelResponseYears`),
  das Spiel liest `hf` direkt. Hebt die Physik den Füllstand später an,
  kann die Anzeige der Spielwertung um Jahrzehnte hinterherhinken.
- Keine Flutwelle, kein Dammbruch, keine saisonalen Hochwasser.

Als nächster Ausbau wäre zu klären, ob ein eigenes, günstigeres
„Damm"-Werkzeug oder ein eigenes Flutbudget den Weg trägt.

## Spieltest — ausstehend

Auf dem Agent-Host gibt es keinen Bildschirm und keinen Renderer. Der Prototyp
ist dort weder gesehen noch mit der Maus gespielt worden. Belegt sind nur die
headless Regeln (XCTest) und der Godot-Vertrag über die Brücke
(`NatureChecks.gd` in CI). Für die Abnahme fehlt der Spieltest im maximierten
Fenster mit diesen Fragen aus dem Issue:

- Sind Ursache und Wirkung lesbar (Feldfarben, Panel, Eingriffsmarken)?
- Wie fühlen sich die Werkzeuge an? Trifft man den Sattel, ist der Radius
  richtig, ist das Budget spürbar?
- **Tempo:** Bei 5 J./Sek. dauert Versuch B (13 Jahre) **2,6 Sekunden**,
  die Reparatur in Versuch A 0,4 Sekunden. Die Vermutung aus den Zahlen ist,
  dass 5 J./Sek. für die Siedlungsreaktion zu schnell ist, während der Fluss
  bei diesem Tempo kaum sichtbar arbeitet (Erosion braucht Jahrhunderte). Das
  muss der Spieltest zeigen. 1 J./Sek. liegt als Vergleich im Panel.
- Entsteht nach der Reparatur in Versuch A eine echte Entscheidung (nachlegen
  oder hoher Sattel)?
- Motiviert das Ende zum Neustart?

**Ergebnis „Game Loop trägt / braucht Änderung / trägt noch nicht":** offen,
bis der Spieltest gemacht ist. Aus den headless Zahlen lässt sich nur sagen:
Ursache → Wirkung → Gegenreaktion → zweiter Zug funktioniert mechanisch, und
der Zeitmaßstab ist der wahrscheinlichste Anpassungsbedarf.

## Bekannte Grenzen

- Eine Karte, drei Siedlungen, keine Siedlungstypen, keine Wirtschaft.
- Ein Strich mit Anheben/Absenken kann sein Budget um den Rest des Strichs
  überziehen (geprüft wird vor dem Strich).
- Die Zeit läuft nach dem Versuchsende weiter, wenn man ▶ drückt; Striche sind
  dann gesperrt.
- Speichern/Laden kennt den Versuch nicht. Eine geladene Welt ist Sandkasten,
  ebenso „Neu" (beendet den Versuch, die 128er-Karte bleibt).
- Die Zeitsprung-Knöpfe (+100 J. …) bleiben sichtbar. Ein Sprung bucht die
  Spieljahre korrekt, überspringt aber jede Reaktion des Spielers.

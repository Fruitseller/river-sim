# Visueller Hill-Climber

Ziel: Das Spiel soll aussehen wie die aufgehübschten Spielbilder in
`docs/references/zielbild/` (d, e, f; Rollen im README dort). Die 49
Proxy-Punkte aus #174 waren erfüllt, das Bild trotzdem nicht. Dieser
Kletterer misst deshalb direkt das Bild: ein Bewertungsmodell vergleicht
blind zwei Stände gegen die Referenz.

## Werkzeuge

```sh
scripts/look/shots.sh <ordner> [game-ordner]     # 3 Aufnahmen: diorama, tal, nah (~1 min)
scripts/look/judge.sh <A-ordner> <B-ordner> [3]  # blinder Paarvergleich (~30 s)
```

`judge.sh` würfelt je Urteil, welcher Stand X und welcher Y ist, erlaubt
„GLEICH“ und druckt am Ende `ENTSCHEIDUNG B_BEHALTEN` oder
`ENTSCHEIDUNG VERWERFEN`.

### Regel (seit 2026-11-20, vom Eigner gelockert)

Gewertet wird über 30 Urteile (10 Läufe je Aufnahme, als ein Durchgang mit
10 oder zwei mit je 5). Behalten heißt:

- B − A beträgt mindestens 1/3 aller Urteile (≥ 10 von 30),
- A gewinnt höchstens 1/5 der Urteile (≤ 6 von 30),
- in keiner Aufnahme stehen mehr A- als B-Stimmen.

„GLEICH“ zählt damit nicht mehr gegen B. Bis 2026-11-20 galt „B ≥ 2/3 und
A ≤ 1/9“; das verwarf gemessen auch kleine echte Verbesserungen (Eichzeile
`performance` gegen `balanced`: 1 bis 4 A-Stimmen von 15), und in den
Totalen ist GLEICH für eine Änderung an 8 px breiten Flüssen das erwartbare
Urteil. Nacheichung der neuen Regel: derselbe Stand zweimal gerendert
0/0/30 (verworfen ✓); `performance` gegen `balanced` aus den alten Läufen
5/10/15 (verworfen, wie bisher); heute gegen Referenz und weichgezeichnet
gegen heute bleiben behalten. Die Urteile der Iterationen 1 bis 12 kippen
unter der neuen Regel nicht.

Die Bildrate darf seitdem bis zu 4 % schlechter sein als der
Vergleichsstand (Mittel); das lässt sich später zurückholen.

## Eichung (2026-11-18)

Standard-Bewerter: DeepSeek V4.1 Flash über opencode (kostenlos, ~4 s je
Urteil, liest Bilder). Je Zeile 3 Läufe × 3 Aufnahmen, wo nicht anders
angegeben.

| A gegen B | Erwartet | DeepSeek A/B/GLEICH | Entscheidung | GPT-6.1 Sol zum Vergleich |
| --- | --- | --- | --- | --- |
| heute gegen Referenzbilder | B klar | 0/8/1 | behalten ✓ | 0/9/0 |
| weichgezeichnet + entsättigt gegen heute | B klar | 0/7/2 | behalten ✓ | 0/7/2 |
| derselbe Stand zweimal gerendert, beide Reihenfolgen | Rauschen | 0/0/9 (5 Läufe: 0/0/15) | verworfen ✓ | 0/0/9 |
| `RS_QUALITY=performance` gegen `balanced` | B, kleiner echter Unterschied | 2/5/2; 5 Läufe: 4/6/5 und 1/4/10 | verworfen ✗ | 0/9/0 |

Lesart: DeepSeek trennt Rauschen sicher von klaren Verbesserungen, sieht
aber KLEINE echte Unterschiede nicht zuverlässig. Er verwirft also eher
zu viel als zu wenig (konservativ). Folgen für den Ablauf:

- Hypothesen so zuschneiden, dass ihre Wirkung im Bild deutlich ist;
  kleine Feinschliff-Schritte bündeln, bis sie sichtbar sind.
- Bei knappem Verwerfen (B ≥ 4 und A ≤ 1) einen zweiten Bewerter eines
  anderen Herstellers befragen, z. B. Gemini 4 Hydrogen als T3-Subagent
  (`delegate_task`, Bildpfade im Brief, derselbe Prompt wie in
  `judge.sh`). GPT-Modelle stehen derzeit nicht zur Verfügung (Limit).
- Ohne „GLEICH“ (erzwungene Wahl) ging der Rausch-Fall mit GPT 6:3 aus;
  die Regel hätte Rauschen in rund einem Viertel der Fälle behalten.
  Neue Bewerter oder ein geänderter Prompt werden vor dem Einsatz mit
  dieser Tabelle neu geeicht.

Nachtrag 2026-11-19: DeepSeek läuft über opencode als Agent mit Shell und
hat in mehreren Urteilen Verzeichnisse gelistet und die Aufnahmen unter
ihrem echten Pfad geöffnet (`…/base/…`, `…/it02/…`); der Vergleich war
dort nicht blind. `judge.sh` gibt seitdem jedem Urteil einen eigenen Ordner
mit neutralen Kopien (`ref.jpg`, `x.jpg`, `y.jpg`). Nacheichung damit:
derselbe Stand zweimal gerendert 0/0/9 (verworfen ✓). Beide Skripte
brauchen ABSOLUTE Pfade. `shots.sh` weckt den Bildschirm und hält ihn wach
(`caffeinate`): bei schlafendem Bildschirm drosselt macOS das Fenster, eine
Aufnahme dauerte dann 16 min statt 20 s, der Bildraten-A/B wird unbrauchbar.

## Ablauf je Iteration

1. Vergleichsstand sichern: `cp -R game "$ALT/game"` (mit `bin/` und `.godot/`),
   Aufnahmen `scripts/look/shots.sh "$ALT/shots"`.
2. EINE Hypothese umsetzen (ein Problem, z. B. „Flussbett liegt nicht im
   Gelände“), bauen.
3. Harte Schranken, alle grün, sonst verwerfen:
   - SimCore-Pflichtsuite und die Godot-Vertragstests (AGENTS.md § Befehle),
   - Determinismus (`simperf --hash` unverändert, wenn die Physik nicht
     Gegenstand der Hypothese ist),
   - Bildrate höchstens 4 % schlechter (Mittel): Zeitraffer-A/B nach
     AGENTS.md (`scripts/timelapse-timing.sh "$ALT/game" game`, maximiert),
   - Wasser liegt nirgends sichtbar über dem Gelände (von Auge in `nah`;
     ein automatischer Wächter dafür fehlt noch).
4. `scripts/look/shots.sh neu` und `scripts/look/judge.sh "$ALT/shots" neu`.
5. `B_BEHALTEN` → committen (Nachricht nennt das Urteil `A x B y GLEICH z`).
   `VERWERFEN` → zurücksetzen, Begründungen der Urteile lesen, nächste
   Hypothese.
6. Drei verworfene Iterationen am selben Problem: nicht weiter an Reglern
   drehen, sondern strukturell eskalieren (s. Council).
7. Alle 5 behaltenen Iterationen: Kontaktbogen (alt | neu | Referenz je
   Aufnahme) an den Eigner, er hat das letzte Wort.

## Was der Bewerter nicht beurteilen darf

- Die Führung der Flussläufe (Schlingen, die sich fast schließen,
  Parallel-Arme, Lauf entlang der Küste). Das ist Physik, eigene Achse mit
  Sim-Kennzahlen, kein Bild-Ziel.
- Formen in `e-tal-kueste-schoen.jpg` (erfundene Fjordwände).

## Council

Im inneren Kreis NICHT: Der Council-Skill startet je Mitglied einen
vollen Agenten (Minuten, hohe Kosten) und vergibt absolute Noten
von 10, ohne Ziel zu kennen. Für die Ja/Nein-Entscheidung je Iteration
ist der blinde Paarvergleich schneller und gemessen trennscharf.

Verfügbare Modelle (Stand 2026-11-18): DeepSeek V4.1 Flash (Bilder) und
GLM 5.3 (keine Bilder) kostenlos, aber zeitweise geblockt; Sonnet 5.5 und
Gemini 4 Hydrogen nur sparsam, Nutzung im Blick behalten; GPT-Modelle
derzeit nicht (Limit). Alle sind auch als T3-Subagenten
(`delegate_task`) nutzbar.

Der Council lohnt sich an drei Stellen:

1. **Prüfpunkt alle 5 behaltenen Iterationen** (Modus Opinion): Diff plus
   Kontaktbogen. Er fängt, was ein einzelner Bewerter belohnt, obwohl es
   falsch ist: gemalte statt echte Tiefe, gebrochene Verträge, Kosten.
2. **Eskalation** nach drei Fehlschlägen am selben Problem: drei Hersteller
   liefern verschiedene strukturelle Vorschläge statt der vierten Variante
   desselben Reglers.
3. **Zweiter Bewerter gegen Goodhart**: Wer nur gegen EIN Modell klettert,
   optimiert dessen Geschmack. Am Prüfpunkt urteilt deshalb zusätzlich
   Gemini 4 Hydrogen (T3-Subagent) über alt gegen neu; widerspricht er
   DeepSeek deutlich, entscheidet der Eigner.

## Prompt für den Agenten

```
Verbessere das Aussehen von river-sim nach docs/look-hillclimb.md.
Erstes Problem: Wasser liegt nicht im Gelände (Flüsse wirken als flache
Bänder auf bzw. über dem Gelände, ohne Bett, Ufer und Tiefe; Referenz
docs/references/zielbild/f-nah-flussschleife-schoen.jpg).
Arbeite in Iterationen genau nach dem Ablauf dort: eine Hypothese,
harte Schranken, shots.sh, judge.sh, behalten nur bei B_BEHALTEN.
Führe ein Logbuch in docs/look-hillclimb-log.md (Hypothese, Urteil,
behalten/verworfen, Kernsatz der Begründungen).
Nach drei verworfenen Iterationen am selben Problem: stopp und schlage
einen strukturellen Umbau vor, statt weiter zu drehen.
Nach fünf behaltenen Iterationen: stopp, Kontaktbogen und Logbuch an mich.
```

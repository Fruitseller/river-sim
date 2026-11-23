# Migration des Mäandergürtels (Howard–Knutson auf Breiten-Skala)

Der Mäandergürtel (Issue #174, Paket B) migriert je Lauf nach Howard–Knutson: Verschiebungsrate entlang der linken Normalen `Ω·C + Γ·∫C stromauf`, Kern-Länge ∝ Breite, Rate ∝ Breite × (Breite · eff), mit Mobilität und Talwand-Bremse. Die Festlegungen unten sind jeweils gemessen.

## Geometrie

- Kanalbreite aus dem Abfluss mit DERSELBEN Kurve wie die Band-Geometrie (`WaterRender.ribbonHalfWidthCells`), damit Bett und Band gleich breit sind (#174).
- Krümmung für das Querprofil (`bendCurvature`): `g.curv` (±½ Breite) trägt noch Knicke im Knotenabstand (gemessen |κ|·b bis 5, Radius unter einer halben Breite); daraus legte der Stempel Knoten für Knoten abwechselnd gekippte Profile übereinander, im Mittel ein symmetrisches V. Kolk und Gleithang antworten auf den Bogen, nicht auf den Knick; deshalb gemittelt über ±`meanderBeltProfileWidths` Breiten. Eine Quelle für Stempel und Render.
- `bendStrength` liefert dem Render (#174 Paket C Teil 2) dieselbe Größe, mit der `Terrain.beltStamp` den Kolk zur Außenkurve schiebt (|Krümmung| · Breite · `meanderBeltPoolGain`, gedeckelt auf 1), mit dem Vorzeichen der Krümmung und mal der Mobilität: wo die Sim kein asymmetrisches Profil baut, ist auch keins zu malen.
- Mobilität aus der Längsneigung über ±1,5 Kanalbreiten: über ±k (≈ 3 Zellen) brach jede Stufe im eingeschnittenen Bett den mobilen Abschnitt auf (gemessen 12–45 mobile Knoten am Hauptlauf von Seed 1337). Unter dem Meer wandert nichts; an Quelle und Mündung wird über 3 Breiten ausgeblendet, sonst staut sich der Stromauf-Term am festen Ende zu Spiralen.

## Raten

- Nur der Stromauf-Term läuft explizit. Der lokale Term (Ω < 0, zur Krümmungsmitte) ist eine Diffusion der Linie mit κ = |Ω|·Rate·b² und läuft als implizit stabile Glättung (`implicitDiffuse`, Thomas-Algorithmus) in `migrateBeltChannel`.
- Die Ufer-Erodierbarkeit (Mobilität × Talwand-Bremse) skaliert AUCH diesen impliziten Lokalterm: bremste sie nur den Wachstumsterm, überwog an jeder gebremsten Stelle die Diffusion, und die Linie wurde gerade statt stehen zu bleiben (gemessen: Rate 1,5 Zellen je 1000 Jahre, Bewegung 0,2, Sinuosität fallend).
- Talwand-Bremse: liegt das Gelände ein paar Breiten weiter in Bewegungsrichtung über `meanderBeltBrakeDepths` Rinnentiefen (Rinnentiefe aus `channelCarve`, mindestens die Kanaltiefe) über der Linie, hält der Lauf; Hügel und Talflanken begrenzen den Gürtel, Unebenheiten der Aue nicht. Verworfen: Ufer gegen gegenüberliegendes Ufer direkt am Kanal (reagierte auf jedes sanfte Quergefälle, Sinuosität 1,1–1,2); ganz ohne Bremse lief der Lauf über die Ebene ins Knäuel.
- Die Gesamtrate wird längs über ±½ Breite geglättet: verschiedene Bremsfaktoren je Knoten erzeugten einen Zickzack im Knotenabstand unter der Krümmungs-Skala, den der Lokalterm nicht sah; seine Knick-Krümmung trieb die CFL-Teilschritte in den Deckel.
- Entfernt mit #187 (beide standen auf 0): der Zug zur tieferen Uferseite (`meanderBeltPull`; mit Stärke 1 hielt er in jedem V-Tal die Linie gerade, Sinuosität 1,2) und die Ufer-Kohäsion (`meanderBeltCohesion`; mit 0,5 Sinuosität 1,3 statt 2,0, Bewuchs bremst im Gürtel über die Ufer-Zerstörung im Stempel). Die Kopplung an die Entwässerung leistet `Terrain.coupleBeltToDrainage`.

## Störquelle (`perturb`)

Howard–Knutson ist konvektiv instabil: Bögen wachsen und wandern stromab, eine einmal gerade Strecke bleibt gerade. Ohne Störquelle spülte der Kern seine Anfangszacken in ~60.000 Jahren hinaus und lag danach als gerade Linie mit einer Spirale am festen Ende (Sinuosität 1,00 ab Jahr 62.000, `testBeltKernelDiagnostic`). In echten Auen kommt die Störung aus der Heterogenität der Ufer (Tonpfropfen alter Altarme, Bewuchs, Zubringer). Auslenkung je Knoten `A · b · √(Rate · dt) · ξ` mit ξ ~ Einheitsvarianz, über ±½ Breite geglättet, mit der Erodierbarkeit gewichtet. Varianz ∝ dt: in Verteilung schrittweiten-unabhängig (Wiener-Prozess), nicht pfadgleich. ξ ist ein SplitMix64-Hash aus Zeit, Lauf und Knoten, deterministisch und nach `restore` reproduzierbar, ohne neuen Zustand.

## Teilschritte und parallele Läufe

Die Teilschrittzahl eines Laufs kommt aus einer geländeunabhängigen Schranke der anfänglichen Rate (`beltFootprint`; Mobilität, Sättigung und Bremse liegen in 0…1, Beträge vor der Ratenglättung begrenzen jede Vorzeichen-Auslöschung) und bleibt im gesamten Lauf konstant. Explizite Bewegung und Störung sind je Teilschritt ≤ ½ Knotenabstand; implizite Diffusion (nichtnegative Koeffizienten), Cutoff und Resample bleiben in der konvexen Hülle. Daraus folgt ein fester Radius des Wirkungsfensters (Teilschritte × Knotenabstand plus Bank-Breite plus zwei Zellen für Rundung, bilineare Abfragen und die vier Nachbarn der Altarm-Pfropfen), über den `Terrain.parallelBeltRuns` entscheidet, welche Läufe parallel laufen dürfen. Die gemeinsame Altarm-Historie wird erst nach allen Arbeiten in ursprünglicher Lauf-Reihenfolge angehängt (`appendBeltHistory`), damit das Ergebnis bit-identisch zur sequenziellen Reihenfolge bleibt.

Betrifft: `MeanderState.beltWidthCells`, `MeanderState.bendStrength`, `MeanderState.bendCurvature`, `MeanderState.beltRatesAndErodibility`, `MeanderState.migrateBeltChannel`, `MeanderState.perturb`, `MeanderState.implicitDiffuse`, `MeanderState.beltFootprint`, `MeanderState.appendBeltHistory`, `Terrain.meanderBeltStep`, `Terrain.parallelBeltRuns`, `Terrain.beltStamp`

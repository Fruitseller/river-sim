# Pfützen-Verlandung: nur seichte Komponenten ohne See-Kern

`fillShallowPonds` füllt SEICHTES Ponding (≤ `puddleFillDepth`) auf Land mit Sediment auf. Ohne den Pass trugen die Auen dauerhafte Flachwasser-Sprenkel knapp über der Render-Schwelle (zerfetzte Blob-Felder). Anders als `fillLakes` ist der Pass tiefen-gedeckelt: echte Seen bleiben. Ziel ist das volle `hf`, nicht der geglättete `waterLevel` (über 3 Seeds ohne messbaren Volumen-Effekt, drückte aber die Braid-Bänke von 9 auf 2).

## Komponenten statt Einzelzellen

Verlandet werden nur 4er-zusammenhängende Ponding-Komponenten OHNE See-Kern. Die Pauschal-Verfüllung hob sonst auch die kilometerbreiten Sub-0.06-Ufersäume der großen Seen als Ganzes an, sichtbar als "wachsender Boden ohne Wasser" (gemessen: 90 % der Tiefland-Hebung, +0.03 je 6000 Jahre auf den Säumen). Ein See ist eine Komponente mit mindestens `puddleLakeCoreCells` Zellen tiefer als `puddleFillDepth` (absolute Zellzahl); sein Ufersaum verlandet nur noch physisch über die Droplet-Deltas. Braid- und Auen-Pfützennetze sind überall seicht und verlanden weiter komplett, egal wie ausgedehnt.

Verworfene Kriterien, beide gemessen:
- "berührt irgendeinen tiefen Pool": nahm auch Braid-/Auen-Netze aus, die fast immer an einem Einzelpool hängen (Braid-Insel-Guard kippte 3 gegen 4).
- relativer Kern-Anteil (≥ 20 %): ließ genau den Problemfall durch, riesiger seichter Saum um kompakten tiefen Kern (Seed 1337: nur −45 % Saum-Hebung statt −100 %).
- eine Größen-Schwelle traf je nach Seed auch Bank-Pfützen: der Braid-Insel-Guard kippte bei 64 UND bei 400 Zellen.

## Ausnahmen

- Mäander-Betten (`isChannel`): das gecarvte Bett nicht zuschütten.
- Wasserführende Läufe (Issue #108, `puddleFillSkipsFlowCells`): dieselbe Regel über den D8-Abfluss ab `channelFlowMinCells`, weil die dendritischen Läufe keine Maske haben. Begründung und Messwerte stehen bei `SimConfig.puddleFillSkipsFlowCells`; der Schalter ist derzeit geparkt.
- Wasserfläche eines abflusslosen Beckens (Issue #11): ihren Spiegel setzt der Wasserhaushalt, eine verdunstungs-gedeckelte Playa ist per Konstruktion seicht; die Verlandung würde genau die Fläche zuschütten, die #11 freigelegt hat. Der trockengefallene Boden hat `hf = h` und fällt schon durchs Tiefen-Gate.
- Vergletscherte Zellen (`underIce`): unter dem Eis steht kein Wasser. `hf` stammt vom Schrittanfang, `updateIce` hat das Bett danach schon geschliffen; jede Zelle, die der Gletscher um mehr als 0,001 tiefer legt, sähe wie eine Pfütze aus und bekäme den Schliff teilweise wieder aufgefüllt. Das traf nur große Schritte und machte die Gletscher-Erosion schrittweitenabhängig: am Gipfel +0,017 Wiederauffüllung in 4000 Jahren bei dt = 1000 gegen +0,002 bei dt = 100 (`docs/glacier-measurements.md` §L). Ohne Eis ist die Maske leer, bit-identisch.
- Frische Baustelle (Issue #26): solange an einer Zelle Regeneration aussteht (`regenPending ≠ 0`), verlandet sie nicht. Auf einer eben planierten Fläche würde der Pass genau das Mikro-Relief zuschütten, aus dem sich die neue Entwässerung organisiert (junge Grundmoränen-Landschaften sind Seen-Mosaike). Kriterium ist bewusst das offene Budget, keine eigene Störungs-Schwelle: eine Schwelle (probiert: 5 % Reststörung ≈ 3 τ) öffnet ein Fenster, in dem der Boden noch steigt oder sinkt, die Verlandung aber schon mit bis zu 0.06 gegen einen Rest von Tausendsteln zuschüttet. So endet die Aussetzung genau, wenn `regenerateDisturbed` abschaltet und das Budget nullt.

Der Pass schreibt `h`/`sed` direkt, nicht über den Bett-Funnel (s. zugehöriges Issue).

Betrifft: `Terrain.fillShallowPonds`, `SimConfig.puddleFillDepth`, `SimConfig.puddleLakeCoreCells`, `SimConfig.puddleFillSkipsFlowCells`, `SimConfig.puddleFillYears`, `docs/glacier-measurements.md`

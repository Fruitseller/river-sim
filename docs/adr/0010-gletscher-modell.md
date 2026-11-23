# Gletscher: Flux-Erosion mit linearem, sub-getaktetem Eistransport (Issue #35)

Das in #33 angelegte Feld `Terrain.ice` bekommt mit `Terrain.updateIce` Transport, Erosion und Massenbilanz, alle in einem sub-getakteten Takt nach dem Vorbild der Hangdiffusion:

    1. TRANSPORT  Eis fließt auf der Eis-Oberfläche s = h + ice bergab,
                  Fluss je Kante ∝ Dicke × Gefälle, Ausstrom je Zelle gedeckelt.
    2. EROSION    E = iceErodeK · q^m · S   (q = Dicke × Oberflächen-Gefälle)
    3. BILANZ     dI/dt = a − μ·I in Relaxationsform; was über die Schmelze
                  verschwindet, legt Moräne ab.

Erosionsgesetz: Flux-Modell (Hergarten 2021 / Liebl et al. 2023, `docs/research-climate-cryosphere.md` §4.3) statt nichtlinearer SIA-Diffusion, deren Zeitschritt-Deckel an H^{n+2} hängt und mit dem +10.000-Jahre-Sprung nicht budgetierbar ist. Der Transport ist ein linearer Diffusions-Pass mit konstantem kappa, linear in Dicke und Gefälle, und hat damit denselben budgetierbaren Deckel wie die Hangdiffusion; die Vereinfachung gegen D ∝ H^{n+2}|∇s|^{n−1} ist bewusst.

Transport statt Akkumulation je Schritt auf dem D8-Baum (wie bei Liebl et al.): eine Gletscherzunge entsteht genau dort, wo Eis weiter reicht als seine Massenbilanz. Eine Akkumulation je Schritt hätte Eis nur, wo es akkumuliert, also Kare, keine Zungen. Gegenprobe (n = 256, 10k Jahre): mit Transport 968 Zellen unter der Firn-Grenze, ohne 63 (`docs/glacier-measurements.md` §C).

Eis als Auflage über dem Bett: das Eis liegt nicht in `h`, die Entwässerung läuft unverändert auf dem Bett. Ab `iceMinThickness` kommt eine Zelle in die Maske `Terrain.underIce`, die über den Bett-Funnel (ADR 0003) jeden fluvialen Abtrag sperrt. Deshalb steht der Pass im Schritt nach dem Abflussfeld und vor jeder fluvialen Höhenänderung.

Abgeschaltet heißt bit-identisch: mit `iceEnabled = false` läuft der Pass nicht, `ice` bleibt 0, `underIce` leer, beide Gates fallen weg, und die Welt rechnet wie zu #33/#36; ebenso, solange keine Zelle Eis trägt. Die Generierung bleibt eisfrei (`generate` schwingt nur das Klima ein), das Eis wächst ab Jahr 0, damit sich die kalibrierte Welt-Erzeugung nicht verschiebt.

dt-Invarianz (Nachtrag #174, `docs/glacier-measurements.md` §L): in der Produktion hing die Eismasse an der Schrittweite (Jahr 20.000, dt 100 gegen 1000: 49/122 bei Seed 1337, 65/31 bei 42, 159/53 bei 20). Drei Ursachen, alle Kopplungen eines großen Schritts an Größen vom Schrittanfang: die Sub-Taktung deckelte nur `kappa·ΣΔs⁺`, nicht die Diffusionszahl `kappa·I` (dickes Eis auf flachem Bett lief instabil, jetzt zusätzlich `kappa·I ≤ iceFlowSubCap/2`); `fillShallowPonds` füllte, was der Gletscher im Schritt schliff, als Pfütze wieder auf (unter dem Eis verlandet seitdem nichts); die Temperatur kam vom Schrittanfang (jetzt rechnet der Teilschritt sie aus dem aktuellen Bett). Jede Ursache allein zu beheben reichte nicht; danach liegen dt 15/100/1000 auf allen drei Seeds beieinander.

Verworfen:
- Nichtlineare SIA-Diffusion: Zeitschritt-Deckel an H^{n+2}, im großen Sprung nicht budgetierbar.
- Eis-Akkumulation je Schritt auf dem D8-Baum: Kare ohne Zungen.

Werte je Konstante (`iceFirnPerSnowYear`, `iceTurnoverYears`, `iceMeltPerKYear`, `iceFlowK`, `iceFlowSubCap`, `iceFlowMoveFraction`, `iceMinThickness`, `iceCoverRef`) mit Sweeps: `docs/glacier-measurements.md` § Kalibrierwerte.

Betrifft: `Terrain.updateIce`, `Terrain.ice`, `Terrain.underIce`, `SimConfig.iceEnabled`, `SimConfig.iceFlowK`, `SimConfig.iceFlowSubCap`, `SimConfig.iceMinThickness`, `Terrain.fillShallowPonds`

import Foundation
import SimCore

/// Makrofarbe und Materialgewichte des Geländes als drei RGBA8-Puffer.
///
/// Die Farbe trägt nur großräumige Sim-Signale wie Biom, Salz und Eis. Der
/// Shader baut daraus zusammen mit `surfaces` und `covers` die eigentliche
/// Oberfläche. So bleiben Materialgrenzen an die Physik gebunden, ohne die
/// Sim-Zellen als verwaschene "Textur" sichtbar zu machen.
///
/// Die geomorphologische Verteilung (Issue #174, Paket D) kalibriert
/// `SimCore.MaterialRender`: Fels auf steil-konvexen Formen, Schutthalden
/// darunter, blankes Gletschereis getrennt vom Schnee, Rohboden nur auf
/// gestörten Flächen, helle Talboden-Wiese.
public enum TerrainColorRenderer {
    public struct Buffers {
        /// RGB = Makrofarbe, A = Sandgewicht als `max(Strand, Bank)`: Strand
        /// aus `CoastMaterial` (Issue #174 C), frische Gleithang-Bank aus
        /// `BarMaterial` (Issue #174 C2); 0 = kein Sand.
        public let colors: [UInt8]
        /// R = Vegetation, G = freier Fels, B = Schnee/Eis,
        /// A = Lithologie-Härte von −1 ... +1 auf 0 ... 1 abgebildet.
        public let surfaces: [UInt8]
        /// Bodenbedeckung (Issue #174 D): R = Schutthalde, G = blankes
        /// Gletschereis als Anteil an der Kältedeckung (B von `surfaces`),
        /// B = Rohboden (frisch gestört), A = Talboden-Wiese (Tönung, kein
        /// eigenes Gewicht).
        public let covers: [UInt8]
    }

    /// Konvexität einer Zelle in Sim-Höhe: eigene Höhe minus Mittel der vier
    /// Nachbarn im Abstand 2 (Stencil-Weite von `Terrain.macroSlope`).
    /// Positiv auf Graten, negativ in Rinnen. Nur für 2 ≤ i,j ≤ n−3 gültig.
    @inline(__always)
    static func convexity(_ p: UnsafePointer<Double>, _ k: Int, _ n: Int) -> Double {
        p[k] - (p[k + 2] + p[k - 2] + p[k + 2 * n] + p[k - 2 * n]) * 0.25
    }

    static func convexity(_ a: [Double], _ k: Int, _ n: Int) -> Double {
        a.withUnsafeBufferPointer { convexity($0.baseAddress!, k, n) }
    }

    /// Felsanteil eines Standorts (0 … 1) aus Weltsteigung und Konvexität
    /// (Welteinheiten): die Steigungsschwellen rücken auf Graten nach unten
    /// und in Rinnen nach oben (`MaterialRender.convexSlopeShift`).
    @inline(__always)
    static func rockTarget(worldSlope: Double, convexity: Double) -> Double {
        let c = min(1, max(-1, convexity / MaterialRender.convexRef))
        let shift = c * MaterialRender.convexSlopeShift
        return smoothstep(MaterialRender.rockSlopeLo - shift, MaterialRender.rockSlopeHi - shift,
                          worldSlope)
    }

    /// Haldenanteil (0 … 1): verbreiterter Felsanteil in der Nähe (`source`),
    /// Steigung im Bereich des Schüttwinkels und eine Hohlform — Schutt
    /// sammelt sich in Rinnen und am Hangfuß (`screeConcavity`), Rippen und
    /// gerade Hänge tragen Fels oder Bewuchs.
    @inline(__always)
    static func screeTarget(worldSlope: Double, source: Double, convexity: Double) -> Double {
        smoothstep(MaterialRender.screeSourceLo, MaterialRender.screeSourceHi, source)
            * smoothstep(MaterialRender.screeSlopeLo, MaterialRender.screeSlopeHi, worldSlope)
            * smoothstep(0, MaterialRender.screeConcavity, -convexity)
    }

    /// Berechnet alle drei Puffer in EINEM Aufruf. Farbe und Materialgewichte
    /// brauchen dieselben teuren Standortwerte (`macroSlope`, Habitat,
    /// Schnee/Eis); getrennte Callables würden diese Arbeit pro Textur-Update
    /// vervielfachen.
    ///
    /// Drei Durchgänge: (1) Felsanteil je Zelle, (2) Felsanteil quer
    /// verbreitert (separierbarer Maximum-Filter, Quelle der Halden), (3) Farbe
    /// und Gewichte. Jeder Durchgang schreibt nur seine eigene Zelle, parallel
    /// also bit-identisch zur sequenziellen Schleife.
    public static func buffers(_ terrain: Terrain) -> Buffers {
        buffers(terrain, bars: BarMaterial.field(terrain))
    }

    /// Wie oben, mit dem Gürtel-Material von außen (`RenderState` rechnet es
    /// einmal und gibt es auch der Schutzmaske). Passt `bars` nicht zum
    /// Gitter, bleibt der Gürtel unsichtbar statt falsch.
    public static func buffers(_ terrain: Terrain, bars: BarMaterial.Field) -> Buffers {
        let n = terrain.cfg.n
        let h = terrain.h
        let rain = terrain.rain, veg = terrain.veg
        let salt = terrain.saltCrust
        // Prüft n > 0 sowie die exakte Größe (n * n) aller vier direkt in der Pixelschleife
        // ohne Fallback gelesenen Felder (h, rain, veg, saltCrust), um Out-of-Bounds-Zugriffe
        // sicher auszuschließen.
        // lithHardness, snow, ice und disturb werden bewusst NICHT im Guard gefordert: Sie
        // sind optionale Feature-Felder (leer, wenn Feature deaktiviert) und besitzen weiter
        // unten einen [0.0]-Fallback mit bedingter Auswertung (lithOn, snowOn, iceOn, rawOn).
        // Bei Größen-Mismatch oder n == 0 liefert der Guard bewusst still leere Puffer zurück
        // statt laut zu scheitern (preconditionFailure): Da dieser Code pro Textur-Update im
        // Render-Pfad läuft (Godot/GDExtension), ist ein harter Crash mitten im Frame schlechter
        // als ein leeres Render-Ergebnis. Zudem ist n == 0 der etablierte Vertrag für leere Texturen.
        guard n > 0,
              h.count == n * n,
              rain.count == n * n,
              veg.count == n * n,
              salt.count == n * n else {
            return Buffers(colors: [], surfaces: [], covers: [])
        }
        let sea = terrain.cfg.sea
        let lith = terrain.lithHardness.count == n * n ? terrain.lithHardness : [0.0]
        let lithOn = lith.count == n * n
        let snow = terrain.snow.count == n * n ? terrain.snow : [0.0]
        let snowOn = snow.count == n * n
        let snowRef = terrain.cfg.snowCoverRef
        let ice = terrain.ice.count == n * n ? terrain.ice : [0.0]
        let iceOn = ice.count == n * n
        let iceRef = terrain.cfg.iceCoverRef
        let disturb = terrain.disturb.count == n * n ? terrain.disturb : [0.0]
        let rawOn = disturb.count == n * n
        let temp = terrain.temperature.count == n * n ? terrain.temperature : [0.0]
        let tempOn = temp.count == n * n
        let bands = terrain.heightBands
        // Weltsteigung aus `macroSlope` wie in `ForestCanopyMask`; ohne
        // Schrittweite (world <= 0 oder nicht endlich) gibt es keine
        // Weltsteigung, dann tragen nur die Höhenbänder Fels.
        let cell = terrain.cfg.world / Double(n)
        let slopeScale = cell > 0 && cell.isFinite ? 2 * RenderContract.heightScale / cell : 0
        let hscale = RenderContract.heightScale
        let radius = max(0, MaterialRender.screeReachCells)
        // Strand und Felsküste (Issue #174 C): Abstand zum Meer je Zelle.
        let coastDistance = CoastMaterial.seaDistance(terrain)
        let barsOn = bars.fits(n * n)
        let barSand = barsOn ? bars.sand : [0]
        let barVeg = barsOn ? bars.vegShift : [0]
        let barReed = barsOn ? bars.reed : [0]
        // Aue: alte Bänke des Mäandergürtels tragen Talboden-Wiese (s. unten).
        let barAge = terrain.barAge.count == n * n ? terrain.barAge : [-1.0]
        let aueOn = barAge.count == n * n
        let reedColor = WaterRender.oxbowReedColor
        let vegMax = MaterialRender.vegAmountMax, mineralTint = MaterialRender.mineralTint

        var colors = [UInt8](repeating: 255, count: n * n * 4)
        var surfaces = [UInt8](repeating: 0, count: n * n * 4)
        var covers = [UInt8](repeating: 0, count: n * n * 4)
        // Felsanteil je Zelle (Durchgang 1), je Zeile und dann je Spalte
        // verbreitert (Durchgang 2).
        var rockField = [Float](repeating: 0, count: n * n)
        var rowSpread = [Float](repeating: 0, count: n * n)
        var reach = [Float](repeating: 0, count: n * n)

        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeBufferPointer { rnb in
        veg.withUnsafeBufferPointer { vgb in
        salt.withUnsafeBufferPointer { slb in
        lith.withUnsafeBufferPointer { ltb in
        snow.withUnsafeBufferPointer { snb in
        ice.withUnsafeBufferPointer { icb in
        disturb.withUnsafeBufferPointer { dsb in
        temp.withUnsafeBufferPointer { tmb in
        rockField.withUnsafeMutableBufferPointer { rfb in
        rowSpread.withUnsafeMutableBufferPointer { rsb in
        reach.withUnsafeMutableBufferPointer { reb in
        coastDistance.withUnsafeBufferPointer { cdb in
        barSand.withUnsafeBufferPointer { bsb in
        barVeg.withUnsafeBufferPointer { bvb in
        barReed.withUnsafeBufferPointer { brb in
        barAge.withUnsafeBufferPointer { bab in
        colors.withUnsafeMutableBufferPointer { cb in
        surfaces.withUnsafeMutableBufferPointer { sb in
        covers.withUnsafeMutableBufferPointer { cvb in
        // Nach dem Guard oben hat jeder Puffer mindestens eine Zelle (Eingaben n*n bzw. [0.0],
        // Ausgaben n*n*4 mit n > 0), baseAddress ist beweisbar ungleich nil.
        // Force-Unwrap folgt dem Stil der Nachbar-Renderer (WaterFieldRenderer, RiverRibbonRenderer).
        let ph = hb.baseAddress!, prain = rnb.baseAddress!, pveg = vgb.baseAddress!
        let psalt = slb.baseAddress!, plith = ltb.baseAddress!
        let psnow = snb.baseAddress!, pice = icb.baseAddress!, pdist = dsb.baseAddress!
        let ptemp = tmb.baseAddress!
        let prock = rfb.baseAddress!, prow = rsb.baseAddress!, preach = reb.baseAddress!
        let pcolor = cb.baseAddress!, psurface = sb.baseAddress!, pcover = cvb.baseAddress!
        let pcoast = cdb.baseAddress!
        let pbsand = bsb.baseAddress!, pbveg = bvb.baseAddress!, pbreed = brb.baseAddress!
        let pbage = bab.baseAddress!

        // (1) Felsanteil aus Weltsteigung und Konvexität, nur auf Land und
        // innerhalb des ±2-Stencils (am Rand ist Meer).
        parallelChunks(n) { jLo, jHi in
            for j in jLo..<jHi where j > 1 && j < n - 2 {
                for i in 2..<max(2, n - 2) {
                    let k = j * n + i
                    guard ph[k] > sea + 0.012 else { continue }
                    prock[k] = Float(rockTarget(
                        worldSlope: Terrain.macroSlope(ph, k, n) * slopeScale,
                        convexity: convexity(ph, k, n) * hscale))
                }
            }
        }
        // (2) Separierbarer Maximum-Filter über ±`screeReachCells`.
        parallelChunks(n) { jLo, jHi in
            for j in jLo..<jHi {
                for i in 0..<n {
                    var m: Float = 0
                    for d in max(0, i - radius)...min(n - 1, i + radius) { m = max(m, prock[j * n + d]) }
                    prow[j * n + i] = m
                }
            }
        }
        parallelChunks(n) { jLo, jHi in
            for j in jLo..<jHi {
                for i in 0..<n {
                    var m: Float = 0
                    for d in max(0, j - radius)...min(n - 1, j + radius) { m = max(m, prow[d * n + i]) }
                    preach[j * n + i] = m
                }
            }
        }

        // (3) Farbe und Gewichte.
        parallelChunks(n) { jLo, jHi in
            for j in jLo..<jHi {
                for i in 0..<n {
                    let k = j * n + i
                    let v = ph[k]
                    let hard = lithOn ? min(1, max(-1, plith[k])) : 0
                    var r = 0.0, g = 0.0, b = 0.0
                    var vegWeight = 0.0, rockWeight = 0.0, coldWeight = 0.0
                    var screeWeight = 0.0, bareIce = 0.0, rawWeight = 0.0, valley = 0.0
                    let interior = i > 1 && i < n - 2 && j > 1 && j < n - 2
                    var sand = 0.0

                    if v <= sea + 0.012 {
                        (r, g, b) = gradColor(v)
                        // Der Strand reicht bis an die Wasserlinie (#174 C).
                        if v > sea && interior {
                            sand = CoastMaterial.sand(distance: pcoast[k],
                                                      slope: Terrain.macroSlope(ph, k, n),
                                                      height: v - sea)
                        }
                    } else {
                        var slope = 0.0, convex = 0.0
                        if interior {
                            slope = Terrain.macroSlope(ph, k, n)
                            convex = convexity(ph, k, n) * hscale
                        }
                        let worldSlope = slope * slopeScale
                        let steep = clamp01(slope * 45)

                        // Dunkler Grundfels statt der bisherigen kreidigen
                        // 0.38...0.45-Fläche. Der Shader ergänzt Materialdetail
                        // und Rauheit; hier bleibt nur die großräumige Tönung.
                        r = 0.29 + 0.035 * steep
                        g = 0.30 + 0.035 * steep
                        b = 0.31 + 0.04 * steep

                        let habitat = Terrain.vegetationSuitability(
                            height: v, slope: slope, rain: prain[k], bands: bands)
                        let vegAmount = clamp01((0.5 + 0.5 * pveg[k]) * habitat * 1.3) * vegMax
                        r += (0.15 - r) * vegAmount
                        g += (0.32 - g) * vegAmount
                        b += (0.10 - b) * vegAmount

                        let highRock = bands.rockAmount(v)
                        if highRock > 0 {
                            r += (0.34 - r) * highRock
                            g += (0.35 - g) * highRock
                            b += (0.37 - b) * highRock
                        }

                        let snowCover = snowOn
                            ? Terrain.snowCoverage(swe: psnow[k], ref: snowRef)
                            : bands.snowAmount(v)
                        if snowCover > 0 {
                            r += (0.88 - r) * snowCover
                            g += (0.90 - g) * snowCover
                            b += (0.93 - b) * snowCover
                        }

                        let iceCover = iceOn
                            ? Terrain.iceCoverage(thickness: pice[k], ref: iceRef)
                            : 0
                        if iceCover > 0 {
                            r += (0.68 - r) * iceCover
                            g += (0.81 - g) * iceCover
                            b += (0.92 - b) * iceCover
                        }

                        let saltCover = clamp01(psalt[k]) * 0.9
                        if saltCover > 0 {
                            r += (0.78 - r) * saltCover
                            g += (0.74 - g) * saltCover
                            b += (0.64 - b) * saltCover
                        }

                        // Die Makrofarbe macht die echte Sim-Lithologie bereits
                        // sichtbar. Der A-Kanal gibt dem Shader zusätzlich die
                        // Härte für Schichtkontrast, Körnung und Rauheit.
                        r -= hard * 0.065
                        g -= hard * 0.075
                        b -= hard * 0.09

                        // Die Gewichte werden hierarchisch abgeschwächt und
                        // summieren sich deshalb auf höchstens 1 — der Rest
                        // ist Grund (Shader: Trockenrasen, in der Höhe
                        // steiniger Grund). Reihenfolge: Kälte deckt alles;
                        // Fels (steil-konvex, Issue #174 D) vor Halde, Halde
                        // vor Rohboden, Rohboden vor Vegetation. Bis #174
                        // stand die Vegetation VOR dem Fels und deckte ihn
                        // auf jedem bewachsbaren Hang zu. `terrain.gdshader`
                        // mischt die Materialien als GEWICHTSSUMME und
                        // verlässt sich genau darauf; wer die Faktoren hier
                        // ändert, prüft die Summe dort mit
                        // (`MaterialTests.testWeightsNeverExceedOne`).
                        coldWeight = max(snowCover, iceCover)
                        let open = (1 - coldWeight) * (1 - saltCover)
                        // Hochlagen-Grau nur, wo nichts wächst (wie vor #174).
                        let rockShare = max(Double(prock[k]), highRock * 0.82 * (1 - vegAmount))
                        let screeShare = screeTarget(worldSlope: worldSlope, source: Double(preach[k]),
                                                     convexity: convex) * (1 - rockShare)
                        let mineral = rockShare + screeShare
                        let rawShare = rawOn
                            ? smoothstep(MaterialRender.rawDisturbLo, MaterialRender.rawDisturbHi, pdist[k])
                            : 0
                        // Bewuchs weicht erst, wenn Fels und Schutt den Standort
                        // überwiegend decken; bis dahin füllt das Mineral nur
                        // die Lücken (der Wald hängt an diesem Gewicht, #168).
                        var vegShare = vegAmount * (1 - rawShare)
                            * (1 - smoothstep(MaterialRender.vegYieldLo, MaterialRender.vegYieldHi, mineral))
                        // Mäandergürtel (#174 C2, `BarMaterial`): Altarme färben
                        // die Makrofarbe als Ried, Scroll-Rippen und alte Bögen
                        // verschieben den Bewuchs — gedeckelt auf den Bereich,
                        // den `vegAmount` selbst erreichen kann (0,78).
                        if barsOn {
                            let reed = Double(pbreed[k]) * WaterRender.oxbowReedTint * open
                            if reed > 0 {
                                r += (reedColor.r - r) * reed
                                g += (reedColor.g - g) * reed
                                b += (reedColor.b - b) * reed
                            }
                            vegShare = min(vegMax, max(0, vegShare + Double(pbveg[k])))
                        }
                        let free = 1 - vegShare
                        vegWeight = vegShare * open
                        rockWeight = rockShare * free * open
                        screeWeight = screeShare * free * open
                        rawWeight = rawShare * (1 - mineral) * free * open
                        // Küste (#174 C): steile Küste in Reichweite der
                        // Brandung wird Fels (sie räumt den Bewuchs ab), flache
                        // Küste knapp über dem Meer Sand. Beide verdrängen die
                        // Gewichte des Materialmodells (#174 D) anteilig; die
                        // Summe bleibt ≤ 1.
                        let cliffCoast = CoastMaterial.cliff(distance: pcoast[k], slope: slope)
                            * (1 - coldWeight)
                        if cliffCoast > 0 {
                            vegWeight *= 1 - cliffCoast
                            screeWeight *= 1 - cliffCoast
                            rawWeight *= 1 - cliffCoast
                            // Der Rest neben der Kälte, nicht neben 0: sonst
                            // summierten sich die Gewichte unter teilweiser
                            // Schneedeckung über 1 (Review zu #174 C).
                            rockWeight = max(rockWeight, cliffCoast
                                * max(0, (1 - coldWeight) - (vegWeight + screeWeight + rawWeight)))
                        }
                        // Sand (EIN Kanal für Strand und Bank, #174 C/C2): der
                        // stärkere gewinnt, `max(Strand, Bank)`. Frische Bank
                        // aus `BarMaterial`, Strand aus `CoastMaterial`.
                        let coastSand = CoastMaterial.sand(distance: pcoast[k], slope: slope,
                                                           height: v - sea)
                        let barSandHere = barsOn ? Double(pbsand[k]) : 0
                        sand = max(coastSand, barSandHere) * (1 - coldWeight)
                        vegWeight *= 1 - sand
                        rockWeight *= 1 - sand
                        screeWeight *= 1 - sand
                        rawWeight *= 1 - sand
                        // Die Makrofarbe folgt dem Mineral: der Shader mischt
                        // sie zu 28 % unter, sonst trüge jede Felswand den
                        // Grünstich des Habitats darunter. Im Ton des
                        // Shader-Felses (Befund #174 „Fels zu hell"): mit
                        // 0,37 hob die Beimischung allein jede Wand um ein
                        // Drittel über ihren eigenen Grauton.
                        let tint = rockWeight + screeWeight
                        r += (mineralTint.r - r) * tint
                        g += (mineralTint.g - g) * tint
                        b += (mineralTint.b - b) * tint

                        // Blankes Eis nur im Zehrgebiet (über 0 °C, dort
                        // schmilzt `updateIce`), darüber Firn. Als
                        // Anteil an der Kältedeckung, damit der Shader Eis-
                        // und Schneefarbe innerhalb von B mischt.
                        let ablation = tempOn
                            ? smoothstep(MaterialRender.firnTempLo, MaterialRender.firnTempHi, ptemp[k])
                            : 1
                        let bare = iceCover * ablation * (1 - MaterialRender.iceSnowHide * snowCover)
                        bareIce = coldWeight > 0 ? clamp01(bare / coldWeight) : 0

                        // Talboden: flach und unterhalb des Nadelwald-Bands,
                        // dazu die Aue: Bänke, die der Fluss verlassen hat
                        // (`barAge` ab dem Ende des Sand-Fensters). Die
                        // Höhenbänder allein verfehlen sie, der Gürtel liegt
                        // zu 83–97 % über `coniferLow` (Review zu #174 D,
                        // `testBarMeadowDiagnostic`).
                        let lowland = 1 - smoothstep(bands.coniferLow,
                                                     max(bands.coniferHigh, bands.coniferLow + 1e-6), v)
                        valley = (1 - smoothstep(MaterialRender.valleySlopeLo,
                                                 MaterialRender.valleySlopeHi, worldSlope))
                            * lowland * open
                        if aueOn, pbage[k] >= 0 {
                            let aue = smoothstep(WaterRender.barSandYearsLo,
                                                 WaterRender.barSandYearsHi, pbage[k])
                            valley = max(valley, aue * open)
                        }
                    }

                    // Umrechnung 0…1 → Byte nur über `byte01` (RenderSupport):
                    // ausgeschrieben klemmte sie NaN nicht weg, sondern brach ab.
                    let o = k * 4
                    pcolor[o] = byte01(r)
                    pcolor[o + 1] = byte01(g)
                    pcolor[o + 2] = byte01(b)
                    pcolor[o + 3] = byte01(sand)
                    psurface[o] = byte01(vegWeight)
                    psurface[o + 1] = byte01(rockWeight)
                    psurface[o + 2] = byte01(coldWeight)
                    psurface[o + 3] = byte01(hard * 0.5 + 0.5)
                    pcover[o] = byte01(screeWeight)
                    pcover[o + 1] = byte01(bareIce)
                    pcover[o + 2] = byte01(rawWeight)
                    pcover[o + 3] = byte01(valley)
                }
            }
        }
        }}}}}}}}}}}}}}}}}}}}

        return Buffers(colors: colors, surfaces: surfaces, covers: covers)
    }

    // Meeresgrund und unmittelbarer Ufersaum. Landmaterialien entstehen im
    // Shader aus den Gewichten; diese Rampe muss dort keine Biompalette mehr
    // vortäuschen.
    private static let stops: [(Double, Double, Double, Double)] = [
        (-0.3, 0.015, 0.04, 0.11),
        (0.00, 0.04, 0.13, 0.27),
        (0.15, 0.12, 0.28, 0.38),
        (0.17, 0.53, 0.46, 0.34),
        (0.28, 0.24, 0.42, 0.19),
    ]

    // Innerhalb der parallelen Pixelschleife aufgerufen; @inline(__always)
    // vermeidet den Call-Overhead für jeden Meeresgrund-Punkt analog zu clamp01/smoothstep.
    @inline(__always)
    static func gradColor(_ v: Double) -> (Double, Double, Double) {
        for k in 0..<(stops.count - 1) {
            if v <= stops[k + 1].0 {
                let a = stops[k], c = stops[k + 1]
                let t = clamp01((v - a.0) / (c.0 - a.0))
                return (a.1 + (c.1 - a.1) * t,
                        a.2 + (c.2 - a.2) * t,
                        a.3 + (c.3 - a.3) * t)
            }
        }
        let c = stops[stops.count - 1]
        return (c.1, c.2, c.3)
    }
}

import Foundation
import SwiftGodot
import SimCore

/// GEOMETRIE-Pfad des Wassers (Issues #31/#34, mit #53 aus `SimNode`
/// ausgelagert): Band-Geometrie entlang der Mäander-Zentrumslinien statt
/// Stempel→Raster→Render-Gitter-Doppelquantisierung. Reine Optik, NULL
/// Sim-Rückwirkung.
///
/// #31 hat die Mäander-Hauptläufe als Bänder eingeführt (hinter einem
/// A/B-Schalter), #34 macht sie zum Standard und schließt die Übergänge:
/// Mündungen laufen IN die Wasserfläche hinein statt davor zu enden,
/// Delta-Distributäre fächern über den Ablagerungskörper auf, und Altarme
/// sind Stillwasser-Bänder statt eines Raster-Overlays.
///
/// Was BEWUSST Raster bleibt (`WaterFieldRenderer`; Begründung/Messung:
/// `docs/geometry-water-measurements.md` §D):
///  - die dendritischen Zubringer UNTER der Mäander-Schwelle (Stream-Map ×
///    MFD-Abfluss): sie haben keine Zentrumslinien-Entität, aus der sich ein
///    Band bauen ließe, tragen aber den größten Teil der Talzeichnung.
///  - Seen/Meer (Gate + Per-Pixel-Uferkontur aus #32): dort ist das Raster
///    dem Band überlegen — die Kontur kommt pixelgenau aus der Wassersäule.
///  - der Nass-Saum (`shore`) um beides, inklusive des Korridor-Halos unter
///    den Bändern.
///
/// Altarm-Parameter, Band-Breiten und Enden-Taper stehen seit Issue #51
/// vollständig im Kalibrier-Vertrag `WaterRender` — GEMEINSAM mit dem
/// Raster-Pfad. Sie müssen dieselben sein: im Geometrie-Modus nimmt das
/// Wasserfeld genau die Zellen aus dem See-Kanal, die die Geometrie malt —
/// driften die Filter, entsteht entweder doppeltes Wasser oder ein Loch. Hier
/// stünden sie als Literal, das nur ein ~20-Minuten-Build prüfen könnte.
final class RiverRibbonRenderer {

    /// Zentrumslinien-Stand beim letzten Ribbon-Build (Dirty-Vertrag wie
    /// `TreeInstanceRenderer`): Knotenzahlen + Positionen, flach. Abfluss ändert
    /// sich nur zusammen mit Positionen (Migration/computeFlow) — Positionen
    /// genügen.
    private var riverSnapshot: [Double] = []
    private var rrVerts: [Vector3] = []
    private var rrCols: [Color] = []
    private var rrUVs: [Vector2] = []
    private var rrUV2s: [Vector2] = []
    private var rrIdx: [Int32] = []
    /// Vertex-Index, an dem jedes Band beginnt. Godot braucht ihn nicht (die
    /// Bänder liegen in EINER Surface), die Wächter schon: „endet jedes
    /// Fluss-Band im Wasser?" ist eine Frage über Band-ENDEN, und die aus den
    /// Puffern zu raten (Bogenlänge 0 als Startmarke) ist bei zwei
    /// zusammenfallenden Stützpunkten mehrdeutig.
    private var rrStripStarts: [Int32] = []
    /// Je Kanal-Index in `terrain.meander.channels`: hat der letzte Build für
    /// diesen Kanal ein Fluss-Band emittiert? `WaterFieldRenderer` liest das:
    /// nur unter echten Bändern stempelt er den Saum-Korridor und deckelt das
    /// D8-Raster darunter — Kanäle, die das Strahler-/Kohärenz-Gate hier
    /// verwirft, überlässt er ganz dem D8/MFD-Raster (Zubringer-Optik). Ohne
    /// diese Rückmeldung deckelte der Korridor ALLE Kanäle ab `renderMinCells`
    /// und die verworfenen (gemessen 599 von 793, 52 % der sichtbaren
    /// Zentrumslinien-Zellen, Jahr 2200/Seed 1337) rendersten als Nass-Saum
    /// OHNE Wasser darin. Die Einigkeit der beiden Pfade entsteht bewusst über
    /// das ECHTE Bau-Ergebnis statt über eine duplizierte Gate-Formel, die
    /// wegdriften könnte.
    private(set) var bandChannelFlags: [Bool] = []
    /// Auflösung des RENDER-Gitters (Main.gd `terrain_grid`, via
    /// `SimNode.setRenderGrid`): die Land-Bänder sampeln ihre Höhen über
    /// `renderSurfaceHeight` von der SICHTBAREN Oberfläche statt von den
    /// Sim-Höhen — sonst versinken sie auf Steilstrecken im gröberen Mesh
    /// (Begründung am Sampler in `RenderSupport.swift`). 0 = unbekannt =
    /// volle Auflösung (Headless-Wächter: bit-identisch zu `bilinearGrid`).
    var renderGrid = 0

    var verts: PackedVector3Array { PackedVector3Array(rrVerts) }
    var colors: PackedColorArray { PackedColorArray(rrCols) }
    var uvs: PackedVector2Array { PackedVector2Array(rrUVs) }
    var uv2s: PackedVector2Array { PackedVector2Array(rrUV2s) }
    var indices: PackedInt32Array { PackedInt32Array(rrIdx) }
    var stripStarts: PackedInt32Array { PackedInt32Array(rrStripStarts) }

    /// Stützpunkt eines Wasser-Bands in GITTER-Koordinaten (kontinuierlich).
    /// Fluss, Delta-Arm und Altarm teilen sich diese Form — sie unterscheiden
    /// sich nur in Breite, Deckkraft, Typ und darin, ob sie auf dem Gelände
    /// oder auf einer Wasserfläche liegen.
    private struct RibbonSample {
        var x: Double
        var z: Double
        /// Halbbreite in Zellen.
        var halfWidth: Double
        var alpha: Double
        /// Strahler-Rang/6 → Tiefenfarbe im Shader.
        var rank: Double
        /// Wasserspiegel (Sim-Höhe), auf dem das Band aufliegt; `nil` = das Band
        /// folgt dem GELÄNDE und jede Kante bekommt ihre eigene lokale Höhe.
        var surface: Double?
    }

    // MARK: Dirty-Vertrag

    private func flattenedChannelPositions(_ terrain: Terrain) -> [Double] {
        var flat: [Double] = []
        for ch in terrain.meander.channels {
            flat.append(Double(ch.nodes.count))
            for nd in ch.nodes { flat.append(nd.x); flat.append(nd.z) }
        }
        return flat
    }

    /// Maximale Knoten-Verschiebung (Zellen) seit `markBuilt`; bei
    /// Struktur-Änderung (Cutoff, Resample, Neu-Saat, Laden) bewusst „riesig",
    /// damit GDScript sofort rebuildet. Vor dem ersten Build ebenso.
    /// EHRLICHE ERWARTUNG: während die Sim läuft, triggert das praktisch jeden
    /// Schritt (Meander.migrate resampled unconditional → Knotenzahl ändert
    /// sich). Der Vertrag spart im Pause-/Idle-/Sculpt-Zustand (kein Schritt →
    /// Delta exakt 0 → kein Rebuild); im Zeitraffer deckelt Main.gd den Mesh-
    /// Rebuild auf 1 Hz (gemessen: 0,30 s kosteten ~4 % FPS).
    func maxDelta(_ terrain: Terrain) -> Double {
        let flat = flattenedChannelPositions(terrain)
        if flat.count != riverSnapshot.count { return 1e9 }
        var maxD = 0.0
        for i in 0..<flat.count { maxD = max(maxD, abs(flat[i] - riverSnapshot[i])) }
        return maxD
    }

    /// Setzt den Rebuild-Vergleichspunkt auf die aktuellen Zentrumslinien.
    func markBuilt(_ terrain: Terrain) { riverSnapshot = flattenedChannelPositions(terrain) }

    /// Verwirft den Vergleichspunkt (geladene Welt) → `maxDelta` meldet „riesig"
    /// und der nächste Frame baut die Bänder neu.
    func invalidateSnapshot() { riverSnapshot = [] }

    // MARK: Bau

    /// Baut die Ribbon-Geometrie aus den Mäander-Zentrumslinien: Catmull-Rom-
    /// geglättetes Band, Breite ∝ √Abfluss, Oberläufe laufen über Enden-Taper
    /// fein aus. Vertex-Vertrag (konsumiert von water.gdshader):
    ///   COLOR.rg = Fließrichtung (kodiert *0.5+0.5), COLOR.b = Strahler-Rang/6,
    ///   COLOR.a = Deckkraft (Abfluss-Rampe × Kanal-Kohärenz × Taper),
    ///   UV.x = Quer-Position 0..1 (Kanten-Feathering), UV.y = Bogenlänge (Welt).
    /// `hscale` = Render-Überhöhung, `lift` = Anhebung über Gelände (Welt-Y) —
    /// deckt den Diskretisierungs-Fehler des gröberen Render-Gitters im Talgrund.
    func build(_ terrain: Terrain, hscale: Double, lift: Double) {
        rrVerts.removeAll(keepingCapacity: true)
        rrCols.removeAll(keepingCapacity: true)
        rrUVs.removeAll(keepingCapacity: true)
        rrUV2s.removeAll(keepingCapacity: true)
        rrIdx.removeAll(keepingCapacity: true)
        rrStripStarts.removeAll(keepingCapacity: true)
        let n = terrain.cfg.n
        let cs = terrain.cfg.cellSize
        let creek = terrain.cfg.renderMinCells
        let smap = terrain.streamMap
        // Strahler-Rang (D8-Netz ab Mäander-Schwelle): Rang-Maß für die
        // Render-Hierarchie — hohe Ordnungen bleiben auch dort sichtbar, wo die
        // Abfluss-Rampe allein sie ausblenden würde. Bewusst je Build frisch:
        // computeFlow ändert receiver UND die area-Netzmaske auch ohne
        // Knoten-Cutoff; ein Cache nur nach Mäander-Struktur wäre fachlich alt.
        // Die Allokationsrate deckelt Main.gd gemeinsam für Echtzeit/_jump auf 1 Hz.
        let orders = terrain.strahlerOrders(minCells: terrain.cfg.meanderMinCells)

        let subdivisions = 3 // Samples je Knoten-Segment (Knotenabstand ~1.5 Zellen)
        bandChannelFlags = [Bool](repeating: false,
                                  count: terrain.meander.channels.count)
        for (chIndex, ch) in terrain.meander.channels.enumerated() {
            let nodes = ch.nodes
            let m = nodes.count
            if m < 2 { continue }
            // Catmull-Rom-Subdivision der Zentrumslinie; Abfluss linear je Segment.
            var px: [Double] = [], pz: [Double] = [], pq: [Double] = []
            px.reserveCapacity(m * subdivisions)
            pz.reserveCapacity(m * subdivisions)
            pq.reserveCapacity(m * subdivisions)
            for i in 0..<(m - 1) {
                let p0 = nodes[max(i - 1, 0)], p1 = nodes[i]
                let p2 = nodes[i + 1], p3 = nodes[min(i + 2, m - 1)]
                for s in 0..<subdivisions {
                    let t = Double(s) / Double(subdivisions)
                    let t2 = t * t, t3 = t2 * t
                    px.append(0.5 * (2 * p1.x + (p2.x - p0.x) * t
                        + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                        + (3 * p1.x - p0.x - 3 * p2.x + p3.x) * t3))
                    pz.append(0.5 * (2 * p1.z + (p2.z - p0.z) * t
                        + (2 * p0.z - 5 * p1.z + 4 * p2.z - p3.z) * t2
                        + (3 * p1.z - p0.z - 3 * p2.z + p3.z) * t3))
                    pq.append(ch.discharge[i] + (ch.discharge[i + 1] - ch.discharge[i]) * t)
                }
            }
            px.append(nodes[m - 1].x); pz.append(nodes[m - 1].z); pq.append(ch.discharge[m - 1])
            let cnt = px.count

            // Deckkraft: Abfluss-Rampe je Sample (fein auslaufen statt harter
            // renderMinCells-Kante) × Stream-Map-Kohärenz des ganzen Kanals
            // (verwaiste/verknäulte Linien als Einheit ausblenden) × Strahler-Boden.
            var alpha = [Double](repeating: 0, count: cnt)
            var rank = [Double](repeating: 0, count: cnt)
            var supportSum = 0.0, supportWeight = 0.0
            for a in 0..<cnt {
                let ci = min(max(Int(px[a].rounded()), 0), n - 1)
                let cj = min(max(Int(pz[a].rounded()), 0), n - 1)
                // D8 und Lagrange-Zentrumslinie liegen nicht zellgenau
                // übereinander. Ein 1-Zellen-Stützsaum verhindert, dass ein
                // Band beim Überqueren EINER Zellgrenze zwischen Ordnung 3/4
                // komplett ein-/ausblendet (räumliche Hysterese ohne Zustand).
                var localOrder: Int32 = 0
                for oj in max(0, cj - 1)...min(n - 1, cj + 1) {
                    for oi in max(0, ci - 1)...min(n - 1, ci + 1) {
                        localOrder = max(localOrder, orders[oj * n + oi])
                    }
                }
                let ord = Double(localOrder)
                rank[a] = min(ord / WaterRender.ribbonRankDivisor, 1.0)
                // Die Zentrumslinie ist kontinuierlich; die Sichtbarkeit ebenso
                // bilinear aus der Stream-Map lesen. Nearest-Cell erzeugte bei
                // Zellwechseln einzelne Alpha-Spitzen (sichtbare Dreiecksfächer).
                let stream = bilinearGrid(smap, px[a], pz[a], n: n)
                // Dasselbe Fenster wie der Korridor-Stempel: beide fragen, ob
                // dem gestempelten Bett real Wasser folgt (Issue #51).
                let mM = WaterRender.corridorMask(streamMap: stream)
                let x = min(max(pq[a] / creek, 0), 1)
                let ramp = x * x * (3 - 2 * x) // smoothstep(0, creek, q)
                var aQ = ramp
                if ord >= 3 { aQ = max(aQ, 0.5) }
                alpha[a] = aQ
                // Die Stream-Map entscheidet auf KANAL-Ebene: lokale
                // Raster-Spitzen als Alpha zu übernehmen erzeugt isolierte
                // Dreiecksfächer. Ein kohärent durchflossener Kanal bleibt
                // stattdessen als ganzes Band sichtbar, inklusive Oberlauf.
                let weight = max(ramp, 0.05)
                supportSum += mM * weight
                supportWeight += weight
            }
            // KASKADEN-Übergabe (WaterRender.cascadeWeight): an Steilstrecken
            // blendet das Band aus — dort malt das Raster, dessen Deckel im
            // Wasserfeld über DIESELBE Funktion entfällt. Ein 3D-Band verliert
            // an Kaskaden gegen das Render-Mesh (Zacken statt Lauf). Zwei
            // Pässe: lokale Neigung (±2 Samples ≈ 1 Zelle), dann MAX-Dilatation
            // ±4 Samples (~2 Zellen) — STUFENBECKEN sind selbst eben, gehören
            // aber zur Kaskade; ohne die Dilatation blieben ihre flachen
            // Band-Platten als Brocken zwischen den ausgeblendeten Abstürzen
            // stehen (Steillauf-A/B). VOR der Glättung, damit der Übergang
            // weich ausläuft.
            let hgrid = terrain.h
            let slopeWindow = 2
            var cascade = [Double](repeating: 0, count: cnt)
            for a in 0..<cnt {
                let a0 = max(0, a - slopeWindow), a1 = min(cnt - 1, a + slopeWindow)
                let dxs = (px[a1] - px[a0]) * cs, dzs = (pz[a1] - pz[a0]) * cs
                let run = (dxs * dxs + dzs * dzs).squareRoot()
                if run < 1e-9 { continue }
                let drop = bilinearGrid(hgrid, px[a0], pz[a0], n: n)
                         - bilinearGrid(hgrid, px[a1], pz[a1], n: n)
                cascade[a] = WaterRender.cascadeWeight(slope: drop / run)
            }
            let cascadeReach = 4
            for a in 0..<cnt {
                var w = 0.0
                for b in max(0, a - cascadeReach)...min(cnt - 1, a + cascadeReach) {
                    w = max(w, cascade[b])
                }
                alpha[a] *= 1 - w
            }
            let supportMean = supportSum / max(supportWeight, 1e-9)
            let supportX = min(max((supportMean - WaterRender.ribbonSupportLo)
                                   / WaterRender.ribbonSupportSpan, 0), 1)
            let channelOpacity = supportX * supportX * (3 - 2 * supportX)
            for a in 0..<cnt { alpha[a] *= channelOpacity }

            // Diskrete Strahler-Zellen können an Netz-Kreuzungen verbleibende
            // Sprünge erzeugen. Symmetrisch längs filtern: keine zeitliche
            // Verzögerung, längere aktive Reaches bleiben unverändert.
            let alphaRadius = 6 // Samples à ~0.5 Zellen → ±3 Zellen
            var prefix = [Double](repeating: 0, count: cnt + 1)
            for a in 0..<cnt { prefix[a + 1] = prefix[a] + alpha[a] }
            for a in 0..<cnt {
                let aLo = max(0, a - alphaRadius)
                let aHi = min(cnt, a + alphaRadius + 1)
                alpha[a] = (prefix[aHi] - prefix[aLo]) / Double(aHi - aLo)
            }
            // Unsichtbare Schwänze (Deckkraft ≈ 0) nicht emittieren; 2 Samples
            // Vorlauf bleiben für den weichen Einstieg.
            guard var lo = alpha.firstIndex(where: { $0 > WaterRender.ribbonMinimumAlpha }),
                  let hi = alpha.lastIndex(where: { $0 > WaterRender.ribbonMinimumAlpha })
            else { continue }
            lo = max(0, lo - 2)
            if hi - lo < 2 { continue }
            // Kartografische Hierarchie: nur Zentrumslinien, die wenigstens
            // Strahler 3 erreichen (Historie und Messung: `ribbonMinimumRank`).
            // Der feine Oberlauf DESSELBEN Bands bleibt vollständig erhalten.
            if !rank[lo...hi].contains(where: { $0 >= WaterRender.ribbonMinimumRank }) { continue }
            // Ab hier wird das Band sicher emittiert — das Wasserfeld darf den
            // Korridor dieses Kanals auf Saum-Intensität deckeln.
            bandChannelFlags[chIndex] = true

            // Bogenlängen (Welt) für Taper und UV.y.
            var arc = [Double](repeating: 0, count: cnt)
            for a in (lo + 1)...hi {
                let dx = (px[a] - px[a - 1]) * cs, dz = (pz[a] - pz[a - 1]) * cs
                arc[a] = arc[a - 1] + (dx * dx + dz * dz).squareRoot()
            }
            let total = arc[hi]

            // Stützpunkte des Laufs (Quellen-Taper über ~4 Zellen). Wo die
            // Zentrumslinie unter Wasser liegt — geflutete Senke, Mündung —
            // liegt das Band FLACH auf dem Spiegel und blendet mit der
            // Wassersäule aus (`lakeHandoverFade`).
            var samples: [RibbonSample] = []
            samples.reserveCapacity(hi - lo + 1 + WaterRender.mouthSearchCells)
            for a in lo...hi {
                let taper = min(1, arc[a] / (WaterRender.ribbonSourceTaperCells * cs))
                samples.append(RibbonSample(x: px[a], z: pz[a],
                                            halfWidth: ribbonHalfWidthCells(pq[a], cfg: terrain.cfg) * taper,
                                            alpha: alpha[a] * taper,
                                            rank: rank[a], surface: nil))
            }

            // MÜNDUNG (Issue #34): das Band lief bisher über die letzten ~2
            // Zellen auf null zusammen und endete auf der zell-gerundeten
            // Zentrumslinie — die Uferkontur des Shaders liegt aber per Pixel
            // auf der Wassersäule. Zwischen beiden blieb ein SPALT. Jetzt folgt
            // das Band dem D8-Empfänger bis IN die Wasserfläche und blendet dort
            // über `mouthOverlapCells` aus: die Überlappung schließt den Spalt,
            // die Ausblendung verhindert eine zweite Wasserfläche über dem See.
            let mouth = mouthPath(terrain, fromX: px[hi], fromZ: pz[hi])
            if mouth.isEmpty {
                // Kein Wasser in Reichweite: der Lauf versickert im Land — dort
                // bleibt der weiche Enden-Taper von #31 richtig.
                for a in samples.indices {
                    let t = min(1, (total - arc[lo + a]) / (WaterRender.ribbonTailTaperCells * cs))
                    samples[a].halfWidth *= t
                    samples[a].alpha *= t
                }
            } else {
                let mouthWidth = ribbonHalfWidthCells(pq[hi], cfg: terrain.cfg)
                let mouthAlpha = alpha[hi]
                for point in mouth {
                    samples.append(RibbonSample(x: point.x, z: point.z,
                                                halfWidth: mouthWidth,
                                                alpha: mouthAlpha,
                                                rank: rank[hi], surface: point.surface))
                }
                // Der Überlappungs-Deckel kann mitten im flachen Apron greifen
                // (dort ist die See-Übergabe noch > 0). Dann übernehmen die
                // Delta-Arme — das Band selbst läuft über die letzten 2 Zellen
                // weich aus, statt mit einer Kante zu enden.
                RiverRibbonRenderer.taperTail(&samples, cells: WaterRender.ribbonTailTaperCells)
            }

            // Wasser-Übergabe in EINEM Pass über den fertigen Lauf (die
            // Meer-Regel braucht die Strecke SEIT der Uferlinie, also die
            // Reihenfolge der Stützpunkte).
            applyWaterHandover(&samples, terrain)
            emitRibbon(samples, terrain, kind: WaterRender.ribbonKindRiver, still: false,
                       hscale: hscale, lift: lift)

            // DELTA (Issue #34): am Eintritt ins stehende Wasser fächert der Lauf
            // über den Ablagerungskörper auf, den die Sim dort aufschüttet.
            if let mouthIndex = samples.firstIndex(where: { $0.surface != nil }),
               mouthIndex > 0 {
                let entry = samples[mouthIndex], before = samples[mouthIndex - 1]
                var dx = entry.x - before.x, dz = entry.z - before.z
                let dl = (dx * dx + dz * dz).squareRoot()
                if dl > 1e-9 {
                    dx /= dl; dz /= dl
                    appendDeltaArms(terrain, mouthX: entry.x, mouthZ: entry.z, dirX: dx, dirZ: dz,
                                    halfWidth: entry.halfWidth, rank: entry.rank,
                                    hscale: hscale, lift: lift)
                }
            }
        }

        // ALTARME (Issue #34): vom Raster-Overlay in die Geometrie.
        appendOxbowRibbons(terrain, hscale: hscale, lift: lift)
    }

    // MARK: Übergabe an die Raster-Wasserflächen

    /// Blendet die letzten `cells` Zellen eines Bands auf 0 aus — gemessen in
    /// BOGENLÄNGE, nicht in Stützpunkten: die Stützpunkt-Abstände unterscheiden
    /// sich je Bandtyp (Fluss ~0.5, Delta-Arm 1 Zelle), ein fester Punkt-Zähler
    /// gäbe je nach Typ eine andere Kantenschärfe.
    private static func taperTail(_ samples: inout [RibbonSample], cells: Double) {
        guard samples.count >= 2, cells > 0 else { return }
        var distance = 0.0
        for a in stride(from: samples.count - 1, through: 0, by: -1) {
            if a < samples.count - 1 {
                let dx = samples[a + 1].x - samples[a].x
                let dz = samples[a + 1].z - samples[a].z
                distance += (dx * dx + dz * dz).squareRoot()
            }
            let t = min(1, distance / cells)
            samples[a].alpha *= t
            if t >= 1 { break }
        }
    }

    /// Deckkraft-Faktor eines Band-Stützpunkts auf einem SEE: 1 an der
    /// Uferlinie, 0 ab der Raster-See-Schwelle.
    ///
    /// Das ist die Übergabe an den See-Kanal, und sie ist bewusst eine Funktion
    /// der WASSERSÄULE statt einer Länge: das Band malt genau das Flachwasser,
    /// das der See-Kanal nicht malen darf (`rawWet` > 0.03), und ist
    /// verschwunden, wo der See-Kanal deckt. Kein Spalt (dazwischen liegt kein
    /// ungemaltes Band), keine zweite Wasserfläche (übereinander liegt keine
    /// gemalte). Gilt für den ganzen Lauf, nicht nur die Mündung — eine
    /// Zentrumslinie, die durch eine geflutete Senke zieht, hat dasselbe
    /// Problem wie eine, die in einen See mündet.
    @inline(__always)
    private static func lakeHandoverFade(pond: Double) -> Double {
        1 - smoothstep(WaterRender.pondContourLo, WaterRender.deltaFrontDepth, pond)
    }

    /// Dasselbe fürs MEER — und dort nach der STRECKE seit der Uferlinie.
    ///
    /// Grund: das Meer ist keine Feld-Fläche, sondern eine eigene Wasser-EBENE
    /// über der ganzen Karte (`water_mi` in Main.gd). Sie deckt ab der ersten
    /// Zelle unter `sea` vollständig — eine Tiefen-Rampe wie am See hätte hier
    /// also nichts zu überbrücken, das Band lief nur als Platte weiter ins Meer
    /// hinein (im A/B-Screenshot als heller Rechteck-Ausleger sichtbar). Die
    /// kurze Überlappung schließt den Diskretisierungs-Spalt zur Uferlinie und
    /// endet dann.
    @inline(__always)
    private static func seaHandoverFade(submergedCells: Double) -> Double {
        1 - smoothstep(0, WaterRender.mouthOverlapCells, submergedCells)
    }

    /// Legt jeden Stützpunkt, der unter Wasser liegt, auf dessen Spiegel und
    /// blendet ihn nach der Regel des jeweiligen Gewässers aus. Läuft ÜBER die
    /// Reihenfolge (die Meer-Regel braucht die Strecke seit der Uferlinie);
    /// beim Zurückkommen an Land beginnt sie neu — ein Lauf, der eine Pfütze
    /// quert, soll dahinter wieder voll sichtbar sein.
    private func applyWaterHandover(_ samples: inout [RibbonSample], _ terrain: Terrain) {
        let n = terrain.cfg.n
        let h = terrain.h, wl = terrain.waterLevel
        let sea = terrain.cfg.sea
        var submergedCells = 0.0
        for a in samples.indices {
            let ci = min(max(Int(samples[a].x.rounded()), 0), n - 1)
            let cj = min(max(Int(samples[a].z.rounded()), 0), n - 1)
            let k = cj * n + ci
            guard let surface = openWaterSurface(k, h: h, wl: wl, sea: sea) else {
                submergedCells = 0
                // Über TROCKENEM Boden folgt das Band dem Gelände — auch dann,
                // wenn der Stützpunkt schon einen Spiegel MITBRINGT: die
                // Mündungs-Kette (`mouthPath`) liest ihre Spiegel an den
                // ZELLZENTREN der D8-Kette und glättet die Punkte danach über
                // ihre Nachbarn. Ein geglätteter Punkt kann dadurch in der
                // Nachbarzelle landen, und liegt die trocken, schwebte das Band
                // dort auf dem Spiegel der Zelle nebenan (gemessen auf dem
                // CI-Runner: 3,5 Welt-Einheiten über dem Boden, Issue #61).
                // Es entscheidet die EIGENE Zelle des Stützpunkts.
                samples[a].surface = nil
                continue
            }
            if a > 0 {
                let dx = samples[a].x - samples[a - 1].x, dz = samples[a].z - samples[a - 1].z
                submergedCells += (dx * dx + dz * dz).squareRoot()
            }
            samples[a].surface = surface
            samples[a].alpha *= surface <= sea
                ? RiverRibbonRenderer.seaHandoverFade(submergedCells: submergedCells)
                : RiverRibbonRenderer.lakeHandoverFade(pond: surface - h[k])
        }
    }

    // MARK: Band-Emission

    /// Hängt ein Band aus `samples` an die Ribbon-Puffer an (Dreiecksstreifen aus
    /// Kantenpaaren). `still` = Altarm: die Fließrichtung wird als 0 kodiert,
    /// woran der Shader Stillwasser erkennt (kein Strömungs-Schimmer).
    private func emitRibbon(_ samples: [RibbonSample], _ terrain: Terrain,
                            kind: Double, still: Bool,
                            hscale: Double, lift: Double) {
        guard samples.count >= 2 else { return }
        let n = terrain.cfg.n
        let cs = terrain.cfg.cellSize
        let half = terrain.cfg.world / 2
        let h = terrain.h
        // Bogenlänge (Welt) für UV.y — im Shader die Phase der Wellen/Strömung.
        var arc = [Double](repeating: 0, count: samples.count)
        for a in 1..<samples.count {
            let dx = (samples[a].x - samples[a - 1].x) * cs
            let dz = (samples[a].z - samples[a - 1].z) * cs
            arc[a] = arc[a - 1] + (dx * dx + dz * dz).squareRoot()
        }
        let base = rrVerts.count
        rrStripStarts.append(Int32(base))
        for a in 0..<samples.count {
            let s = samples[a]
            let a0 = max(0, a - 1), a1 = min(samples.count - 1, a + 1)
            var tx = samples[a1].x - samples[a0].x, tz = samples[a1].z - samples[a0].z
            let tl = (tx * tx + tz * tz).squareRoot()
            if tl > 1e-9 { tx /= tl; tz /= tl }
            let hw = max(s.halfWidth, 0) * cs
            let wx = s.x * cs - half, wz = s.z * cs - half
            let perpx = -tz * hw, perpz = tx * hw
            let yLeft: Float, yRight: Float
            if let surface = s.surface {
                // Auf Wasser liegt das Band FLACH auf dem Spiegel — beide Kanten
                // auf derselben Höhe, sonst kippte es am Ufer aus der Fläche.
                // NICHT mit `lift`: der deckt den Chord-Fehler des gröberen
                // RENDER-Gitters im Talgrund ab; über einer Wasserfläche hob er
                // das Band sichtbar aus ihr heraus (Mündung als schwebende
                // Platte über dem Meer, im A/B-Screenshot gefunden).
                // Meer: die eigene Wasser-EBENE liegt exakt auf `sea` — das Band
                // gehört DARUNTER, dann liest es sich als Trübung im Wasser
                // statt als Fläche darauf. See: der Terrain-Shader hebt seine
                // Fläche erst ab `geometryLiftLo`, im Apron liegt das Terrain
                // also unter dem Spiegel; ein Hauch Abstand hält das Band frei.
                let onSea = surface <= terrain.cfg.sea + 1e-9
                let y = Float(surface * hscale + (onSea ? WaterRender.ribbonSeaSurfaceSink
                                                        : WaterRender.ribbonLakeSurfaceLift))
                yLeft = y; yRight = y
            } else {
                // Auf Land folgt jede Kante ihrer EIGENEN lokalen Höhe. Eine
                // gemeinsame Zentrumslinien-Höhe schneidet das Band an
                // Quergefällen ins Terrain (nur radiale Fragmente sichtbar).
                // Aber nur bis zur maximalen QUER-Neigung um die Zentrums-Höhe
                // (`WaterRender.ribbonMaxCrossSlope`): ist das Band breiter als
                // die Schluchtsohle, liegt die Kante auf der WAND — ungeklemmt
                // drapierte sich das Band die Wände hoch (große blaue Platten
                // an Steilwänden). Die geklemmte Kante taucht in den Fels ein;
                // sichtbar bleibt genau die Sohlenbreite.
                let edgeGX = perpx / cs, edgeGZ = perpz / cs
                let yCenter = renderSurfaceHeight(h, s.x, s.z, n: n,
                                                  renderGrid: renderGrid) * hscale
                let crossTol = hw * WaterRender.ribbonMaxCrossSlope
                let yL = renderSurfaceHeight(h, s.x - edgeGX, s.z - edgeGZ, n: n,
                                             renderGrid: renderGrid) * hscale
                let yR = renderSurfaceHeight(h, s.x + edgeGX, s.z + edgeGZ, n: n,
                                             renderGrid: renderGrid) * hscale
                yLeft = Float(min(max(yL, yCenter - crossTol), yCenter + crossTol) + lift)
                yRight = Float(min(max(yR, yCenter - crossTol), yCenter + crossTol) + lift)
            }
            rrVerts.append(Vector3(x: Float(wx - perpx), y: yLeft, z: Float(wz - perpz)))
            rrVerts.append(Vector3(x: Float(wx + perpx), y: yRight, z: Float(wz + perpz)))
            let dirX = still ? 0.0 : tx, dirZ = still ? 0.0 : tz
            let col = Color(r: Float(dirX * 0.5 + 0.5), g: Float(dirZ * 0.5 + 0.5),
                            b: Float(min(max(s.rank, 0), 1)),
                            a: Float(min(max(s.alpha, 0), 1)))
            rrCols.append(col); rrCols.append(col)
            rrUVs.append(Vector2(x: 0, y: Float(arc[a])))
            rrUVs.append(Vector2(x: 1, y: Float(arc[a])))
            let kindUV = Vector2(x: Float(kind), y: 0)
            rrUV2s.append(kindUV); rrUV2s.append(kindUV)
            if a > 0 {
                let v = Int32(base + (a - 1) * 2)
                rrIdx.append(v); rrIdx.append(v + 2); rrIdx.append(v + 1)
                rrIdx.append(v + 1); rrIdx.append(v + 2); rrIdx.append(v + 3)
            }
        }
    }

    /// Delta-Fächer an einer Mündung: bis zu drei Distributär-Arme über den
    /// Apron — die Zone zwischen Uferlinie und `WaterRender.deltaFrontDepth`,
    /// also genau das Flachwasser, das der Raster-See-Kanal nicht malt. Ein Arm
    /// endet an der Delta-FRONT (dort übernimmt die Seefläche) oder am Rand des
    /// Wassers; zu kurze Arme (Steilufer ohne Ablagerungskörper) fallen weg.
    ///
    /// Die Arme laufen bewusst GERADE aus der Mündungsrichtung heraus: ihre
    /// Länge — und damit die Form des Fächers — kommt aus dem Ablagerungskörper,
    /// nicht aus einer erfundenen Kurve.
    private func appendDeltaArms(_ terrain: Terrain,
                                 mouthX: Double, mouthZ: Double, dirX: Double, dirZ: Double,
                                 halfWidth: Double, rank: Double,
                                 hscale: Double, lift: Double) {
        let n = terrain.cfg.n
        let h = terrain.h, wl = terrain.waterLevel
        let sea = terrain.cfg.sea
        let spread = WaterRender.deltaArmSpread
        let maxCells = WaterRender.deltaMaxArmCells
        for angle in [-spread, 0.0, spread] {
            let ca = cos(angle), sa = sin(angle)
            let ax = dirX * ca - dirZ * sa, az = dirX * sa + dirZ * ca
            var samples: [RibbonSample] = []
            var reachedFront = false
            var onSea = false
            for stepIndex in 0...maxCells {
                let t = Double(stepIndex)
                let x = mouthX + ax * t, z = mouthZ + az * t
                let ci = Int(x.rounded()), cj = Int(z.rounded())
                if ci < 0 || cj < 0 || ci >= n || cj >= n { break }
                let k = cj * n + ci
                guard let surface = openWaterSurface(k, h: h, wl: wl, sea: sea) else { break }
                if surface <= sea { onSea = true }
                if surface - h[k] >= WaterRender.deltaFrontDepth { reachedFront = true; break }
                let f = t / Double(maxCells)
                // Ein Delta-Arm ist BREITER als der Lauf, aus dem er kommt: der
                // Strom verliert an der Mündung seine Tiefe, nicht sein Wasser.
                // Ein Mindestmaß hält den Fächer als Fläche lesbar — mit der
                // reinen Lauf-Breite wurden aus schmalen Mündungen drei
                // nadeldünne Strahlen (A/B-Screenshot).
                let armWidth = max(halfWidth, WaterRender.deltaArmMinHalfWidthCells)
                samples.append(RibbonSample(x: x, z: z,
                                            halfWidth: armWidth * (WaterRender.deltaArmWidthAtMouth
                                                - WaterRender.deltaArmWidthTaper * f),
                                            alpha: WaterRender.deltaArmOpacity * (1 - f * f),
                                            rank: rank * WaterRender.deltaArmRankFactor,
                                            surface: surface))
            }
            if samples.count < WaterRender.deltaMinArmCells { continue }
            // Der Fächer muss an SICHTBARES Wasser anschließen: entweder an die
            // Delta-Front (dahinter malt der See-Kanal) oder ans Meer. Ein Apron,
            // der einfach trocken ausläuft, ist eine überschwemmte Ebene — dort
            // malt das Raster bewusst nichts, und die Geometrie darf es nicht
            // hintenherum doch tun.
            if !reachedFront && !onSea { continue }
            // Weich in die Wasserfläche auslaufen (letzte 2 Zellen).
            RiverRibbonRenderer.taperTail(&samples, cells: WaterRender.ribbonTailTaperCells)
            emitRibbon(samples, terrain, kind: WaterRender.ribbonKindDelta, still: false,
                       hscale: hscale, lift: lift)
        }
    }

    /// Altarm-Bänder (Issue #34): abgeschnürte Schleifen als STILLWASSER-
    /// Geometrie statt als Raster-Overlay im See-Kanal. Filter, Trimmung und
    /// Alters-Fade sind dieselben wie im Stempel-Pfad (gemeinsame Konstanten) —
    /// das Wasserfeld nimmt im Geometrie-Modus genau diese Zellen aus `rawWet`,
    /// also müssen beide Seiten dieselben Schleifen meinen.
    ///
    /// Die Verlandung braucht keinen eigenen Mechanismus: ein Stützpunkt ohne
    /// Wassersäule bekommt Deckkraft 0. Füllt die Sim den Bogen zu, verschwindet
    /// er von selbst — zuerst an den seichten Enden.
    private func appendOxbowRibbons(_ terrain: Terrain, hscale: Double, lift: Double) {
        let n = terrain.cfg.n
        let h = terrain.h, wl = terrain.waterLevel
        let sea = terrain.cfg.sea
        for index in terrain.meander.oxbows.indices {
            let oxbow = terrain.meander.oxbows[index]
            if oxbow.count < WaterRender.oxbowMinimumNodes { continue }
            let age = index < terrain.meander.oxbowAge.count
                ? terrain.meander.oxbowAge[index] : 0
            let fade = max(0, 1 - age / terrain.cfg.oxbowMaxAge)
            if fade <= 0 { continue }
            let trim = min(WaterRender.oxbowMaximumTrimmedNodes, max(1, oxbow.count / 8))
            let first = trim, last = oxbow.count - trim - 1
            if last - first < 2 { continue }
            var samples: [RibbonSample] = []
            samples.reserveCapacity(last - first + 1)
            for nodeIndex in first...last {
                let node = oxbow[nodeIndex]
                let ci = min(max(Int(node.x.rounded()), 0), n - 1)
                let cj = min(max(Int(node.z.rounded()), 0), n - 1)
                let k = cj * n + ci
                let edgeSteps = min(nodeIndex - first, last - nodeIndex)
                let endFade = min(1, Double(edgeSteps + 1) / WaterRender.oxbowEndFadeSteps)
                var alpha = 0.0
                // Ohne offenes Seewasser in der EIGENEN Zelle liegt der
                // Stützpunkt auf dem Gelände (`nil`) statt auf `waterLevel`:
                // dort ist er ohnehin unsichtbar (Deckkraft 0), und
                // `waterLevel` ist auf trockenem Boden nur der nachlaufende
                // Darstellungsspiegel — unter der Meereshöhe hätte er das Band
                // sogar unter die Meeresebene gelegt. Dieselbe Regel wie im
                // Fluss-Band (s. `applyWaterHandover`, Issue #61).
                var surface: Double? = nil
                if let s = openWaterSurface(k, h: h, wl: wl, sea: sea), s > sea {
                    surface = s
                    // Dieselbe Übergabe wie beim Fluss-Band: sobald die
                    // Wassersäule den See-Kanal erreicht, malt das Raster —
                    // ohne diesen Faktor lagen dunkle Altarm-Haken ÜBER der
                    // Seefläche, wenn ein alter Bogen unter einem See liegt
                    // (gemessen: Seed 1337, Jahr 20.000, sichtbar im A/B).
                    alpha = WaterRender.oxbowMaximumOpacity * fade * endFade
                        * RiverRibbonRenderer.lakeHandoverFade(pond: s - h[k])
                }
                samples.append(RibbonSample(x: node.x, z: node.z,
                                            halfWidth: WaterRender.oxbowHalfWidthCells,
                                            alpha: alpha, rank: 0, surface: surface))
            }
            if !samples.contains(where: { $0.alpha > WaterRender.ribbonMinimumAlpha }) { continue }
            emitRibbon(samples, terrain, kind: WaterRender.ribbonKindOxbow, still: true,
                       hscale: hscale, lift: lift)
        }
    }
}

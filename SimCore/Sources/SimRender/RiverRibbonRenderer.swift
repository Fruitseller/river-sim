import Foundation
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
/// driften die Filter, entsteht entweder doppeltes Wasser oder ein Loch.
public struct RibbonMesh: Equatable {
    public var vertices: [SIMD3<Float>]
    public var colors: [SIMD4<Float>]
    public var uvs: [SIMD2<Float>]
    public var uv2s: [SIMD2<Float>]
    public var indices: [Int32]
    public var stripStarts: [Int32]
    /// Je Kanal-Index: hat der Build tatsächlich ein Band emittiert?
    public var bandChannelFlags: [Bool]
    /// Je Rasterzelle die vom gebauten Band gemalte Deckkraft.
    public var bandCoverage: [Double]

    public init(vertices: [SIMD3<Float>] = [], colors: [SIMD4<Float>] = [],
                uvs: [SIMD2<Float>] = [], uv2s: [SIMD2<Float>] = [],
                indices: [Int32] = [], stripStarts: [Int32] = [],
                bandChannelFlags: [Bool] = [], bandCoverage: [Double] = []) {
        self.vertices = vertices
        self.colors = colors
        self.uvs = uvs
        self.uv2s = uv2s
        self.indices = indices
        self.stripStarts = stripStarts
        self.bandChannelFlags = bandChannelFlags
        self.bandCoverage = bandCoverage
    }
}

public final class RiverRibbonRenderer {
    public init() {}

    /// Zentrumslinien-Stand beim letzten Ribbon-Build (Dirty-Vertrag):
    /// Knotenzahlen + Positionen, flach. Abfluss ändert
    /// sich nur zusammen mit Positionen (Migration/computeFlow) — Positionen
    /// genügen.
    ///
    /// `nil` heißt „kein Vergleichspunkt" und ist bewusst NICHT das leere Array:
    /// eine Welt OHNE Zentrumslinien flacht ebenfalls auf `[]` ab. Mit dem
    /// leeren Array als Sentinel meldete `maxDelta` nach einem Weltwechsel auf
    /// genau so eine Welt „0 = unverändert", und der Rebuild blieb aus — auf dem
    /// Schirm standen die Bänder der VORIGEN Welt weiter, und `bandCoverage`
    /// deckelte das Raster-Wasserfeld entlang ihrer Korridore (Löcher im Feld,
    /// s. `WaterFieldRenderer`).
    private var riverSnapshot: [Double]?
    /// Letztes Bau-Ergebnis als godot-freie POD-Puffer. `stripStarts` markiert
    /// den Vertex-Index jedes Bands; damit prüfen die Wächter Band-Enden direkt,
    /// ohne sie aus mehrdeutigen UV-Werten herzuleiten.
    public private(set) var mesh = RibbonMesh()
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
    public var bandChannelFlags: [Bool] { mesh.bandChannelFlags }

    /// Je Zelle: wie stark deckt die gebaute Band-Geometrie sie WIRKLICH ab
    /// (0 = gar nicht, 1 = volle Deckkraft)? Gegenstück zu `bandChannelFlags`
    /// eine Ebene feiner — und aus demselben Grund: das Raster-Feld muss sein
    /// Wasser genau dort und genau so weit zurücknehmen, wie das Band es
    /// ersetzt.
    ///
    /// Vorher war der Deckel BINÄR je Korridor-Zelle. Ein Band deckt aber über
    /// seine Länge sehr unterschiedlich: Enden-Taper, Abfluss-Rampe,
    /// Stream-Map-Kohärenz und die Kaskaden-Übergabe ziehen sein Alpha bis auf
    /// 0. Der binäre Deckel nahm dem Raster trotzdem das volle Wasser weg —
    /// GEMESSEN (Seed 1337, Jahr 20 000): 94 469 gedeckelte Korridor-Zellen
    /// gegen 10 307 Zellen, die als Fluss übrig blieben. Sichtbar war das als
    /// abreißende Läufe („keine durchgehenden Adern"): erst Band, dann eine
    /// trockene Rinne, wo weder Band noch Raster malte.
    public var bandCoverage: [Double] { mesh.bandCoverage }
    /// Auflösung des RENDER-Gitters (Main.gd `terrain_grid`, via
    /// `SimNode.setRenderGrid`): die Land-Bänder sampeln ihre Höhen über
    /// `renderSurfaceHeight` von der SICHTBAREN Oberfläche statt von den
    /// Sim-Höhen — sonst versinken sie auf Steilstrecken im gröberen Mesh
    /// (Begründung am Sampler in `RenderSupport.swift`). 0 = unbekannt =
    /// volle Auflösung (Headless-Wächter: bit-identisch zu `bilinearGrid`).
    public var renderGrid = 0
    /// Mess-Schalter für `fadeUphill` (nur Diagnose: `RiverUphill.swift`
    /// misst die Rohhöhen der Bänder ohne das Sicherheitsnetz).
    var fadesUphill = true

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
        /// Signierte Bogenstärke (−1 … +1, `MeanderState.bendStrength`) → UV2.y:
        /// Tiefenfarbe nach Querprofil. 0 = symmetrisch (Delta-Arm, Altarm).
        var bend: Double = 0
        /// Stück einer Meeresmündung jenseits der Wasserlinie: liegt wie die
        /// Delta-Arme unter der Ozean-Ebene, nicht auf Gelände + `lift`.
        var seaMouth = false
    }

    // MARK: Dirty-Vertrag

    private func flattenedChannelPositions(_ terrain: Terrain) -> [Double] {
        let totalCount = terrain.meander.channels.reduce(0) { $0 + 1 + $1.nodes.count * 2 }
        var flat: [Double] = []
        flat.reserveCapacity(totalCount)
        for ch in terrain.meander.channels {
            flat.append(Double(ch.nodes.count))
            for nd in ch.nodes { flat.append(nd.x); flat.append(nd.z) }
        }
        return flat
    }

    /// Maximale Knoten-Verschiebung (Zellen) seit `markBuilt`; bei
    /// Struktur-Änderung (Cutoff, Resample, Neu-Saat, Laden) bewusst „riesig"
    /// (`rebuildSentinel`), damit GDScript sofort rebuildet. Vor dem ersten
    /// Build ebenso, und bei nicht-endlicher Differenz (NaN in Knoten oder
    /// Snapshot): `max(maxD, NaN)` liefert `maxD` und verschluckte sie sonst.
    /// Bleiben Koordinaten nicht-endlich, bleibt der Zustand dirty.
    /// EHRLICHE ERWARTUNG: während die Sim läuft, triggert das praktisch jeden
    /// Schritt (Meander.migrate resampled unconditional → Knotenzahl ändert
    /// sich). Der Vertrag spart im Pause-/Idle-/Sculpt-Zustand (kein Schritt →
    /// Delta exakt 0 → kein Rebuild); im Zeitraffer deckelt Main.gd den Mesh-
    /// Rebuild auf 1 Hz (gemessen: 0,30 s kosteten ~4 % FPS).
    ///
    /// Vergleicht die Zentrumslinien direkt gegen den Snapshot ohne
    /// Zwischen-Allokation eines flachen Arrays.
    public func maxDelta(_ terrain: Terrain) -> Double {
        guard let snapshot = riverSnapshot else { return Self.rebuildSentinel }
        var idx = 0
        var maxD = 0.0
        for ch in terrain.meander.channels {
            let count = ch.nodes.count
            guard idx < snapshot.count else { return Self.rebuildSentinel }
            if snapshot[idx] != Double(count) { return Self.rebuildSentinel }
            idx += 1
            guard idx + count * 2 <= snapshot.count else { return Self.rebuildSentinel }
            for nd in ch.nodes {
                let dx = abs(nd.x - snapshot[idx])
                let dz = abs(nd.z - snapshot[idx + 1])
                guard dx.isFinite && dz.isFinite else { return Self.rebuildSentinel }
                maxD = max(maxD, max(dx, dz))
                idx += 2
            }
        }
        guard idx == snapshot.count else { return Self.rebuildSentinel }
        return maxD
    }

    /// „Riesiges" `maxDelta`: weit über den Rebuild-Schwellen in `Main.gd`.
    static let rebuildSentinel = 1e9

    /// Setzt den Rebuild-Vergleichspunkt auf die aktuellen Zentrumslinien.
    public func markBuilt(_ terrain: Terrain) { riverSnapshot = flattenedChannelPositions(terrain) }

    /// Verwirft den Vergleichspunkt (geladene Welt) → `maxDelta` meldet „riesig"
    /// und der nächste Frame baut die Bänder neu.
    public func invalidateSnapshot() { riverSnapshot = nil }

    // MARK: Bau

    /// Baut die Ribbon-Geometrie aus den Mäander-Zentrumslinien: Catmull-Rom-
    /// geglättetes Band, Breite ∝ √Abfluss, Oberläufe laufen über Enden-Taper
    /// fein aus. Vertex-Vertrag (konsumiert von water.gdshader):
    ///   COLOR.rg = Fließrichtung (kodiert *0.5+0.5), COLOR.b = Strahler-Rang/6,
    ///   COLOR.a = Deckkraft (Abfluss-Rampe × Kanal-Kohärenz × Taper),
    ///   UV.x = Quer-Position 0..1 (Kanten-Feathering), UV.y = Bogenlänge (Welt),
    ///   UV2.x = Band-Typ (`WaterRender.ribbonKind*`: Fluss, Delta-Arm, Altarm),
    ///   UV2.y = signierte Bogenstärke −1 … +1 (Querprofil, Prallhang tief;
    ///   0 auf Delta- und Altarmen).
    /// `hscale` = Render-Überhöhung, `lift` = Anhebung über Gelände (Welt-Y) —
    /// deckt den Diskretisierungs-Fehler des gröberen Render-Gitters im Talgrund.
    @discardableResult
    public func build(_ terrain: Terrain, hscale: Double, lift: Double) -> RibbonMesh {
        mesh.vertices.removeAll(keepingCapacity: true)
        mesh.colors.removeAll(keepingCapacity: true)
        mesh.uvs.removeAll(keepingCapacity: true)
        mesh.uv2s.removeAll(keepingCapacity: true)
        mesh.indices.removeAll(keepingCapacity: true)
        mesh.stripStarts.removeAll(keepingCapacity: true)
        let n = terrain.cfg.n
        mesh.bandChannelFlags = [Bool](repeating: false,
                                       count: terrain.meander.channels.count)
        let cnt = n * n
        // Bei leerem Terrain oder fehlerhaften Puffergrößen defensiv abbrechen, um
        // Out-of-Bounds-Zugriffe im Rendernetz und Traps auf 0-zähligen Pufferzeigern
        // sicher auszuschließen (vgl. #122).
        guard n > 0, terrain.h.count == cnt,
              terrain.waterLevel.count == cnt,
              terrain.streamMap.count == cnt else {
            mesh.bandCoverage = []
            return mesh
        }
        if mesh.bandCoverage.count != cnt {
            mesh.bandCoverage = [Double](repeating: 0, count: cnt)
        } else {
            mesh.bandCoverage.withUnsafeMutableBufferPointer {
                // Defensiver Guard statt Force-Unwrap/assertionFailure: Ein harter Trap
                // mitten im Frame ist im GDExtension-Render-Pfad unakzeptabel (vgl. #122).
                guard let base = $0.baseAddress else { return }
                base.update(repeating: 0, count: cnt)
            }
        }
        let cs = terrain.cfg.cellSize
        // cellSize 0 (keine definierte Schrittweite): kein Band ohne Schrittweite,
        // spart Catmull-Rom- und Stützpunkt-Interpolation mit NaN-Offsets ein.
        guard cs > 0, cs.isFinite else { return mesh }
        let creek = terrain.cfg.renderMinCells
        let smap = terrain.streamMap
        // Strahler-Rang (D8-Netz ab Mäander-Schwelle): Rang-Maß für die
        // Render-Hierarchie — hohe Ordnungen bleiben auch dort sichtbar, wo die
        // Abfluss-Rampe allein sie ausblenden würde. Bewusst je Build frisch:
        // computeFlow ändert receiver UND die area-Netzmaske auch ohne
        // Knoten-Cutoff; ein Cache nur nach Mäander-Struktur wäre fachlich alt.
        // Die Allokationsrate deckelt Main.gd gemeinsam für Echtzeit/_jump auf 1 Hz.
        let orders = terrain.strahlerOrders(minCells: terrain.cfg.meanderMinCells)
        guard orders.count == cnt else {
            mesh.bandCoverage = []
            return mesh
        }

        let subdivisions = 3 // Samples je Knoten-Segment (Knotenabstand ~1.5 Zellen)
        // Große Läufe ZUERST: jedes Band blendet dort aus, wo ein früheres
        // schon deckt (`emitRibbon`). In Abfluss-Reihenfolge endet so der
        // Zubringer am Hauptlauf statt umgekehrt, und Stummel-Kanäle auf
        // demselben Bett verschwinden unter dem Lauf, den sie doppeln.
        // Gleichstand nach Index: der Bau bleibt deterministisch.
        let channels = terrain.meander.channels
        let peak = channels.map { $0.discharge.max() ?? 0 }
        let order = channels.indices.sorted {
            peak[$0] != peak[$1] ? peak[$0] > peak[$1] : $0 < $1
        }
        // Mündungen, an denen schon ein Delta-Fächer steht (s. unten).
        var fanMouths: [(x: Double, z: Double)] = []
        for chIndex in order {
            let ch = channels[chIndex]
            let nodes = ch.nodes
            let m = nodes.count
            if m < 2 { continue }
            // Kanäle mit unvollständigem/nicht-endlichem Abfluss oder extremen Koordinaten
            // überspringen, um OOB-Traps und Double-to-Int-Konvertierungsfehler zu verhindern.
            guard ch.discharge.count >= m else { continue }
            guard !nodes.contains(where: {
                !$0.x.isFinite || !$0.z.isFinite || abs($0.x) > 1e9 || abs($0.z) > 1e9
            }) else { continue }
            guard !ch.discharge.prefix(m).contains(where: { !$0.isFinite || abs($0) > 1e9 }) else { continue }
            // Bogenstärke je Knoten aus der Gürtel-Geometrie der Sim (dieselbe
            // Größe, mit der `beltStamp` den Kolk nach außen legt).
            let hgridBend = terrain.h
            let nodeBend = MeanderState.bendStrength(ch, config: terrain.cfg,
                                                     heightAt: { bilinearGrid(hgridBend, $0.x, $0.z, n: n) })
            // Catmull-Rom-Subdivision der Zentrumslinie; Abfluss linear je Segment.
            var px: [Double] = [], pz: [Double] = [], pq: [Double] = [], pb: [Double] = []
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
                    pb.append(nodeBend[i] + (nodeBend[i + 1] - nodeBend[i]) * t)
                }
            }
            px.append(nodes[m - 1].x); pz.append(nodes[m - 1].z); pq.append(ch.discharge[m - 1])
            pb.append(nodeBend[m - 1])
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
                rank[a] = clamp01(ord / WaterRender.ribbonRankDivisor)
                // Die Zentrumslinie ist kontinuierlich; die Sichtbarkeit ebenso
                // bilinear aus der Stream-Map lesen. Nearest-Cell erzeugte bei
                // Zellwechseln einzelne Alpha-Spitzen (sichtbare Dreiecksfächer).
                let stream = bilinearGrid(smap, px[a], pz[a], n: n)
                // Dasselbe Fenster wie der Korridor-Stempel: beide fragen, ob
                // dem gestempelten Bett real Wasser folgt (Issue #51).
                let mM = WaterRender.corridorMask(streamMap: stream)
                let ramp = smoothstep(0, creek, pq[a])
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
            let channelOpacity = smoothstep(0, 1, (supportMean - WaterRender.ribbonSupportLo)
                                                  / WaterRender.ribbonSupportSpan)
            // Abfluss-Vertrauen (Issue #174 C2): ein großer Lauf bleibt sichtbar,
            // auch wenn die Stream-Map ihn nicht trackt — je Stützpunkt, damit
            // sein feiner Oberlauf weiter an der Stütze hängt.
            // Den Strahler-Rang (unten) braucht auch ein vertrauter Lauf.
            for a in 0..<cnt {
                alpha[a] *= max(channelOpacity,
                                WaterRender.ribbonTrust(dischargeCells: pq[a], referenceCells: creek))
            }

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
                  var hi = alpha.lastIndex(where: { $0 > WaterRender.ribbonMinimumAlpha })
            else { continue }
            lo = max(0, lo - 2)
            if hi - lo < 2 { continue }
            // Kartografische Hierarchie: nur Zentrumslinien, die wenigstens
            // Strahler 3 erreichen (Historie und Messung: `ribbonMinimumRank`).
            // Der feine Oberlauf DESSELBEN Bands bleibt vollständig erhalten.
            if !rank[lo...hi].contains(where: { $0 >= WaterRender.ribbonMinimumRank }) { continue }
            // Für die Tiefenfarbe fällt der Rang stromab nie: die Strahler-
            // Ordnung eines Laufs wächst nur an Zusammenflüssen. Der 3×3-
            // Stützsaum oben überbrückt nur einen Zellversatz zwischen
            // D8-Netz und Zentrumslinie; driftet die Linie weiter weg, fiel
            // EIN Stützpunkt auf Rang 0 (oder ein Stück auf Ordnung 2), und
            // der Shader malte über die volle Bandbreite einen hellen Quer-
            // strich bzw. Block („Leitersprosse", Seed 1337 / Jahr 230.000:
            // 0.667 → 0 → 0.667 an einem einzigen Stützpunkt). Die Stützpunkte
            // laufen von der Quelle zur Mündung, das laufende Maximum folgt
            // also der Fließrichtung; Gate und `river_ribbons.gd` lesen das
            // Maximum des Bands, das bleibt unverändert.
            for a in 1..<cnt { rank[a] = max(rank[a], rank[a - 1]) }
            // Ab hier wird das Band sicher emittiert — das Wasserfeld darf den
            // Korridor dieses Kanals auf Saum-Intensität deckeln.
            mesh.bandChannelFlags[chIndex] = true

            // Bogenlängen (Welt) für Taper und UV.y.
            var arc = [Double](repeating: 0, count: cnt)
            for a in (lo + 1)...hi {
                let dx = (px[a] - px[a - 1]) * cs, dz = (pz[a] - pz[a - 1]) * cs
                arc[a] = arc[a - 1] + (dx * dx + dz * dz).squareRoot()
            }


            // Stützpunkte des Laufs (Quellen-Taper über ~4 Zellen, bei einem
            // breit beginnenden Lauf über `ribbonLandTaperHalfWidths`
            // Halbbreiten). Wo die Zentrumslinie unter Wasser liegt —
            // geflutete Senke, Mündung — liegt das Band FLACH auf dem Spiegel
            // und blendet mit der Wassersäule aus (`lakeHandoverFade`).
            var samples: [RibbonSample] = []
            samples.reserveCapacity(hi - lo + 1 + WaterRender.mouthSearchCells)
            let sourceTaperCells = max(WaterRender.ribbonSourceTaperCells,
                                       WaterRender.ribbonLandTaperHalfWidths
                                       * ribbonHalfWidthCells(pq[lo], cfg: terrain.cfg))
            for a in lo...hi {
                let taper = clamp01(arc[a] / (sourceTaperCells * cs))
                samples.append(RibbonSample(x: px[a], z: pz[a],
                                            halfWidth: ribbonHalfWidthCells(pq[a], cfg: terrain.cfg) * taper,
                                            alpha: alpha[a] * taper,
                                            rank: rank[a], surface: nil, bend: pb[a]))
            }

            // MÜNDUNG (Issue #34): das Band lief bisher über die letzten ~2
            // Zellen auf null zusammen und endete auf der zell-gerundeten
            // Zentrumslinie — die Uferkontur des Shaders liegt aber per Pixel
            // auf der Wassersäule. Zwischen beiden blieb ein SPALT. Jetzt folgt
            // das Band dem D8-Empfänger bis IN die Wasserfläche und blendet dort
            // über `mouthOverlapCells` aus: die Überlappung schließt den Spalt,
            // die Ausblendung verhindert eine zweite Wasserfläche über dem See.
            // Läuft die Zentrumslinie selbst ins MEER, endet sie hier an der
            // Wasserlinie (letzter Stützpunkt an Land): dahinter liegt das Band
            // unter der Ozean-Ebene, und die Linie krümmt sich dort oft
            // (Seed 1337 Jahr 20.000: drei Zellen Bogen im Meer, der
            // Krümmungs-Deckel verengte die Mündung an der Wasserlinie). Die
            // Mündung läuft von dort geradeaus weiter (`mouthPath`).
            if let wet = (lo...hi).first(where: { a in
                let ci = min(max(Int(px[a].rounded()), 0), n - 1)
                let cj = min(max(Int(pz[a].rounded()), 0), n - 1)
                return terrain.h[cj * n + ci] <= terrain.cfg.sea
            }), wet - 1 > lo + 2, wet <= hi,
               // Der Strahler-Anschluss (s. oben) muss auch auf dem gekürzten
               // Band liegen, sonst stünde ein Band ohne ihn (`river_ribbons.gd`).
               rank[lo...(wet - 1)].contains(where: { $0 >= WaterRender.ribbonMinimumRank }) {
                let cut = hi - (wet - 1)
                samples.removeLast(cut)
                hi = wet - 1
            }
            let tail = max(lo, hi - 2)
            let mouth = mouthPath(terrain, fromX: px[hi], fromZ: pz[hi],
                                  dirX: px[hi] - px[tail], dirZ: pz[hi] - pz[tail])
            if mouth.isEmpty {
                // Kein Wasser in Reichweite: der Lauf versickert im Land oder
                // endet vor einer Steilstrecke, die das Raster weitermalt —
                // dort läuft das Band spitz aus (Länge wie an der Quelle nach
                // der Halbbreite, sonst endete ein breiter Lauf stumpf).
                let tailTaperCells = max(WaterRender.ribbonTailTaperCells,
                                         WaterRender.ribbonLandTaperHalfWidths
                                         * ribbonHalfWidthCells(pq[hi], cfg: terrain.cfg))
                for a in samples.indices {
                    let t = clamp01((arc[hi] - arc[lo + a]) / (tailTaperCells * cs))
                    samples[a].halfWidth *= t
                    samples[a].alpha *= t
                }
            } else {
                // Deckkraft-Halt (`WaterRender.mouthAlphaHoldCells`): auf den
                // letzten Zellen vor dem Wasser fällt die Deckkraft stromab
                // nicht mehr, und die Mündungs-Kette übernimmt den Endwert.
                if let last = samples.indices.last {
                    var first = last
                    while first > 0, arc[hi] - arc[lo + first - 1] <= WaterRender.mouthAlphaHoldCells * cs {
                        first -= 1
                    }
                    if first < last {
                        for a in (first + 1)...last { samples[a].alpha = max(samples[a].alpha, samples[a - 1].alpha) }
                    }
                }
                let mouthWidth = ribbonHalfWidthCells(pq[hi], cfg: terrain.cfg)
                let mouthAlpha = max(alpha[hi], samples.last?.alpha ?? 0)
                // Die D8-Kette schreitet in GANZEN Zellen; der Enden-Taper
                // (`taperTail`, 2 Zellen) fiele damit in ~0.5er-Alpha-Stufen je
                // Segment — als Stufen sichtbar und Bruch des
                // Glattheits-Vertrags (river_ribbons.gd: max 0.40 je Segment;
                // gekippt auf eingelaufenen Welten, deren Läufe öfter über
                // flache Aprons münden). Ein Mittelpunkt je Kettenglied
                // halbiert die Schrittweite auf die der regulären Samples;
                // den Spiegel bestimmt `applyWaterHandover` pro Stützpunkt
                // ohnehin selbst.
                // Die Bogenstärke (Tiefenfarbe am Prallhang) des letzten
                // Laufknotens läuft über die Kette linear auf null aus, statt
                // an der Mündung auf 0 zu springen (Review zu #174 C2).
                var prevX = px[hi], prevZ = pz[hi]
                let mouthBend = pb[hi], links = Double(mouth.count)
                for (link, point) in mouth.enumerated() {
                    let step = Double(link)
                    samples.append(RibbonSample(x: (prevX + point.x) * 0.5,
                                                z: (prevZ + point.z) * 0.5,
                                                halfWidth: mouthWidth,
                                                alpha: mouthAlpha,
                                                rank: rank[hi], surface: nil,
                                                bend: mouthBend * (1 - (step + 0.5) / links)))
                    samples.append(RibbonSample(x: point.x, z: point.z,
                                                halfWidth: mouthWidth,
                                                alpha: mouthAlpha,
                                                rank: rank[hi], surface: point.surface,
                                                bend: mouthBend * (1 - (step + 1) / links)))
                    prevX = point.x
                    prevZ = point.z
                }
                // Knick am Übergang Zentrumslinie → Mündungs-Kette: die Linie
                // endet oft eine Zelle neben dem D8-Lauf, die Kette setzt dann
                // unter 30–80° an. Am Knick griff der Krümmungs-Deckel und
                // verengte die Mündung auf eine Spitze (Halbbreite 0,2–0,4,
                // über `ribbonMaxHalfWidthSlope` zwei bis drei Zellen stromauf
                // nachgezogen; Seed 1337 Jahr 20.000). Glättungsdurchgänge
                // über die letzten Laufknoten und die Kette, beide Enden fest:
                // mindestens drei, und weiter, solange der Krümmungs-Deckel im
                // Fenster die Halbbreite unter die Hälfte drücken würde
                // (`WaterRender.mouthJunctionMaxSmoothPasses`). Trifft ein Lauf
                // parallel zur Küste ein und biegt die Kette rechtwinklig ins
                // Meer, reichten drei Durchgänge nicht (Linux, Seed 1337:
                // Halbbreite 0,31 von 2,50 an der Wasserlinie).
                let junction = hi - lo + 1
                let first = max(1, junction - WaterRender.mouthJunctionSmoothSamples)
                let last = samples.count - 2
                if last > first {
                    func pinched() -> Bool {
                        for a in first...last where samples[a].halfWidth > 0 {
                            let r = RiverRibbonRenderer.curvatureRadiusCells(samples[a - 1], samples[a], samples[a + 1])
                                * WaterRender.ribbonCurvatureWidthFactor
                            if r < 0.5 * samples[a].halfWidth { return true }
                        }
                        return false
                    }
                    var pass = 0
                    while pass < 3 || (pass < WaterRender.mouthJunctionMaxSmoothPasses && pinched()) {
                        let raw = samples
                        for a in first...last {
                            samples[a].x = 0.5 * raw[a].x + 0.25 * (raw[a - 1].x + raw[a + 1].x)
                            samples[a].z = 0.5 * raw[a].z + 0.25 * (raw[a - 1].z + raw[a + 1].z)
                        }
                        pass += 1
                    }
                }
                // Jenseits der Wasserlinie liegt die Mündung unter der
                // Ozean-Ebene (`emitRibbon`): mit dem Gelände-Maximum hob der
                // flache Küstensaum das Band als Keil über das Meer (Seed 20,
                // Jahr 20.000, Mündung 358/641).
                for a in junction..<samples.count {
                    let ci = min(max(Int(samples[a].x.rounded()), 0), n - 1)
                    let cj = min(max(Int(samples[a].z.rounded()), 0), n - 1)
                    samples[a].seaMouth = terrain.h[cj * n + ci] <= terrain.cfg.sea
                }
                // Der Überlappungs-Deckel kann mitten im flachen Apron greifen
                // (dort ist die See-Übergabe noch > 0). Dann übernehmen die
                // Delta-Arme — das Band selbst läuft über die letzten 2 Zellen
                // weich aus, statt mit einer Kante zu enden. Im MEER nur über
                // das Stück unter der Ozean-Ebene: endet die Mündung früh (eine
                // Bank eine Zelle vor der Küste hält den Geradeaus-Strahl an),
                // lag der Taper sonst wieder auf dem Strand (Befund #174).
                var taper = WaterRender.ribbonTailTaperCells
                if let firstSea = samples.indices.first(where: { a in
                    guard a >= junction else { return false }
                    let ci = min(max(Int(samples[a].x.rounded()), 0), n - 1)
                    let cj = min(max(Int(samples[a].z.rounded()), 0), n - 1)
                    return terrain.h[cj * n + ci] <= terrain.cfg.sea
                }) {
                    var wet = 0.0
                    for a in (firstSea + 1)..<max(firstSea + 1, samples.count) {
                        let dx = samples[a].x - samples[a - 1].x, dz = samples[a].z - samples[a - 1].z
                        wet += (dx * dx + dz * dz).squareRoot()
                    }
                    taper = min(taper, max(wet, 1e-6))
                }
                RiverRibbonRenderer.taperTail(&samples, cells: taper)
            }

            // Wasser-Übergabe in EINEM Pass über den fertigen Lauf (die
            // Meer-Regel braucht die Strecke SEIT der Uferlinie, also die
            // Reihenfolge der Stützpunkte).
            applyWaterHandover(&samples, terrain)
            if fadesUphill { fadeUphill(&samples, terrain) }
            RiverRibbonRenderer.limitAlphaSteps(&samples)
            emitRibbon(samples, terrain, kind: WaterRender.ribbonKindRiver, still: false,
                       hscale: hscale, lift: lift)

            // DELTA (Issue #34): am Eintritt ins stehende Wasser fächert der Lauf
            // über den Ablagerungskörper auf, den die Sim dort aufschüttet.
            // EIN Fächer je Mündung: münden mehrere Kanäle in dieselbe Zelle
            // (Stummel-Kanäle neben dem Hauptlauf), lagen bis zu vier
            // identische Fächer übereinander und malten einen dunklen Block
            // (Seed 1337, Jahr 230.000).
            if let mouthIndex = samples.firstIndex(where: { $0.surface != nil }),
               mouthIndex > 0,
               !fanMouths.contains(where: {
                   let dx = $0.x - samples[mouthIndex].x, dz = $0.z - samples[mouthIndex].z
                   return dx * dx + dz * dz < WaterRender.deltaFanSpacingCells * WaterRender.deltaFanSpacingCells
               }) {
                let entry = samples[mouthIndex], before = samples[mouthIndex - 1]
                fanMouths.append((x: entry.x, z: entry.z))
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
        return mesh
    }

    /// Längs-Filter für Werte, die eher zu FRÜH als zu spät abfallen sollen:
    /// Minimum über ±`radius`, dann Kastenmittel. Aus einem Wechsel
    /// hoch/tief/hoch von Stützpunkt zu Stützpunkt wird so eine stetige Senke
    /// statt eines Streifenmusters. Ein Stützpunkt mit 0 bleibt 0: Minimum und
    /// Kastenmittel sehen um ihn herum nur Nullen.
    static func erodeAndSmooth(_ values: [Double], radius: Int) -> [Double] {
        let cnt = values.count
        guard cnt > 1, radius > 0 else { return values }
        var eroded = values
        for a in 0..<cnt {
            var v = values[a]
            for b in max(0, a - radius)...min(cnt - 1, a + radius) { v = min(v, values[b]) }
            eroded[a] = v
        }
        return boxMean(eroded, radius: radius)
    }

    private static func boxMean(_ values: [Double], radius: Int) -> [Double] {
        let cnt = values.count
        var prefix = [Double](repeating: 0, count: cnt + 1)
        for a in 0..<cnt { prefix[a + 1] = prefix[a] + values[a] }
        var out = values
        for a in 0..<cnt {
            let aLo = max(0, a - radius), aHi = min(cnt, a + radius + 1)
            out[a] = (prefix[aHi] - prefix[aLo]) / Double(aHi - aLo)
        }
        return out
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
            let t = clamp01(distance / cells)
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
    /// hinein (im A/B-Screenshot als heller Rechteck-Ausleger sichtbar).
    ///
    /// Das Band läuft ab der Wasserlinie weich in die Meeresfarbe und Deckkraft 0
    /// aus (über `mouthOverlapCells` Zellen), statt mit gerader Kante über dem
    /// Schelf abzutauchen. Bis zur Wasserlinie bleibt es voll breit und deckend
    /// (Wächter `testRiverBandsReachTheSeaAtFullWidthAndOpacity`).
    @inline(__always)
    private static func seaHandoverFade(submergedCells: Double) -> Double {
        1 - smoothstep(0.0, WaterRender.mouthOverlapCells, submergedCells)
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
        var fade = [Double](repeating: 1, count: samples.count)
        for a in samples.indices {
            let ci = min(max(Int(samples[a].x.rounded()), 0), n - 1)
            let cj = min(max(Int(samples[a].z.rounded()), 0), n - 1)
            let k = cj * n + ci
            // Der SEE-Fade liest die Wassersäule BILINEAR am Stützpunkt — wie
            // der Alpha-Pass die Stream-Map: nearest-cell sprang an den
            // Zellkanten des Ufersaums um bis zu ~0.5 Deckkraft in EINEM
            // Segment (river_ribbons-Vertrag: max 0.40; auf eingelaufenen
            // Welten mit vielen flachen Ponds entlang der Läufe kippte er).
            // Er wirkt auch auf dem letzten TROCKENEN Stück vor dem Ufer
            // (bilinearer Pond > 0 durch die Nachbarzelle): die Blende beginnt
            // damit stetig VOR der nass/trocken-Zellkante statt auf ihr.
            // `wlS > sea` hält das Meer draußen — dort gilt die Strecken-Regel.
            let wlS = bilinearGrid(wl, samples[a].x, samples[a].z, n: n)
            let lakePond = wlS > sea
                ? max(wlS - bilinearGrid(h, samples[a].x, samples[a].z, n: n), 0) : 0
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
                fade[a] = RiverRibbonRenderer.lakeHandoverFade(pond: lakePond)
                continue
            }
            if a > 0 {
                let dx = samples[a].x - samples[a - 1].x, dz = samples[a].z - samples[a - 1].z
                submergedCells += (dx * dx + dz * dz).squareRoot()
            }
            samples[a].surface = surface
            fade[a] = surface <= sea
                ? RiverRibbonRenderer.seaHandoverFade(submergedCells: submergedCells)
                : RiverRibbonRenderer.lakeHandoverFade(pond: lakePond)
        }
        // Läuft die Zentrumslinie an einer SEE-Uferlinie entlang, wechseln die
        // Stützpunkte zwischen nass und trocken, und die Übergabe sprang je
        // halbe Zelle zwischen voll und blass: helle und dunkle Querstreifen
        // („Leitersprossen" am See, Befund #174). Die See-Übergabe wird deshalb
        // geglättet (Minimum-Filter).
        // Auf dem MEER gilt die monotone Streckenblende ab der Wasserlinie:
        // der Minimum-Filter darf die Blende nicht auf den Strand zurückziehen
        // (Wächter `testRiverBandsReachTheSeaAtFullWidthAndOpacity`).
        var lakeFade = fade
        for a in samples.indices {
            let s = samples[a].surface ?? 1.0
            if s <= sea { lakeFade[a] = 1.0 }
        }
        lakeFade = RiverRibbonRenderer.erodeAndSmooth(lakeFade, radius: WaterRender.ribbonHandoverSmoothSamples)
        for a in samples.indices {
            let s = samples[a].surface ?? 1.0
            let f = s <= sea ? fade[a] : lakeFade[a]
            samples[a].alpha *= f
        }
        // Der Deckel der Deckkraft-Sprünge (`limitAlphaSteps`) läuft beim
        // Aufrufer NACH `fadeUphill`, damit er beide Blenden erfasst.
    }

    /// Wasser fließt nicht bergauf (`WaterRender.ribbonUphillFade`): blendet
    /// jeden Stützpunkt aus, dessen Höhe über dem tiefsten Punkt stromauf
    /// liegt. Höhe = Spiegel auf Wasser, sonst die sichtbare Oberfläche unter
    /// der Mitte — dieselbe, auf die `emitRibbon` das Band legt. Ein stromab
    /// fallender Lauf bleibt bit-gleich (Faktor exakt 1).
    private func fadeUphill(_ samples: inout [RibbonSample], _ terrain: Terrain) {
        let n = terrain.cfg.n, h = terrain.h
        var lowest = Double.infinity
        for a in samples.indices {
            let y = samples[a].surface
                ?? renderSurfaceHeight(h, samples[a].x, samples[a].z, n: n, renderGrid: renderGrid)
            if y > lowest { samples[a].alpha *= WaterRender.ribbonUphillFade(rise: y - lowest) }
            lowest = min(lowest, y)
        }
    }

    /// Deckelt den Deckkraft-Sprung je Segment auf `WaterRender.ribbonMaxAlphaStep`,
    /// indem er Stützpunkte nur ABSENKT (vorwärts und rückwärts je einmal:
    /// danach gilt der Deckel überall). Die See-Übergabe fällt über einer
    /// Pfütze, die tiefer als ihre Rampe ist, sonst in einem einzigen Segment
    /// auf 0. Absenken hält die Übergabe dicht: das Band blendet vor der Pfütze
    /// nur etwas früher aus, eine zweite Wasserfläche entsteht nie.
    private static func limitAlphaSteps(_ samples: inout [RibbonSample]) {
        guard samples.count >= 2 else { return }
        let step = WaterRender.ribbonMaxAlphaStep
        for a in 1..<samples.count {
            samples[a].alpha = min(samples[a].alpha, samples[a - 1].alpha + step)
        }
        for a in stride(from: samples.count - 2, through: 0, by: -1) {
            samples[a].alpha = min(samples[a].alpha, samples[a + 1].alpha + step)
        }
    }

    // MARK: Band-Emission

    /// Hängt ein Band aus `samples` an die Ribbon-Puffer an (Dreiecksstreifen aus
    /// Kantenpaaren). `still` = Altarm: die Fließrichtung wird als 0 kodiert,
    /// woran der Shader Stillwasser erkennt (kein Strömungs-Schimmer).
    private func emitRibbon(_ samples: [RibbonSample], _ terrain: Terrain,
                            kind: Double, still: Bool,
                            hscale: Double, lift: Double) {
        // cellSize 0 (keine definierte Schrittweite): kein Band, sonst 0/0 = NaN
        // in den Kanten-Offsets.
        guard samples.count >= 2, terrain.cfg.cellSize > 0 else { return }
        let n = terrain.cfg.n
        let cs = terrain.cfg.cellSize
        let half = terrain.cfg.world / 2
        let h = terrain.h
        // Keine Bänder übereinander: wo ein FRÜHER gebautes Band schon deckt
        // (`bandCoverage` hält bis hier nur die früheren), blendet dieses aus.
        // Zwei halbtransparente Bänder addierten sich sonst zu dunklen
        // Blöcken und Stößen an Zusammenflüssen, Delta-Fächern und Stummel-
        // Kanälen auf demselben Bett.
        var samples = samples
        for a in samples.indices {
            let occ = bilinearGrid(mesh.bandCoverage, samples[a].x, samples[a].z, n: n)
            samples[a].alpha *= 1 - smoothstep(WaterRender.ribbonOcclusionLo,
                                               WaterRender.ribbonOcclusionHi, occ)
        }
        RiverRibbonRenderer.limitAlphaSteps(&samples)
        // Bogenlänge (Welt) für UV.y — im Shader die Phase der Wellen/Strömung.
        var arc = [Double](repeating: 0, count: samples.count)
        for a in 1..<samples.count {
            let dx = (samples[a].x - samples[a - 1].x) * cs
            let dz = (samples[a].z - samples[a - 1].z) * cs
            arc[a] = arc[a - 1] + (dx * dx + dz * dz).squareRoot()
        }
        // Gemalte Halbbreite je Stützpunkt (Zellen): Breite am Krümmungsradius
        // deckeln, sonst falten sich die Quads an engen Schlingen zu
        // Dreiecks-Fächern (s. WaterRender.ribbonCurvatureWidthFactor). Danach
        // die Änderung je Bogenlänge begrenzen, nur nach unten
        // (`ribbonMaxHalfWidthSlope`): sonst wechselten gedeckelte Knick- und
        // ungedeckelte Mittelpunkte der Mündungs-Kette ab, und das Band zerfiel
        // in versetzte Blöcke.
        var halfWidthCells = [Double](repeating: 0, count: samples.count)
        for a in 0..<samples.count {
            let maxRadius = RiverRibbonRenderer.curvatureRadiusCells(
                                samples[max(0, a - 1)], samples[a],
                                samples[min(samples.count - 1, a + 1)])
                            * WaterRender.ribbonCurvatureWidthFactor
            halfWidthCells[a] = min(maxRadius, max(0, samples[a].halfWidth))
        }
        let widthSlope = WaterRender.ribbonMaxHalfWidthSlope
        for a in 1..<samples.count {
            let len = (arc[a] - arc[a - 1]) / cs
            halfWidthCells[a] = min(halfWidthCells[a], halfWidthCells[a - 1] + widthSlope * len)
        }
        for a in stride(from: samples.count - 2, through: 0, by: -1) {
            let len = (arc[a + 1] - arc[a]) / cs
            halfWidthCells[a] = min(halfWidthCells[a], halfWidthCells[a + 1] + widthSlope * len)
        }
        let base = mesh.vertices.count
        mesh.stripStarts.append(Int32(base))
        // Vorgänger-Stützpunkt für den Deckungs-Stempel: gestempelt wird das
        // SEGMENT, nicht der Punkt (s. `stampCoverage`), und dafür braucht es
        // die bereits GEDECKELTE Halbbreite der vorigen Runde.
        var previous: (x: Double, z: Double, halfWidthCells: Double, alpha: Double)?
        for a in 0..<samples.count {
            let s = samples[a]
            let a0 = max(0, a - 1), a1 = min(samples.count - 1, a + 1)
            // Tangente aus der zentralen Differenz — die glättet die Richtung
            // über den Stützpunkt hinweg. Sie DEGENERIERT aber genau dort, wo
            // die Zentrumslinie eine Haarnadel macht: dann liegen Vorgänger und
            // Nachfolger fast aufeinander, die Differenz ist ~0 und mit ihr die
            // Quer-Richtung. Beide Bandkanten fielen dann auf die Mittellinie,
            // und die anschließenden Quads strahlten von diesem einen Punkt als
            // FÄCHER aus spitzen Dreiecken weg (User: „das Wasser der Flüsse
            // besteht teilweise aus hässlichen Dreiecken"; reproduziert an den
            // verknäulten Läufen der Tiefebene, Seed 1337 / Jahr 20 000).
            // Deshalb eine Rückfallkette auf die einseitigen Segmente: erst
            // vorwärts, dann rückwärts, zuletzt eine feste Richtung. Ein Band
            // hat IMMER eine Quer-Richtung.
            var tx = samples[a1].x - samples[a0].x, tz = samples[a1].z - samples[a0].z
            var tl = (tx * tx + tz * tz).squareRoot()
            if tl <= 1e-6 {
                tx = samples[a1].x - samples[a].x; tz = samples[a1].z - samples[a].z
                tl = (tx * tx + tz * tz).squareRoot()
            }
            if tl <= 1e-6 {
                tx = samples[a].x - samples[a0].x; tz = samples[a].z - samples[a0].z
                tl = (tx * tx + tz * tz).squareRoot()
            }
            if tl > 1e-6 { tx /= tl; tz /= tl } else { tx = 1; tz = 0 }
            let hwCells = halfWidthCells[a]
            let hw = hwCells * cs
            let wx = s.x * cs - half, wz = s.z * cs - half
            let perpx = -tz * hw, perpz = tx * hw
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
            let yMin = yCenter - crossTol, yMax = yCenter + crossTol
            var yLeftD = min(yMax, max(yMin, yL)) + lift
            var yRightD = min(yMax, max(yMin, yR)) + lift
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
                //
                // Nie aber UNTER die Land-Höhe: läuft die Zentrumslinie an
                // einer Uferlinie entlang, wechseln ihre Stützpunkte zwischen
                // nass und trocken. Im flachen Saum liegt der Spiegel unter
                // Gelände + `lift`, das Band sprang je halbe Zelle zwischen
                // beiden Höhen, und jede nasse Reihe tauchte unter das Gelände
                // — Querstreifen („Leitersprossen", Befund #174: Seed 1337,
                // Jahr 230.000, 0,42 Welt-Einheiten Sprung). Das Maximum ist
                // stetig: auf tiefem Wasser gewinnt der Spiegel wie bisher,
                // im Saum das Gelände.
                // Ausnahme: Delta-Arme und Mündungen auf dem MEER. Sie liegen
                // als Trübung unter der Meeres-Ebene; über dem flachen Schelf
                // höbe das Gelände-Maximum sie als Strahlenfächer bzw. Keil
                // darüber.
                let onSea = surface <= terrain.cfg.sea + 1e-9
                let y = surface * hscale + (onSea ? WaterRender.ribbonSeaSurfaceSink
                                                  : WaterRender.ribbonLakeSurfaceLift)
                // Mündung: unter die Ozean-Ebene nur, wo auch die gerenderte
                // Oberfläche schon unter dem Meer liegt — sonst verschwände das
                // Band eine Zelle vor der sichtbaren Wasserlinie unter dem Strand.
                let mouthUnder = s.seaMouth && yCenter <= terrain.cfg.sea * hscale
                if onSea && (kind == WaterRender.ribbonKindDelta || mouthUnder) {
                    yLeftD = y; yRightD = y
                } else {
                    yLeftD = max(yLeftD, y)
                    yRightD = max(yRightD, y)
                }
            }
            let yLeft = Float(yLeftD), yRight = Float(yRightD)
            // Deckung dieses Bandstücks ins gemeinsame Feld: dieselbe Fläche,
            // die gleich als Quad entsteht (Halbbreite in Zellen), mit dem
            // Alpha, mit dem sie wirklich malt. `WaterFieldRenderer` deckelt
            // sein Raster genau um diesen Betrag.
            //
            // Deshalb `hwCells` und NICHT `s.halfWidth`: der Krümmungs-Deckel
            // oben schneidet die Halbbreite an engen Schlingen auf r/2 zurück,
            // und laut `WaterRender.ribbonCurvatureWidthFactor` ist das dort die
            // Regel, nicht der Ausnahmefall. Mit der ungedeckelten Breite meldete
            // das Band Deckung für einen Streifen, den es gar nicht malt — das
            // Raster nahm sein Wasser zurück, das Band ersetzte es nicht, und
            // genau dort riss der Lauf wieder ab (dieselbe Lücke, gegen die der
            // anteilige Deckel eingeführt wurde).
            if let p = previous {
                stampCoverage(fromX: p.x, fromZ: p.z,
                              fromHalfWidthCells: p.halfWidthCells, fromAlpha: p.alpha,
                              toX: s.x, toZ: s.z,
                              toHalfWidthCells: hwCells, toAlpha: s.alpha,
                              // Erstes/letztes Segment: dort endet das Band mit
                              // einer geraden Quad-Kante, nicht an einer Naht.
                              openStart: a == 1, openEnd: a == samples.count - 1,
                              n: n)
            }
            previous = (x: s.x, z: s.z, halfWidthCells: hwCells, alpha: s.alpha)
            mesh.vertices.append(SIMD3(Float(wx - perpx), yLeft, Float(wz - perpz)))
            mesh.vertices.append(SIMD3(Float(wx + perpx), yRight, Float(wz + perpz)))
            let dirX = still ? 0.0 : tx, dirZ = still ? 0.0 : tz
            let col = SIMD4(Float(dirX * 0.5 + 0.5), Float(dirZ * 0.5 + 0.5),
                            Float(clamp01(s.rank)),
                            Float(clamp01(s.alpha)))
            mesh.colors.append(col); mesh.colors.append(col)
            mesh.uvs.append(SIMD2(0, Float(arc[a])))
            mesh.uvs.append(SIMD2(1, Float(arc[a])))
            // UV2.y = Bogenstärke (Tiefenfarbe nach Querprofil, Issue #174 C2).
            let kindUV = SIMD2(Float(kind), Float(max(-1, min(1, s.bend))))
            mesh.uv2s.append(kindUV); mesh.uv2s.append(kindUV)
            if a > 0 {
                let v = Int32(base + (a - 1) * 2)
                mesh.indices.append(v); mesh.indices.append(v + 2); mesh.indices.append(v + 1)
                mesh.indices.append(v + 1); mesh.indices.append(v + 2); mesh.indices.append(v + 3)
            }
        }
    }

    /// Krümmungsradius (Zellen) durch drei Stützpunkte — Menger-Krümmung.
    /// Kollineare oder zusammenfallende Punkte ergeben `.infinity` (Gerade),
    /// der Breiten-Deckel greift dort also nicht.
    private static func curvatureRadiusCells(_ a: RibbonSample, _ b: RibbonSample,
                                             _ c: RibbonSample) -> Double {
        let abx = b.x - a.x, abz = b.z - a.z
        let bcx = c.x - b.x, bcz = c.z - b.z
        let cax = a.x - c.x, caz = a.z - c.z
        let ab = (abx * abx + abz * abz).squareRoot()
        let bc = (bcx * bcx + bcz * bcz).squareRoot()
        let ca = (cax * cax + caz * caz).squareRoot()
        let cross = abs(abx * bcz - abz * bcx)      // = 2 · Dreiecksfläche
        guard cross > 1e-9 else { return .infinity }
        return ab * bc * ca / (2 * cross)
    }

    /// Trägt die Deckkraft EINES BANDSTÜCKS (Stützpunkt → Stützpunkt) in
    /// `bandCoverage` ein (Maximum je Zelle — Bänder dürfen sich überlagern,
    /// doppelt gedeckelt wird trotzdem nicht).
    ///
    /// Gestempelt wird der Streifen, nicht ein Kreis um den Stützpunkt: das
    /// Quad zwischen zwei Stützpunkten ist ein Streifen, die Stützpunkte liegen
    /// aber bis zu ~1,5 Zellen auseinander. Kreise um die Punkte lassen die
    /// Streifenkante dazwischen frei, sobald der Krümmungs-Deckel die Halbbreite
    /// klein macht (ab ~0,3 Zellen); dort bliebe Raster-Wasser UNTER dem Band
    /// stehen (Doppelung statt Lücke — harmlos, aber falsch gemeldet).
    /// Deshalb Abstand zur STRECKE, mit entlang der Strecke interpolierter
    /// Halbbreite und Alpha: beides läuft im Quad ebenso linear.
    ///
    /// `+ 0.5`: eine Zelle gilt als gedeckt, sobald ihr MITTELPUNKT höchstens
    /// eine halbe Zelle neben der gemalten Fläche liegt.
    ///
    /// `openStart`/`openEnd` sagen, ob das Segment am ANFANG bzw. ENDE des Bands
    /// liegt. An inneren Nähten läuft der Fußpunkt in eine Kugelkappe (Radius
    /// `hw + 0.5` um den Stützpunkt) — die ist nötig, damit zwei aufeinander
    /// folgende Segmente an der Naht lückenlos decken, auch wenn die
    /// Zentrumslinie dort abknickt. An den zwei Band-ENDEN gibt es keine Naht:
    /// das Quad endet mit einer GERADEN Kante quer zum letzten Segment (die
    /// Tangente dort ist genau dessen Richtung, s. `emitRibbon`). Dort deckte
    /// die Kappe bis zu `hw` Zellen HINTER dem Bandende Fläche, die kein Quad
    /// malt — dieselbe Fehlerklasse wie die ungedeckelte Breite (Deckung melden,
    /// wo kein Band entsteht), nur auf die Enden reduziert. Deshalb längs nur
    /// die halbe Zelle Überhang aus der Regel oben, quer weiter `hw + 0.5`.
    private func stampCoverage(fromX: Double, fromZ: Double,
                               fromHalfWidthCells: Double, fromAlpha: Double,
                               toX: Double, toZ: Double,
                               toHalfWidthCells: Double, toAlpha: Double,
                               openStart: Bool, openEnd: Bool,
                               n: Int) {
        guard fromAlpha > 0 || toAlpha > 0 else { return }
        let hw0 = max(0, fromHalfWidthCells), hw1 = max(0, toHalfWidthCells)
        let reach = max(hw0, hw1) + 0.5
        let i0 = max(0, Int((min(fromX, toX) - reach).rounded(.down)))
        let i1 = min(n - 1, Int((max(fromX, toX) + reach).rounded(.up)))
        let j0 = max(0, Int((min(fromZ, toZ) - reach).rounded(.down)))
        let j1 = min(n - 1, Int((max(fromZ, toZ) + reach).rounded(.up)))
        guard i0 <= i1, j0 <= j1 else { return }
        let dx = toX - fromX, dz = toZ - fromZ
        let len2 = dx * dx + dz * dz
        // Zulässiger LÄNGS-Überhang an einem offenen Bandende, in
        // Segment-Parametern: die halbe Zelle der Regel oben. Ein degeneriertes
        // Segment (zusammenfallende Stützpunkte) hat keine Richtung, dort bleibt
        // es beim Kreis um den Punkt.
        let overhang = len2 > 1e-12 ? 0.5 / len2.squareRoot() : 0
        for j in j0...j1 {
            for i in i0...i1 {
                // Fußpunkt auf der Strecke (geklemmt: die Nähte sind Kappen).
                let px = Double(i) - fromX, pz = Double(j) - fromZ
                let tRaw = len2 > 1e-12 ? (px * dx + pz * dz) / len2 : 0
                // Hinter einem offenen Bandende hört die gemalte Fläche auf.
                if openStart && tRaw < -overhang { continue }
                if openEnd && tRaw > 1 + overhang { continue }
                let t = clamp01(tRaw)
                let ex = px - dx * t, ez = pz - dz * t
                let hw = hw0 + (hw1 - hw0) * t + 0.5
                if ex * ex + ez * ez > hw * hw { continue }
                let value = clamp01(fromAlpha + (toAlpha - fromAlpha) * t)
                let k = j * n + i
                if mesh.bandCoverage[k] < value { mesh.bandCoverage[k] = value }
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
                guard x.isFinite, z.isFinite, abs(x) < 1e9, abs(z) < 1e9 else { break }
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
            guard let nodeRange = oxbowNodeRange(count: oxbow.count) else { continue }
            let first = nodeRange.lowerBound, last = nodeRange.upperBound
            let age = index < terrain.meander.oxbowAge.count
                ? terrain.meander.oxbowAge[index] : 0
            let fade = clamp01(1 - age / WaterRender.oxbowVisibleYears)
            if fade <= 0 { continue }
            var samples: [RibbonSample] = []
            samples.reserveCapacity(nodeRange.count)
            for nodeIndex in nodeRange {
                let node = oxbow[nodeIndex]
                guard node.x.isFinite, node.z.isFinite,
                      abs(node.x) < 1e9, abs(node.z) < 1e9 else { continue }
                let ci = min(max(Int(node.x.rounded()), 0), n - 1)
                let cj = min(max(Int(node.z.rounded()), 0), n - 1)
                let k = cj * n + ci
                let edgeSteps = min(nodeIndex - first, last - nodeIndex)
                let endFade = clamp01(Double(edgeSteps + 1) / WaterRender.oxbowEndFadeSteps)
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

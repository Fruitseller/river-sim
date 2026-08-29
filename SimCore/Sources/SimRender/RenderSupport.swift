import Foundation
import SimCore

// Gemeinsame Werkzeuge der godot-freien Render-Aufbereitung (Issues #53/#80).
//
// Hier steht, was MEHRERE Render-Module brauchen — sonst hätte jedes eine
// eigene Kopie, und die beiden Wasser-Pfade (Raster-Feld und Band-Geometrie)
// müssen sich exakt einig sein: sie teilen die Uferlinien-Definition
// (`openWaterSurface`), den Mündungs-Pfad (`mouthPath`) und die Band-Halbbreite.
// Die KALIBRIER-Zahlen dahinter liegen unverändert im getesteten Vertrag
// `SimCore.WaterRender` (Issue #51) — dieses Modul rechnet nur mit ihnen.

/// Datenparallel über disjunkte Index-Bereiche — nur für Pässe, deren Zellen
/// unabhängig sind (jede schreibt ausschließlich ihren eigenen Index): das
/// Ergebnis ist BIT-IDENTISCH zur sequenziellen Schleife. Gleiche Idee wie
/// `Terrain.parallel` in SimCore; die Render-Aufbereitung läuft sonst auf dem
/// aufrufenden Thread.
private let hostCoreCount = ProcessInfo.processInfo.activeProcessorCount
@inline(__always) public func parallelChunks(_ count: Int, _ body: (Int, Int) -> Void) {
    let chunks = min(count, max(1, hostCoreCount * 4))
    if chunks <= 1 { body(0, count); return }
    DispatchQueue.concurrentPerform(iterations: chunks) { c in
        body(count * c / chunks, count * (c + 1) / chunks)
    }
}

@inline(__always)
func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

/// Feldwert an kontinuierlicher Grid-Position (bilinear, randgeklemmt).
@inline(__always)
func bilinearGrid(_ field: [Double], _ gx: Double, _ gz: Double, n: Int) -> Double {
    let xi = min(max(Int(gx), 0), n - 2), yi = min(max(Int(gz), 0), n - 2)
    let fx = min(max(gx - Double(xi), 0), 1), fy = min(max(gz - Double(yi), 0), 1)
    let k = yi * n + xi
    return field[k] * (1 - fx) * (1 - fy) + field[k + 1] * fx * (1 - fy)
         + field[k + n] * (1 - fx) * fy + field[k + n + 1] * fx * fy
}

/// Höhe der GERENDERTEN Oberfläche: bilinear zwischen den Render-Gitter-
/// Vertices, die ihrerseits bilinear aus dem n²-Feld lesen (so sampelt der
/// Terrain-Vertex-Shader). Bei `renderGrid >= n` (oder unbekannt, `<= 1`)
/// identisch zu `bilinearGrid`.
///
/// Die Band-Geometrie muss der SICHTBAREN Oberfläche folgen, nicht den
/// Sim-Höhen: auf Steilstrecken weicht das gröbere Render-Mesh um ein
/// Vielfaches von `RenderContract.riverLift` von den Sim-Höhen ab — ein Band
/// auf Sim-Höhen taucht dort abwechselnd unter das Mesh und ragt an
/// Dreieckskämmen als blaue Zacken heraus (User-Screenshots, Steil-Läufe im
/// „balanced"-Gitter 384 auf dem 832er-Feld).
@inline(__always)
func renderSurfaceHeight(_ field: [Double], _ gx: Double, _ gz: Double,
                         n: Int, renderGrid: Int) -> Double {
    if renderGrid <= 1 || renderGrid >= n { return bilinearGrid(field, gx, gz, n: n) }
    let s = Double(n - 1) / Double(renderGrid - 1) // Render-Vertex-Abstand in Zellen
    let rx = gx / s, rz = gz / s
    let xi = min(max(Int(rx), 0), renderGrid - 2)
    let zi = min(max(Int(rz), 0), renderGrid - 2)
    let fx = min(max(rx - Double(xi), 0), 1), fz = min(max(rz - Double(zi), 0), 1)
    let v00 = bilinearGrid(field, Double(xi) * s, Double(zi) * s, n: n)
    let v10 = bilinearGrid(field, Double(xi + 1) * s, Double(zi) * s, n: n)
    let v01 = bilinearGrid(field, Double(xi) * s, Double(zi + 1) * s, n: n)
    let v11 = bilinearGrid(field, Double(xi + 1) * s, Double(zi + 1) * s, n: n)
    // Innerhalb des Quads ist die sichtbare Fläche die TRIANGULIERUNG des
    // Meshes, nicht die Bilinear-Fläche — auf steilen Quads weichen beide um
    // den halben Quad-Twist voneinander ab, und das Band täuchte gegen die
    // Bilinear-Annahme weiter ein/aus. Godots PlaneMesh teilt jedes Quad
    // entlang der ANTI-Diagonale (prevrow+i → thisrow+i−1, also von (1,0)
    // nach (0,1)): unter ihr das Dreieck (0,0)(1,0)(0,1), über ihr
    // (1,1)(0,1)(1,0).
    return fx + fz <= 1
        ? v00 + fx * (v10 - v00) + fz * (v01 - v00)
        : v11 + (1 - fx) * (v01 - v11) + (1 - fz) * (v10 - v11)
}

/// Wasseroberfläche über einer Zelle, falls sie unter offenem Wasser liegt —
/// `nil` = trocken. Meer und See sind zwei verschiedene Flächen: das Meer
/// liegt als eigene Ebene auf `cfg.sea` (Priority-Flood füllt es NICHT auf,
/// `hf == h` unter Meereshöhe), Seen tragen ihren ratenbegrenzten
/// Darstellungs-Spiegel `waterLevel`. Die Präsenz-Schwelle ist der Fuß der
/// Shader-Uferkontur — was der Shader nicht mehr zeichnet, ist auch für die
/// Geometrie kein Wasser.
@inline(__always)
func openWaterSurface(_ k: Int, h: [Double], wl: [Double], sea: Double) -> Double? {
    if h[k] <= sea { return sea }
    let pond = wl[k] - h[k]
    if wl[k] > sea && pond > WaterRender.pondContourLo { return wl[k] }
    return nil
}

/// Halbbreite (Zellen) aus dem Abfluss `q` (Zellen Einzugsgebiet), bezogen
/// auf die Render-Schwelle der Config. Kurve und Grenzen:
/// `WaterRender.ribbonHalfWidthCells`.
@inline(__always)
func ribbonHalfWidthCells(_ q: Double, cfg: SimConfig) -> Double {
    WaterRender.ribbonHalfWidthCells(dischargeCells: q,
                                     referenceCells: cfg.renderMinCells)
}

/// Mündungs-Pfad: Zellzentren vom letzten Zentrumslinien-Knoten dem
/// D8-Empfänger folgend, bis das Band `WaterRender.mouthOverlapCells` tief
/// in der Wasserfläche liegt. Leer = binnen `WaterRender.mouthSearchCells`
/// kein Wasser.
///
/// Die D8-Kette läuft in Zell-Schritten und zickzackt entsprechend; ein
/// 3-Punkt-Mittel glättet sie, ohne die Endpunkte zu verschieben.
/// Wird von BEIDEN Pfaden gebraucht: die Geometrie baut daraus ihre
/// Mündung, das Wasserfeld stempelt denselben Korridor als Saum (sonst
/// malte das D8-Raster unter dem verlängerten Band eine zweite Fluss-Version).
func mouthPath(_ terrain: Terrain, fromX: Double,
               fromZ: Double) -> [(x: Double, z: Double, surface: Double?)] {
    let n = terrain.cfg.n
    let h = terrain.h, wl = terrain.waterLevel, rec = terrain.receiver
    let sea = terrain.cfg.sea
    let i0 = min(max(Int(fromX.rounded()), 0), n - 1)
    let j0 = min(max(Int(fromZ.rounded()), 0), n - 1)
    var k = j0 * n + i0
    var path: [(x: Double, z: Double, surface: Double?)] = []
    var wetCells = 0.0
    for _ in 0..<WaterRender.mouthSearchCells {
        let r = rec[k]
        if r < 0 { break }
        k = Int(r)
        let surface = openWaterSurface(k, h: h, wl: wl, sea: sea)
        path.append((Double(k % n), Double(k / n), surface))
        if surface != nil {
            wetCells += 1
            if wetCells >= WaterRender.mouthOverlapCells + 1 { break }
        }
    }
    guard path.contains(where: { $0.surface != nil }) else { return [] }
    // Trockene Nachzügler abschneiden: die Kette kann nach der Wasserfläche
    // wieder über eine Nehrung/Bank laufen. Ein Band, das dort endet, hätte
    // die Wasserfläche zwar berührt, aber nicht IN ihr aufgehört — genau der
    // Spalt, den die Mündungs-Verlängerung schließen soll.
    while let last = path.last, last.surface == nil { path.removeLast() }
    let raw = path
    for a in 1..<max(raw.count - 1, 1) {
        path[a].x = 0.5 * raw[a].x + 0.25 * (raw[a - 1].x + raw[a + 1].x)
        path[a].z = 0.5 * raw[a].z + 0.25 * (raw[a - 1].z + raw[a + 1].z)
    }
    return path
}

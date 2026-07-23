import Foundation
import SwiftGodot
import SimCore

/// GDExtension-Brücke: hält den reinen `SimCore.Terrain` und reicht seine Felder
/// als Packed*Array an Godot. Alle @Callable-Methoden sind aus GDScript aufrufbar.
///
/// Bewusst dünn: die gesamte Physik lebt in SimCore (headless getestet), hier
/// passiert nur Marshalling Swift → Godot.
@Godot
final class SimNode: Node {
    private let terrain = Terrain(config: SimConfig(), seed: 1337)

    // MARK: Steuerung

    @Callable func generate(seed: Int) {
        terrain.generate(seed: UInt32(truncatingIfNeeded: seed))
    }

    @Callable func step(years: Double) {
        terrain.step(dtYears: years)
    }

    // MARK: Konstanten

    @Callable func gridSize() -> Int { terrain.cfg.n }
    @Callable func worldSize() -> Double { terrain.cfg.world }
    @Callable func seaLevel() -> Double { terrain.cfg.sea }
    @Callable func floorLevel() -> Double { terrain.cfg.floor }
    @Callable func currentYear() -> Double { terrain.years }

    // MARK: Felder (row-major, Länge n*n)

    @Callable func heights() -> PackedFloat32Array { pack(terrain.h) }
    @Callable func filled() -> PackedFloat32Array { pack(terrain.hf) }
    @Callable func sediment() -> PackedFloat32Array { pack(terrain.sed) }
    @Callable func rainField() -> PackedFloat32Array { pack(terrain.rain) }
    @Callable func vegetation() -> PackedFloat32Array { pack(terrain.veg) }
    @Callable func flowArea() -> PackedFloat32Array { pack(terrain.area) }

    /// Abfluss-Nachbar je Zelle (-1 = Senke/Meer) — für Fluss-Geometrie.
    @Callable func receivers() -> PackedInt32Array { PackedInt32Array(terrain.receiver) }

    // MARK: Render-Buffer (in Swift berechnet → GDScript setzt nur zusammen)

    /// Biom-/Höhen-Färbung (aus dem Prototyp) als RGBA8-Byte-Buffer (n*n*4) —
    /// direkt als Farb-Textur hochladbar, kein GDScript-Loop nötig.
    @Callable func terrainColorBytes() -> PackedByteArray {
        let n = terrain.cfg.n
        let sea = terrain.cfg.sea
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        let creek = 22.0 // Fluss-Tönung ab diesem Einzugsgebiet (nur Landzellen über Meer)
        let h = terrain.h, sed = terrain.sed, rain = terrain.rain, veg = terrain.veg, area = terrain.area
        let hf = terrain.hf
        var out = [UInt8](repeating: 255, count: n * n * 4)

        // Fluss-Stärke je Zelle, dann um 1 Zelle DILATIEREN → fette, verbundene
        // Flusslinien statt haardünner Fäden (User: „zu klein/unscheinbar").
        var riv = [Double](repeating: 0, count: n * n)
        for k in 0..<(n * n) where hf[k] > sea {
            let cu = area[k] / cellArea
            if cu >= creek { riv[k] = min(max(log(cu / creek + 1) / 2.0, 0), 1) }
        }
        var rivD = [Double](repeating: 0, count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                var m = riv[k]
                if i > 0 { m = max(m, riv[k - 1]) }
                if i < n - 1 { m = max(m, riv[k + 1]) }
                if j > 0 { m = max(m, riv[k - n]) }
                if j < n - 1 { m = max(m, riv[k + n]) }
                rivD[k] = m
            }
        }

        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                var r = 0.0, g = 0.0, b = 0.0
                let v = h[k]
                if v <= sea + 0.012 {
                    (r, g, b) = gradColor(v)
                } else {
                    r = 0.52; g = 0.55; b = 0.34 // Steppe (olivgrün statt beige)
                    let wr = min(max(rain[k] * 1.2, 0), 1)        // → Gras (Feuchte)
                    r += (0.30 - r) * wr; g += (0.52 - g) * wr; b += (0.22 - b) * wr
                    let wv = veg[k] * 0.85                        // → Wald (Vegetation)
                    r += (0.11 - r) * wv; g += (0.30 - g) * wv; b += (0.13 - b) * wv
                    var rocky = sed[k] < 0.004 ? 0.5 : 0.0
                    if i > 0 && i < n - 1 && j > 0 && j < n - 1 {
                        let slope = (abs(h[k + 1] - h[k - 1]) + abs(h[k + n] - h[k - n])) * 0.25
                        rocky = max(rocky, min(0.85, max(0, slope * 55 - 0.75))) // steiler nötig → mehr Grün
                    }
                    let wf = max(0, rocky)                        // → dunkle Felswände (Kontrast)
                    r += (0.34 - r) * wf; g += (0.31 - g) * wf; b += (0.28 - b) * wf
                    if v > 0.68 {                                 // → dunkles Hochgebirgs-Fels, dann Schnee
                        let wg = min(max((v - 0.68) / 0.10, 0), 1)
                        r += (0.40 - r) * wg; g += (0.39 - g) * wg; b += (0.38 - b) * wg
                    }
                    if v > 0.80 {                                 // → Schnee (nur höchste Gipfel)
                        let ws = min(max((v - 0.80) / 0.05, 0), 1)
                        r += (0.96 - r) * ws; g += (0.97 - g) * ws; b += (0.99 - b) * ws
                    }
                    let t = rivD[k]                               // dezente Tönung für kleine Bäche
                    if t > 0.01 {                                 // (große Flüsse kriegen echte Geometrie)
                        let tw = min(1, t * 0.55)
                        r += (0.12 - r) * tw; g += (0.30 - g) * tw; b += (0.52 - b) * tw
                    }
                }
                let o = k * 4
                out[o] = UInt8(min(max(r, 0), 1) * 255)
                out[o + 1] = UInt8(min(max(g, 0), 1) * 255)
                out[o + 2] = UInt8(min(max(b, 0), 1) * 255)
                // out[o+3] bleibt 255 (Alpha)
            }
        }
        return PackedByteArray(out)
    }

    // Höhen-Farbverlauf (Schwelle, r, g, b) — portiert aus dem Prototyp.
    private let stops: [(Double, Double, Double, Double)] = [
        (-0.3, 0.02, 0.07, 0.20), (0.00, 0.08, 0.22, 0.45), (0.15, 0.20, 0.42, 0.60),
        (0.17, 0.76, 0.70, 0.50), (0.28, 0.25, 0.48, 0.22), (0.45, 0.16, 0.34, 0.16),
        (0.58, 0.42, 0.38, 0.34), (0.70, 0.55, 0.53, 0.51), (0.80, 0.95, 0.96, 0.98),
    ]
    private func gradColor(_ v: Double) -> (Double, Double, Double) {
        for k in 0..<(stops.count - 1) {
            if v <= stops[k + 1].0 {
                let a = stops[k], c = stops[k + 1]
                let t = min(max((v - a.0) / (c.0 - a.0), 0), 1)
                return (a.1 + (c.1 - a.1) * t, a.2 + (c.2 - a.2) * t, a.3 + (c.3 - a.3) * t)
            }
        }
        let c = stops[stops.count - 1]
        return (c.1, c.2, c.3)
    }

    // MARK: Sculpting

    /// Hebt (dir > 0) oder senkt (dir < 0) das Terrain in einem Pinsel um
    /// Gitterzentrum (gx, gz) mit Radius in Welteinheiten. Koppelt in die Tektonik.
    @Callable func sculpt(gx: Double, gz: Double, radiusWorld: Double, dir: Double) {
        terrain.sculpt(gx: gx, gz: gz, radiusWorld: radiusWorld, dir: dir)
    }

    /// Nach Sculpting/Änderungen Entwässerung neu berechnen (für Live-Flüsse).
    @Callable func recomputeFlow() { terrain.computeFlow() }

    // MARK: Fluss-Netz-Geometrie (echtes Netz: variable Breite + Mäander)

    private var rvVerts: [Vector3] = []
    private var rvCols: [Color] = []
    private var rvIdx: [Int32] = []

    /// Tract das Flussnetz aus der Entwässerung, glättet die Läufe, fügt in
    /// flachen Abschnitten Mäander (laterale Sinus-Auslenkung) hinzu und baut ein
    /// Band variabler Breite (∝ Einzugsgebiet). `hscale` = Godot-Höhenskalierung.
    @Callable func buildRivers(hscale: Double) {
        rvVerts.removeAll(keepingCapacity: true)
        rvCols.removeAll(keepingCapacity: true)
        rvIdx.removeAll(keepingCapacity: true)
        let n = terrain.cfg.n
        let world = terrain.cfg.world
        let half = world / 2
        let step = world / Double(n - 1)
        let sea = terrain.cfg.sea
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        let h = terrain.h, hf = terrain.hf, area = terrain.area, rec = terrain.receiver
        let lakeEps = 0.035
        let minCells = 85.0 // Hauptflüsse als Geometrie (kleine Bäche = Terrain-Tönung)

        func sampleH(_ gx: Double, _ gz: Double) -> Double {
            let xi = min(max(Int(gx), 0), n - 2), yi = min(max(Int(gz), 0), n - 2)
            let fx = min(max(gx - Double(xi), 0), 1), fy = min(max(gz - Double(yi), 0), 1)
            let i00 = yi * n + xi
            return h[i00] * (1 - fx) * (1 - fy) + h[i00 + 1] * fx * (1 - fy)
                 + h[i00 + n] * (1 - fx) * fy + h[i00 + n + 1] * fx * fy
        }

        var isBig = [Bool](repeating: false, count: n * n)
        for k in 0..<(n * n) where hf[k] > sea && area[k] / cellArea >= minCells {
            isBig[k] = true
        }
        // Quelle = große Zelle ohne großen Zufluss-Nachbarn.
        func isSource(_ k: Int) -> Bool {
            if !isBig[k] { return false }
            let i = k % n, j = k / n
            for dj in -1...1 {
                for di in -1...1 {
                    if di == 0 && dj == 0 { continue }
                    let ni = i + di, nj = j + dj
                    if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                    let nb = nj * n + ni
                    if isBig[nb] && Int(rec[nb]) == k { return false }
                }
            }
            return true
        }
        var drawn = [Bool](repeating: false, count: n * n)

        for s in 0..<(n * n) where isSource(s) {
            // 1) Durchgehender Lauf: der Abfluss-Kette folgen bis Meer/See/bestehendes Netz.
            var cells: [Int] = []
            var c = s
            var guardN = 0
            while guardN < n * n {
                guardN += 1
                cells.append(c)
                if drawn[c] && cells.count > 1 { break }
                drawn[c] = true
                let r = rec[c]
                if r < 0 { break }
                let ri = Int(r)
                if hf[ri] <= sea || hf[ri] - h[ri] > lakeEps { break } // endet an Küste/See
                c = ri
            }
            if cells.count < 2 { continue }

            // 2) Zentrumslinie (Zellkoords) + Mäander-Auslenkung in flachen Abschnitten
            let m = cells.count
            var px = [Double](repeating: 0, count: m)
            var pz = [Double](repeating: 0, count: m)
            var acc = [Double](repeating: 0, count: m)
            for a in 0..<m {
                let k = cells[a]
                px[a] = Double(k % n); pz[a] = Double(k / n); acc[a] = area[k] / cellArea
            }
            let phase = Double(s % 131) * 0.61
            var distC = 0.0
            for a in 0..<m {
                if a > 0 {
                    let dx0 = px[a] - px[a - 1], dz0 = pz[a] - pz[a - 1]
                    distC += (dx0 * dx0 + dz0 * dz0).squareRoot()
                }
                let a0 = max(0, a - 1), a1 = min(m - 1, a + 1)
                var dx = px[a1] - px[a0], dz = pz[a1] - pz[a0]
                let dl = (dx * dx + dz * dz).squareRoot()
                if dl > 1e-6 { dx /= dl; dz /= dl }
                // Flachheit aus lokaler Steigung entlang des Laufs
                let sl = abs(h[cells[a1]] - h[cells[a0]])
                let flat = max(0, 1 - sl * 55)
                // an den Enden auf 0 ausblenden, damit Quelle/Mündung/Zuflüsse anschließen
                let edge = min(1.0, min(Double(a), Double(m - 1 - a)) / 3.0)
                let amp = (0.4 + 2.6 * flat) * edge // Zellen; steile Bäche gerade, Ebenen mäandern
                let off = amp * sin(distC * 0.5 + phase)
                px[a] += -dz * off // senkrecht zur Fließrichtung auslenken
                pz[a] += dx * off
            }
            // 3) Polylinie glätten (entfernt D8-Treppen), Endpunkte fest
            for _ in 0..<3 {
                var nx = px, nz = pz
                for a in 1..<(m - 1) {
                    nx[a] = (px[a - 1] + 2 * px[a] + px[a + 1]) * 0.25
                    nz[a] = (pz[a - 1] + 2 * pz[a] + pz[a + 1]) * 0.25
                }
                px = nx; pz = nz
            }
            // 4) Band variabler Breite bauen
            for a in 0..<m {
                let a0 = max(0, a - 1), a1 = min(m - 1, a + 1)
                var dx = px[a1] - px[a0], dz = pz[a1] - pz[a0]
                let dl = (dx * dx + dz * dz).squareRoot()
                if dl > 1e-6 { dx /= dl; dz /= dl }
                let w = min(1.5 + 1.3 * log(acc[a] / minCells + 1), 6.5) // Halbbreite in Zellen (fett)
                let perpx = -dz, perpz = dx
                let y = Float(sampleH(px[a], pz[a]) * hscale + 0.18)
                let col = Color(r: Float(dx * 0.5 + 0.5), g: Float(dz * 0.5 + 0.5), b: 1.0, a: 1.0)
                let lx = px[a] - perpx * w, lz = pz[a] - perpz * w
                let rx = px[a] + perpx * w, rz = pz[a] + perpz * w
                rvVerts.append(Vector3(x: Float(-half + lx * step), y: y, z: Float(-half + lz * step)))
                rvVerts.append(Vector3(x: Float(-half + rx * step), y: y, z: Float(-half + rz * step)))
                rvCols.append(col); rvCols.append(col)
                if a > 0 {
                    let base = Int32(rvVerts.count - 4)
                    rvIdx.append(base); rvIdx.append(base + 2); rvIdx.append(base + 1)
                    rvIdx.append(base + 1); rvIdx.append(base + 2); rvIdx.append(base + 3)
                }
            }
        }
    }

    @Callable func riverVerts() -> PackedVector3Array { PackedVector3Array(rvVerts) }
    @Callable func riverColors() -> PackedColorArray { PackedColorArray(rvCols) }
    @Callable func riverIndices() -> PackedInt32Array { PackedInt32Array(rvIdx) }

    private func pack(_ a: [Double]) -> PackedFloat32Array {
        var f = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count { f[i] = Float(a[i]) }
        return PackedFloat32Array(f)
    }
}

#initSwiftExtension(cdecl: "swift_entry_point", types: [SimNode.self])

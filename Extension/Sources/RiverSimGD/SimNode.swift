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

    private let hscale: Double = 26 // Höhen-Skalierung fürs Mesh (Godot-seitig)

    /// Vertex-Positionen in Weltkoordinaten (row-major, n*n).
    @Callable func terrainVertices() -> PackedVector3Array {
        let n = terrain.cfg.n
        let half = terrain.cfg.world / 2
        let step = terrain.cfg.world / Double(n - 1)
        let h = terrain.h
        var v = [Vector3](); v.reserveCapacity(n * n)
        for j in 0..<n {
            for i in 0..<n {
                v.append(Vector3(x: Float(-half + Double(i) * step),
                                 y: Float(h[j * n + i] * hscale),
                                 z: Float(-half + Double(j) * step)))
            }
        }
        return PackedVector3Array(v)
    }

    /// Glatte Vertex-Normalen (Zentraldifferenz auf dem Höhenfeld).
    @Callable func terrainNormals() -> PackedVector3Array {
        let n = terrain.cfg.n
        let step = terrain.cfg.world / Double(n - 1)
        let h = terrain.h
        var out = [Vector3](); out.reserveCapacity(n * n)
        for j in 0..<n {
            for i in 0..<n {
                let l = max(i - 1, 0), r = min(i + 1, n - 1)
                let d = max(j - 1, 0), u = min(j + 1, n - 1)
                let dhx = (h[j * n + r] - h[j * n + l]) * hscale
                let dhz = (h[u * n + i] - h[d * n + i]) * hscale
                let nx = -dhx, ny = 2 * step, nz = -dhz
                let len = (nx * nx + ny * ny + nz * nz).squareRoot()
                out.append(Vector3(x: Float(nx / len), y: Float(ny / len), z: Float(nz / len)))
            }
        }
        return PackedVector3Array(out)
    }

    /// Vertex-Farben (Biom-/Höhen-Färbung aus dem Prototyp), direkt als
    /// PackedColorArray → GDScript braucht keinen Pro-Zelle-Loop mehr.
    @Callable func terrainColors() -> PackedColorArray {
        let n = terrain.cfg.n
        let sea = terrain.cfg.sea
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        let creek = 15.0
        let h = terrain.h, sed = terrain.sed, rain = terrain.rain, veg = terrain.veg, area = terrain.area
        var out = [Color](); out.reserveCapacity(n * n)
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                var r = 0.0, g = 0.0, b = 0.0
                let v = h[k]
                if v <= sea + 0.012 {
                    (r, g, b) = gradColor(v)
                } else {
                    r = 0.66; g = 0.58; b = 0.40 // Steppe
                    let wr = min(max(rain[k], 0), 1)              // → Gras (Feuchte)
                    r += (0.36 - r) * wr; g += (0.54 - g) * wr; b += (0.26 - b) * wr
                    let wv = veg[k] * 0.85                        // → Wald (Vegetation)
                    r += (0.11 - r) * wv; g += (0.30 - g) * wv; b += (0.13 - b) * wv
                    var rocky = sed[k] < 0.004 ? 0.55 : 0.0
                    if i > 0 && i < n - 1 && j > 0 && j < n - 1 {
                        let slope = (abs(h[k + 1] - h[k - 1]) + abs(h[k + n] - h[k - n])) * 0.25
                        rocky = max(rocky, min(0.85, max(0, slope * 70 - 0.55)))
                    }
                    let wf = max(0, rocky)                        // → Fels
                    r += (0.47 - r) * wf; g += (0.45 - g) * wf; b += (0.43 - b) * wf
                    if v > 0.60 {                                 // → Schnee
                        let ws = min(max((v - 0.60) / 0.08, 0), 1)
                        r += (0.95 - r) * ws; g += (0.96 - g) * ws; b += (0.98 - b) * ws
                    }
                    let cu = area[k] / cellArea                   // → Fluss-Tönung
                    if cu >= creek {
                        let t = min(max(log(cu / creek + 1) / 2.5, 0), 1) * 0.85
                        r += (0.10 - r) * t; g += (0.32 - g) * t; b += (0.58 - b) * t
                    }
                }
                out.append(Color(r: Float(r), g: Float(g), b: Float(b), a: 1.0))
            }
        }
        return PackedColorArray(out)
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

    private func pack(_ a: [Double]) -> PackedFloat32Array {
        var f = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count { f[i] = Float(a[i]) }
        return PackedFloat32Array(f)
    }
}

#initSwiftExtension(cdecl: "swift_entry_point", types: [SimNode.self])

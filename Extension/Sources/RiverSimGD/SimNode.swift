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
        let h = terrain.h, sed = terrain.sed, rain = terrain.rain, veg = terrain.veg
        var out = [UInt8](repeating: 255, count: n * n * 4)
        // Wasser (Flüsse/Seen/Altarme) zeichnet das separate Wasser-Feld (waterFieldBytes)
        // als glattes, geshadetes Overlay — hier nur Land-Biome + Meeresgrund.

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

    // MARK: Wasser-Feld (glattes Overlay statt Geometrie — nickmcd-Stream/Pool-Map)

    /// Kontinuierliches Wasser-Feld als RGBA8-Textur (n×n), das der Terrain-Shader
    /// linear gefiltert und geshadet als glattes Overlay rendert — statt blockiger
    /// Pro-Zell-Quads und Ribbon-Meshes. Kanäle:
    ///   R = Fluss-Intensität (Stream-Map: log-skalierter, dilatierter Abfluss)
    ///   G = Seetiefe (Pool-Map: hf−h über Land; deckt Seen UND Altarme ab)
    ///   B,A = Fließrichtung (aus dem Empfänger, kodiert *0.5+0.5) für die Animation
    @Callable func waterFieldBytes() -> PackedByteArray {
        let n = terrain.cfg.n
        let sea = terrain.cfg.sea
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        let creek = 22.0 // ab so viel Einzugsgebiet ein sichtbarer Wasserlauf
        let h = terrain.h, hf = terrain.hf, area = terrain.area, rec = terrain.receiver

        // Stream-Map: log-skalierte Fluss-Intensität, dann 1 Zelle dilatiert →
        // verbundene, nicht haardünne Läufe (linear-Filter macht sie glatt).
        var s = [Double](repeating: 0, count: n * n)
        for k in 0..<(n * n) where hf[k] > sea && h[k] > sea {
            let cu = area[k] / cellArea
            if cu >= creek { s[k] = min(1, log(cu / creek + 1) / 2.5) }
        }
        var sd = [Double](repeating: 0, count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                var m = s[k]
                if i > 0 { m = max(m, s[k - 1]) }
                if i < n - 1 { m = max(m, s[k + 1]) }
                if j > 0 { m = max(m, s[k - n]) }
                if j < n - 1 { m = max(m, s[k + n]) }
                sd[k] = m
            }
        }

        var out = [UInt8](repeating: 0, count: n * n * 4)
        for k in 0..<(n * n) {
            let lake = (hf[k] > sea && hf[k] > h[k]) ? min(1, (hf[k] - h[k]) / 0.08) : 0
            var dx = 0.0, dz = 0.0
            let r = rec[k]
            if r >= 0 {
                let ddx = Double(Int(r) % n - k % n), ddz = Double(Int(r) / n - k / n)
                let dl = (ddx * ddx + ddz * ddz).squareRoot()
                if dl > 1e-6 { dx = ddx / dl; dz = ddz / dl }
            }
            let o = k * 4
            out[o] = UInt8(min(max(sd[k], 0), 1) * 255)
            out[o + 1] = UInt8(min(max(lake, 0), 1) * 255)
            out[o + 2] = UInt8((dx * 0.5 + 0.5) * 255)
            out[o + 3] = UInt8((dz * 0.5 + 0.5) * 255)
        }
        return PackedByteArray(out)
    }

    private func pack(_ a: [Double]) -> PackedFloat32Array {
        var f = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count { f[i] = Float(a[i]) }
        return PackedFloat32Array(f)
    }
}

#initSwiftExtension(cdecl: "swift_entry_point", types: [SimNode.self])

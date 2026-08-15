import Foundation
import SwiftGodot
import SimCore

/// 3D-Bäume aus dem veg-Feld als MultiMesh-Transform-Puffer (Issue #53 aus
/// `SimNode` ausgelagert) — reine Optik, NULL Sim-Rückwirkung.
///
/// Zustand hat der Renderer nur für den Dirty-Vertrag: GDScript soll die
/// MultiMeshes nicht jeden Frame neu füllen, sondern erst wenn sich die
/// Vegetation merklich geändert hat.
final class TreeInstanceRenderer {

    /// veg-Feld beim letzten Baum-Rebuild — Grundlage der Rebuild-Heuristik
    /// (Bäume nicht jeden Frame neu bauen, sondern nur wenn sich die Vegetation
    /// merklich geändert hat). Reiner Render-Zustand.
    private var treeVegSnapshot: [Double] = []

    /// Maximale |Δveg| seit dem letzten `markBuilt` — GDScript rebuildet die
    /// Baum-MultiMeshes erst ab einer Schwelle (Heuristik: 0.1). Vor dem
    /// ersten Build (kein Snapshot) immer 1 → erzwingt den Initial-Build.
    func maxDelta(_ terrain: Terrain) -> Double {
        let veg = terrain.veg
        if treeVegSnapshot.count != veg.count { return 1.0 }
        var maxD = 0.0
        for k in 0..<veg.count { maxD = max(maxD, abs(veg[k] - treeVegSnapshot[k])) }
        return maxD
    }

    /// Setzt den Rebuild-Vergleichspunkt auf das aktuelle veg-Feld.
    func markBuilt(_ terrain: Terrain) { treeVegSnapshot = terrain.veg }

    /// Verwirft den Vergleichspunkt (geladene Welt) → `maxDelta` meldet 1 und
    /// der nächste Frame baut die Bäume neu.
    func invalidateSnapshot() { treeVegSnapshot = [] }

    /// FNV-1a über (i, j, salt) → deterministischer Per-Zelle-Zufall für Jitter/
    /// Varianten/Verdünnung. KEIN Frame-Random: gleiche Zelle → gleicher Baum,
    /// sonst flackert der Wald bei jedem Rebuild.
    @inline(__always) private func treeHash01(_ i: Int, _ j: Int, _ salt: UInt32) -> Double {
        var x: UInt32 = 2_166_136_261
        x = (x ^ UInt32(truncatingIfNeeded: i)) &* 16_777_619
        x = (x ^ UInt32(truncatingIfNeeded: j)) &* 16_777_619
        x = (x ^ salt) &* 16_777_619
        // Avalanche-Mix (fmix32): FNV allein korreliert auf Rastern sichtbar.
        x ^= x >> 16; x = x &* 0x85eb_ca6b; x ^= x >> 13
        return Double(x) / Double(UInt32.max)
    }

    /// MultiMesh-Transform-Puffer je Baum-Variante (0 Laubbaum, 1 Nadelbaum,
    /// 2 Busch): 12 Floats pro Instanz im Godot-Buffer-Layout (3×4-Zeilen der
    /// Basis + Origin) — GDScript setzt ihn direkt (`multimesh.buffer`), ohne
    /// je Instanz ein Transform3D zu bauen. `hscale` = vertikale Render-
    /// Überhöhung aus Main.gd (reine Render-Konstante, kennt SimCore nicht).
    ///
    /// Maske je Kandidat (jede 3. Zelle): nur Waldklasse, trocken, fern von
    /// Strand und Aue, flach und innerhalb der Baumgrenze. Damit bleiben Gras,
    /// Flusskorridore, Deltas, Küsten, steile Hänge und Gipfel als Terrain lesbar.
    /// `coverage` ist reine Darstellung: 1 = reduziert, 2 = voll. Jitter,
    /// Varianten-Wahl, Größe und Verdünnung kommen deterministisch aus dem
    /// (i,j)-Hash; weder Sim-Zustand noch Rebuild-Reihenfolge beeinflussen ihn.
    func buffer(_ terrain: Terrain, variant: Int, hscale: Double,
                coverage: Int) -> PackedFloat32Array {
        let n = terrain.cfg.n
        let sea = terrain.cfg.sea
        let cs = terrain.cfg.cellSize
        let half = terrain.cfg.world / 2
        let h = terrain.h, hf = terrain.hf, veg = terrain.veg, rain = terrain.rain
        let vegClass = terrain.vegClass
        let bands = terrain.heightBands
        var out: [Float] = []
        out.reserveCapacity(10_000 * 12)
        for j in stride(from: 6, to: n - 6, by: 3) {
            for i in stride(from: 6, to: n - 6, by: 3) {
                let k = j * n + i
                let v = veg[k]
                // Klasse 2 ist der vom Sim-Kern abgeleitete Wald. Gras (auch im
                // Bett), Auwald und kahle Flächen bleiben bewusst ohne 3D-Gehölz:
                // Auen/Deltas sollen den Flussverlauf statt einer Kronendecke zeigen.
                if vegClass[k] != 2 || v <= 0.55 { continue }
                if h[k] <= sea + 0.025 { continue }           // Strand/Meer
                if hf[k] - h[k] >= 0.012 { continue }          // nass: Flussbett/See/Aue
                // WALDGRENZE an der Schneelinie (Issue #4): das Vegetationsband
                // reicht höher als die Schneegrenze (vegNone ≈ 0.685 gegen
                // snowStart ≈ 0.570), die Sim hält dort also noch veg — Bäume auf
                // verschneiten Gipfeln wären aber sichtbar falsch. Regel und
                // Messwerte: HeightBands.bearsTrees.
                if !bands.bearsTrees(h[k]) { continue }
                // Grob-Steigung (±2 Zellen) wie in updateVegetation — dieselbe
                // Quelle (Terrain.macroSlope): der Hang-Charakter zählt, nicht die
                // feine Rinnen-Textur.
                let slope = Terrain.macroSlope(h, k, n)
                if slope * 40 >= 0.18 { continue }
                let habitat = Terrain.vegetationSuitability(height: h[k], slope: slope,
                                                             rain: rain[k], bands: bands)
                if habitat < 0.55 { continue }                 // trocken/frisch karg
                // Sechs Zellen Küstenabstand halten breite sichtbare Strände und
                // flache Küstensedimente offen. Die kleine lokale Suche passiert
                // nur beim seltenen Baum-Rebuild, nicht im Simulationsschritt.
                var nearCoast = false
                for dz in -6...6 where !nearCoast {
                    for dx in -6...6 where h[(j + dz) * n + i + dx] <= sea + 0.012 {
                        nearCoast = true
                        break
                    }
                }
                if nearCoast { continue }
                let isBush = v < 0.72
                // Verdünnung staffelt Biom-Dichte und Feuchte. Die volle Ansicht
                // bleibt absichtlich unter einer geschlossenen Walddecke; reduziert
                // halbiert die bereits selektive Belegung für die Geländelektüre.
                let wetness = min(1, max(0, rain[k] * 1.3))
                let fullKeep = min(0.58, 0.20 + (v - 0.55) * 0.85) * (0.35 + 0.65 * wetness)
                let keep = coverage >= 2 ? fullKeep : fullKeep * 0.5
                if treeHash01(i, j, 0x51ed) >= keep { continue }
                // Varianten-Wahl: Nadel wird mit der Höhe wahrscheinlicher
                // (Vegetations-Stufen), unten dominiert Laub. Höhenband aus dem
                // Sim-Kern (Issue #4) statt der alten absoluten 0.26…0.48 — sonst
                // kippt der Wald mit jeder Neukalibrierung des Höhenbereichs
                // komplett auf eine Variante.
                let wanted: Int
                if isBush {
                    wanted = 2
                } else {
                    wanted = treeHash01(i, j, 0xc0f4) < bands.coniferShare(h[k]) ? 1 : 0
                }
                if wanted != variant { continue }
                // Jitter ±1 Zelle (bricht das 2er-Raster), Höhe bilinear an der
                // gejitterten Position, minimal versenkt (kein Schweben am Hang).
                let jx = (treeHash01(i, j, 0x9e37) - 0.5) * 2.0
                let jz = (treeHash01(i, j, 0x79b9) - 0.5) * 2.0
                let gx = Double(i) + jx, gz = Double(j) + jz
                let y = bilinearGrid(h, gx, gz, n: n) * hscale - 0.05
                let x = gx * cs - half
                let z = gz * cs - half
                let s = (isBush ? 0.7 : 0.8) + 0.5 * treeHash01(i, j, 0x5ca1)
                let ang = treeHash01(i, j, 0x2b2b) * 2 * Double.pi
                let c = s * cos(ang), sn = s * sin(ang)
                // Godot-MultiMesh-Layout (TRANSFORM_3D, ohne Color/CustomData):
                // Zeile0(xx yx zx ox) Zeile1(xy yy zy oy) Zeile2(xz yz zz oz).
                out.append(Float(c)); out.append(0); out.append(Float(sn)); out.append(Float(x))
                out.append(0); out.append(Float(s)); out.append(0); out.append(Float(y))
                out.append(Float(-sn)); out.append(0); out.append(Float(c)); out.append(Float(z))
            }
        }
        return PackedFloat32Array(out)
    }
}

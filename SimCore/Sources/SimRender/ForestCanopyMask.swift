import SimCore

/// Waldmaske des Kronendachs (Issue #152): wie dicht Wald je Zelle steht, als
/// R8-Puffer (n×n, 0 = kein Wald, 255 = geschlossener Bestand).
///
/// Der Terrain-Shader hebt damit das Dach an und setzt Kronen darauf; WO Wald
/// steht, entscheidet allein diese Maske. Sie vereint:
///  1. Vegetation aus den Materialgewichten (`TerrainColorRenderer`), mit
///     Lichtungs-Rauschen verschoben, damit der Wald Gruppen bildet.
///  2. Keine Bäume in Wänden (Weltsteigung), auf Schnee und Eis und im
///     Ufersaum über dem Meer.
///  3. Die Schutzmaske (`WaterProtectMask`, #154): kein Wald über Rasterwasser,
///     Seen und Flussbändern samt Saum.
///
/// Bis #152 rechnete die Studie das im Shader; als Render-Ableitung hier ist
/// sie deterministisch und headless prüfbar. Zustandslos; den Cache hält
/// `RenderState`. Kalibrierung: `SimCore.CanopyRender`.
public enum ForestCanopyMask {

    /// Lichtungs-Rauschen je Zelle, zentriert um 0. Hängt nur an Gittergröße
    /// und Weltbreite, nicht am Zustand (und bewusst nicht am Welt-Seed: kein
    /// Weltwechsel muss es neu rechnen); `RenderState` rechnet es einmal.
    public static func clumpField(n: Int, world: Double) -> [Float] {
        guard n > 0 else { return [] }
        let scale = CanopyRender.clumpFrequency * world / Double(n)
        var field = [Float](repeating: 0, count: n * n)
        field.withUnsafeMutableBufferPointer { fb in
            let pf = fb.baseAddress!
            parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<n {
                        let v = clumpNoise((Double(i) + 0.5) * scale, (Double(j) + 0.5) * scale)
                        pf[j * n + i] = Float(v - CanopyRender.clumpMean)
                    }
                }
            }
        }
        return field
    }

    /// Value-Noise-fBm der Flusstal-Studie (3 Oktaven, Amplituden 0.55 · 0.48ⁱ,
    /// Wertebereich 0 … 0.94, Mittel ≈ 0.47), portiert aus `fbm`/`vnoise`/
    /// `ehash` in `terrain.gdshader` und `erosion_filter.gdshaderinc`. Gleiche
    /// Statistik wie im abgenommenen Bild; bit-gleich zur GPU ist es nicht und
    /// muss es nicht sein, es läuft nur hier.
    static func clumpNoise(_ x: Double, _ y: Double) -> Double {
        var px = x, py = y, value = 0.0, amplitude = 0.55
        for _ in 0..<3 {
            value += valueNoise(px, py) * amplitude
            px = px * 2.03 + 17.1
            py = py * 2.03 + 9.2
            amplitude *= 0.48
        }
        return value
    }

    private static func valueNoise(_ x: Double, _ y: Double) -> Double {
        let ix = x.rounded(.down), iy = y.rounded(.down)
        let fx = x - ix, fy = y - iy
        let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
        let a = hash(ix, iy), b = hash(ix + 1, iy)
        let c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1)
        let top = a + (b - a) * ux, bottom = c + (d - c) * ux
        return (top + (bottom - top) * uy) * 0.5 + 0.5
    }

    /// x-Komponente von `ehash` (−1 … 1).
    private static func hash(_ x: Double, _ y: Double) -> Double {
        let kx = 0.3183099, ky = 0.3678794
        let hx = x * kx + ky, hy = y * ky + kx
        let p = hx * hy * (hx + hy)
        let inner = p - p.rounded(.down)
        let q = 16 * kx * inner
        return -1 + 2 * (q - q.rounded(.down))
    }

    /// `surfaces` = RGBA8-Materialgewichte (R Vegetation, B Schnee/Eis),
    /// `protect` = R8-Schutzmaske, `clump` = `clumpField`. Passt eine Eingabe
    /// nicht zur Gittergröße, bleibt die Maske leer statt falsch.
    public static func bytes(_ terrain: Terrain, surfaces: [UInt8], protect: [UInt8],
                             clump: [Float]) -> [UInt8] {
        let n = terrain.cfg.n
        let cnt = n * n
        let h = terrain.h
        guard n > 2, h.count == cnt, surfaces.count == cnt * 4,
              protect.count == cnt, clump.count == cnt else {
            return [UInt8](repeating: 0, count: max(cnt, 0))
        }
        let sea = terrain.cfg.sea
        // dh je Zelle (Sim-Einheit) → Weltsteigung: × Überhöhung / Zellbreite.
        let slopeScale = RenderContract.heightScale / (terrain.cfg.world / Double(n)) * 0.5
        var mask = [UInt8](repeating: 0, count: cnt)
        h.withUnsafeBufferPointer { hb in
        surfaces.withUnsafeBufferPointer { sb in
        protect.withUnsafeBufferPointer { pb in
        clump.withUnsafeBufferPointer { cb in
        mask.withUnsafeMutableBufferPointer { mb in
            let ph = hb.baseAddress!, ps = sb.baseAddress!, pp = pb.baseAddress!
            let pc = cb.baseAddress!, pm = mb.baseAddress!
            parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    let jm = max(j - 1, 0), jp = min(j + 1, n - 1)
                    for i in 0..<n {
                        let k = j * n + i
                        if pp[k] != 0 { continue }
                        let v = ph[k]
                        let shore = smoothstep(sea + CanopyRender.shoreLo,
                                               sea + CanopyRender.shoreHi, v)
                        if shore <= 0 { continue }
                        let veg = Double(ps[k * 4]) / 255
                        let cold = Double(ps[k * 4 + 2]) / 255
                        let im = max(i - 1, 0), ip = min(i + 1, n - 1)
                        let dx = ph[j * n + ip] - ph[j * n + im]
                        let dz = ph[jp * n + i] - ph[jm * n + i]
                        let slope = (dx * dx + dz * dz).squareRoot() * slopeScale
                        let f = smoothstep(CanopyRender.vegetationLo, CanopyRender.vegetationHi,
                                           veg + Double(pc[k]) * CanopyRender.clumpGain)
                            * (1 - smoothstep(CanopyRender.wallSlopeLo, CanopyRender.wallSlopeHi, slope))
                            * (1 - smoothstep(CanopyRender.coldLo, CanopyRender.coldHi, cold))
                            * shore
                        pm[k] = byte01(f)
                    }
                }
            }
        }}}}}
        return mask
    }
}

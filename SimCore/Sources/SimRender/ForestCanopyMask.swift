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

    /// Lichtungs-Rauschen je Zelle, um 0 (Lichtungen ziehen es weit ins
    /// Negative, `CanopyRender.clearing*`). Hängt nur an Gittergröße
    /// und Weltbreite, nicht am Zustand (und bewusst nicht am Welt-Seed: kein
    /// Weltwechsel muss es neu rechnen); `RenderState` rechnet es einmal.
    public static func clumpField(n: Int, world: Double) -> [Float] {
        guard n > 0 else { return [] }
        let scale = CanopyRender.clumpFrequency * world / Double(n)
        let clearScale = CanopyRender.clearingFrequency * world / Double(n)
        var field = [Float](repeating: 0, count: n * n)
        field.withUnsafeMutableBufferPointer { fb in
            let pf = fb.baseAddress!
            parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<n {
                        let v = clumpNoise((Double(i) + 0.5) * scale, (Double(j) + 0.5) * scale)
                        // Lichtungen in großer Skala (Look-Iteration 6): ein
                        // zweites, gröberes fBm schneidet auch in dichte
                        // Bestände Lücken, deren Größe mit den Oktaven
                        // streut (Einzellichtung bis Wiesental).
                        let c = clumpNoise((Double(i) + 0.5) * clearScale + 41.3,
                                           (Double(j) + 0.5) * clearScale + 7.9)
                        let clearing = 1 - smoothstep(CanopyRender.clearingLo, CanopyRender.clearingHi, c)
                        pf[j * n + i] = Float(v - CanopyRender.clumpMean - clearing * CanopyRender.clearingDepth)
                    }
                }
            }
        }
        return field
    }

    /// Auwald-Rauschen je Zelle (0 … 0,94, Mittel ≈ 0,47; Look-Iteration 12):
    /// steuert Breite und Lücken des Galeriewalds
    /// (`CanopyRender.riparian*`). Wie `clumpField` nur von Gittergröße und
    /// Weltbreite abhängig; `RenderState` rechnet es einmal.
    public static func riparianField(n: Int, world: Double) -> [Float] {
        guard n > 0 else { return [] }
        let scale = CanopyRender.riparianFrequency * world / Double(n)
        var field = [Float](repeating: 0, count: n * n)
        field.withUnsafeMutableBufferPointer { fb in
            let pf = fb.baseAddress!
            parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<n {
                        pf[j * n + i] = Float(clumpNoise((Double(i) + 0.5) * scale + 113.7,
                                                         (Double(j) + 0.5) * scale + 61.2))
                    }
                }
            }
        }
        return field
    }

    /// Eingaben des Galeriewalds: Abstand zum Wasser
    /// (`WaterProtectMask.canopyGuard`), Auwald-Rauschen (`riparianField`)
    /// und die Makrofarbe (A-Kanal = Sand von Strand und Bank).
    public struct Riparian {
        public let distance: [UInt8]
        public let noise: [Float]
        public let colors: [UInt8]
        /// Sperre für den GRUNDWALD (n×n, leer = keine; Look-Iteration 14):
        /// die volle Schutzmaske. Der Galeriewald darf bis an den
        /// Wasserkörper, der übrige Wald bleibt wie vor Iteration 12 hinter
        /// dem Saum der Schutzmaske — sonst wuchs der Talboden zwischen eng
        /// liegenden Läufen zu.
        public let baseBlock: [UInt8]

        public init(distance: [UInt8], noise: [Float], colors: [UInt8], baseBlock: [UInt8] = []) {
            self.distance = distance
            self.noise = noise
            self.colors = colors
            self.baseBlock = baseBlock
        }

        func fits(_ count: Int) -> Bool {
            distance.count == count && noise.count == count && colors.count == count * 4
        }
    }

    /// Galeriewald-Anteil 0 … `riparianDensity` einer Zelle aus Abstand zum
    /// Wasser (Zellen), Auwald-Rauschen, Fels und Sand. Bewusst OHNE
    /// Vegetationsgewicht: die Sim rodet den Mäandergürtel beim Stempeln
    /// (`veg = 0`), gemessen fiel so ein Drittel der ufernahen Zellen ohne
    /// Wald auf kahlen Gürtelboden — genau der Korridor, um den es geht.
    @inline(__always)
    static func riparianCover(distance: Double, noise: Double, rock: Double, sand: Double) -> Double {
        let t = smoothstep(CanopyRender.riparianGapLo, CanopyRender.riparianGapHi, noise)
        guard t > 0 else { return 0 }
        let width = CanopyRender.riparianWidthLo
            + (CanopyRender.riparianWidthHi - CanopyRender.riparianWidthLo)
            * smoothstep(CanopyRender.riparianGapHi, 0.62, noise)
        let near = 1 - smoothstep(width, width + 1, distance)
        return CanopyRender.riparianDensity * t * near
            * (1 - smoothstep(CanopyRender.riparianRockLo, CanopyRender.riparianRockHi, rock))
            * (1 - smoothstep(CanopyRender.riparianSandLo, CanopyRender.riparianSandHi, sand))
    }

    /// Zielmaske des Frames (vor dem Gedächtnis): Sperre und Abstandskarte
    /// aus Bandkern, Rasterwasser, nasser Wiese und Bänken
    /// (`WaterProtectMask.canopyGuard`), Galeriewald daran. Der EINE Weg,
    /// den `RenderState` fährt; die Wächter rechnen damit nach. `protect`
    /// (die Schutzmaske, leer = keine) sperrt den Grundwald wie vor
    /// Look-Iteration 12 (`Riparian.baseBlock`).
    public static func target(_ terrain: Terrain, surfaces: [UInt8], colors: [UInt8],
                              bandCore: [Double], waterBytes: [UInt8], wetMeadow: [Bool],
                              barSand: [Float], clump: [Float], riparianNoise: [Float],
                              protect: [UInt8] = [])
        -> (mask: [UInt8], distance: [UInt8]) {
        let water = WaterProtectMask.canopyGuard(n: terrain.cfg.n, bandCoverage: bandCore,
                                                 waterBytes: waterBytes, wetMeadow: wetMeadow,
                                                 barSand: barSand)
        let mask = bytes(terrain, surfaces: surfaces, protect: water.blocked, clump: clump,
                         riparian: Riparian(distance: water.distance, noise: riparianNoise,
                                            colors: colors, baseBlock: protect))
        return (mask, water.distance)
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
    /// nicht zur Gittergröße oder fehlt die Schrittweite (`cellSize == 0`, etwa
    /// bei `world <= 0` oder nicht-endlich), bleibt die Maske leer statt falsch.
    /// `riparian` (Look-Iteration 12) setzt entlang des Wassers den
    /// Galeriewald dazu; ohne (oder passt es nicht) gibt es keinen.
    public static func bytes(_ terrain: Terrain, surfaces: [UInt8], protect: [UInt8],
                             clump: [Float], riparian: Riparian? = nil) -> [UInt8] {
        bytes(terrain, surfaces: surfaces, protect: protect, clump: clump,
              vegetationLo: CanopyRender.vegetationLo, vegetationHi: CanopyRender.vegetationHi,
              clumpGain: CanopyRender.clumpGain, riparian: riparian)
    }

    /// Dieselbe Maske mit anderen Vegetations-Schwellen, nur für den
    /// Kalibrier-Sweep (`testCanopyCoverageDiagnostic`, Issue #168); bewusst
    /// nicht öffentlich, die Produktion liest allein `CanopyRender`.
    static func bytes(_ terrain: Terrain, surfaces: [UInt8], protect: [UInt8],
                      clump: [Float], vegetationLo: Double, vegetationHi: Double,
                      clumpGain: Double, riparian: Riparian? = nil) -> [UInt8] {
        let n = terrain.cfg.n
        let cnt = n * n
        let h = terrain.h
        guard n > 2, terrain.cfg.cellSize > 0, h.count == cnt, surfaces.count == cnt * 4,
              protect.count == cnt, clump.count == cnt else {
            return [UInt8](repeating: 0, count: max(cnt, 0))
        }
        let sea = terrain.cfg.sea
        // `macroSlope` ≈ halbe Höhendifferenz je Zelle (Mittel aus |dx| und
        // |dz| über ±2 Zellen) → Weltsteigung: × 2 × Überhöhung / Zellbreite.
        let slopeScale = 2 * RenderContract.heightScale / (terrain.cfg.world / Double(n))
        let rip = riparian?.fits(cnt) == true ? riparian : nil
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
                    for i in 0..<n {
                        let k = j * n + i
                        if pp[k] != 0 { continue }
                        let v = ph[k]
                        let shore = smoothstep(sea + CanopyRender.shoreLo,
                                               sea + CanopyRender.shoreHi, v)
                        // Der Galeriewald hat einen eigenen, flacheren
                        // Ufersaum zum Meer: Mündungsebenen liegen kaum über
                        // dem Meeresspiegel; den Strand sperrt dort das
                        // Sandgewicht (`riparianSand*`).
                        let ripShore = smoothstep(sea + CanopyRender.riparianShoreLo,
                                                  sea + CanopyRender.riparianShoreHi, v)
                        if shore <= 0 && ripShore <= 0 { continue }
                        let veg = Double(ps[k * 4]) / 255
                        let cold = Double(ps[k * 4 + 2]) / 255
                        // Am Rand (2 Zellen) fehlt der Stencil; dort ist Meer.
                        let inner = i > 1 && i < n - 2 && j > 1 && j < n - 2
                        let slope = inner ? Terrain.macroSlope(ph, k, n) * slopeScale : 0
                        let baseOpen = rip.map { $0.baseBlock.count != cnt || $0.baseBlock[k] == 0 } ?? true
                        var cover = smoothstep(vegetationLo, vegetationHi,
                                               veg + Double(pc[k]) * clumpGain) * shore
                            * (baseOpen ? 1 : 0)
                            * (1 - smoothstep(CanopyRender.wallSlopeLo, CanopyRender.wallSlopeHi, slope))
                        if let rip, rip.distance[k] != 255 {
                            // Eigenes Wand-Gate: die Makro-Steigung (±2 Zellen)
                            // schließt am Ufer das eingetiefte Gerinne ein.
                            cover = max(cover, ripShore * riparianCover(
                                distance: Double(rip.distance[k]), noise: Double(rip.noise[k]),
                                rock: Double(ps[k * 4 + 1]) / 255,
                                sand: Double(rip.colors[k * 4 + 3]) / 255)
                                * (1 - smoothstep(CanopyRender.riparianWallSlopeLo,
                                                  CanopyRender.riparianWallSlopeHi, slope)))
                        }
                        let f = cover
                            * (1 - smoothstep(CanopyRender.coldLo, CanopyRender.coldHi, cold))
                        pm[k] = byte01(f)
                    }
                }
            }
        }}}}}
        return mask
    }

    /// Gedächtnis der Waldmaske in Sim-Jahren (Issue #167): `memory` (0 … 1 je
    /// Zelle) folgt `target` (frische Maske aus `bytes`) nach unten SOFORT und
    /// nach oben über exponentielle Relaxation mit Zeitkonstante `tau`
    /// (`Terrain.relaxFraction`, dt-invariant: ein Sprung über `dtYears`
    /// ergibt dasselbe wie viele kleine Takte). Kommt Wasser, ist der Wald
    /// sofort weg; zieht es sich zurück, wächst er nach. Liefert die Maske als
    /// R8. Passt `memory` nicht zu `target`, beginnt das Gedächtnis beim Ziel.
    /// Nicht-positive sowie nicht-endliche Zeitschritte (`dtYears <= 0`, `NaN`, `±inf`)
    /// führen defensiv zu keinem Nachwachsen und vergiften das Gedächtnis nicht.
    /// Nicht-positives oder ungültiges `tau` (`tau <= 0`, `NaN`) führt defensiv zu
    /// sofortigem Nachwachsen auf das Ziel (`rise = 1`, instantane Relaxation).
    ///
    /// `wet` (sichtbares Wasser JETZT, s. `WetNow`) und `retreatTau`: wo das
    /// Ziel fällt und dort kein Wasser liegt, weicht der Wald über
    /// `retreatTau` statt sofort (`CanopyRender.retreatYears`); ohne `wet`,
    /// mit `retreatTau <= 0` oder ohne vergangene Sim-Zeit wie bisher sofort.
    /// `fast` (n×n, leer = keine) markiert Zellen, die über `fastTau` statt
    /// `tau` nachwachsen (Auwald, `CanopyRender.riparianRegrowYears`).
    public static func regrow(_ memory: inout [Float], toward target: [UInt8],
                              dtYears: Double, tau: Double,
                              wet: WetNow? = nil, retreatTau: Double = 0,
                              fast: [Bool] = [], fastTau: Double = 0) -> [UInt8] {
        guard !target.isEmpty else {
            memory = []
            return []
        }
        if memory.count != target.count {
            memory = target.map { Float($0) / 255 }
            return target
        }
        guard tau > 0 else {
            memory = target.map { Float($0) / 255 }
            return target
        }
        let safeDt = (dtYears.isFinite && dtYears > 0) ? dtYears : 0.0
        let rise = Float(Terrain.relaxFraction(dt: safeDt, tau: tau))
        // Auwald (Look-Iteration 12): in Wassernähe (`fast`) wächst der Wald
        // über `fastTau` nach — Weichholzaue auf frisch verlassenem Gleithang.
        let hasFast = fast.count == target.count && fastTau > 0 && fastTau.isFinite
        let riseFast = hasFast ? Float(Terrain.relaxFraction(dt: safeDt, tau: fastTau)) : rise
        // Ohne vergangene Sim-Zeit kein Rückzug über Zeit: ändert sich das
        // Ziel im selben Sim-Jahr (Band-Bau, Wasser-Upload, Pinsel-Takt),
        // folgt der Wald sofort.
        let gradual = safeDt > 0 && retreatTau > 0 && retreatTau.isFinite && wet?.fits(target.count) == true
        let fall = gradual ? Float(Terrain.relaxFraction(dt: safeDt, tau: retreatTau)) : 1
        let probe = gradual ? wet! : WetNow(bandCoverage: [], waterBytes: [], bandThreshold: 1)
        var out = target
        memory.withUnsafeMutableBufferPointer { mb in
        out.withUnsafeMutableBufferPointer { ob in
        probe.bandCoverage.withUnsafeBufferPointer { cb in
        probe.waterBytes.withUnsafeBufferPointer { wb in
            let pm = mb.baseAddress!, po = ob.baseAddress!
            // Leere Felder an der LÄNGE erkennen, nicht an `baseAddress`: die
            // ist für ein leeres Array nur unter Darwin nil, unter Linux zeigt
            // sie auf geteilten Leerspeicher (CI las dort über das Ende hinaus).
            let pc = cb.isEmpty ? nil : cb.baseAddress, pw = wb.isEmpty ? nil : wb.baseAddress
            let band = probe.bandThreshold
            let river = probe.riverThreshold, lake = probe.lakeThreshold
            for k in 0..<target.count {
                let t = Float(po[k]) / 255
                let m = pm[k]
                if t <= m {
                    // Wasser: sofort weg. Sonst (gradual) über `retreatTau`.
                    if !gradual || fall >= 1 || t == m { pm[k] = t; continue }
                    let isWet = (pc != nil && pc![k] >= band)
                        || (pw != nil && (pw![k * 4] >= river || pw![k * 4 + 1] >= lake))
                    if isWet { pm[k] = t; continue }
                    let next = min(1.0, max(t, m + (t - m) * fall))
                    pm[k] = next
                    po[k] = UInt8((next * 255).rounded())
                    continue
                }
                let next = min(1.0, max(0.0, m + (t - m) * (hasFast && fast[k] ? riseFast : rise)))
                pm[k] = next
                po[k] = UInt8((next * 255).rounded())
            }
        }}}}
        return out
    }
}

/// Sichtbares Wasser JETZT für den Wald-Rückzug (`ForestCanopyMask.regrow`):
/// Band ab `bandThreshold` Deckung oder Rasterwasser über den Schwellen der
/// Schutzmaske, ohne Saum, Wiese und Bänke. Davor weicht der Wald sofort, im
/// übrigen geschützten Bereich über `CanopyRender.retreatYears`. Leere Felder
/// zählen nicht (vor dem ersten Band-Bau bzw. Wasser-Upload).
public struct WetNow {
    public let bandCoverage: [Double]
    public let waterBytes: [UInt8]
    public let bandThreshold: Double
    let riverThreshold = byte01(WaterRender.protectRiverThreshold)
    let lakeThreshold = byte01(WaterRender.protectLakeThreshold)

    public init(bandCoverage: [Double], waterBytes: [UInt8], bandThreshold: Double) {
        self.bandCoverage = bandCoverage
        self.waterBytes = waterBytes
        self.bandThreshold = bandThreshold
    }

    /// Passen die Felder zu `count` Zellen (oder sind leer)?
    func fits(_ count: Int) -> Bool {
        (bandCoverage.isEmpty || bandCoverage.count == count)
            && (waterBytes.isEmpty || waterBytes.count == count * 4)
    }
}

import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Zeitraffer-Überblende der Flussbänder (Issue #174): die Band-Geometrie kommt
/// höchstens einmal je `RenderState.ribbonRebuildSeconds` und wurde bis hierher
/// HART ersetzt, während Farbe, Material, Wald und Höhe schon über ihre
/// eigene Blende glitten (#170, #172). Seit dem Mäandergürtel (#174 B)
/// wandern die Läufe so schnell, dass jeder Band-Bau sichtbar springt.
final class RiverFadeTests: XCTestCase {

    // MARK: - Bänder

    /// Die Band-Blende dauert so lange wie der Band-Deckel: im Zeitraffer
    /// liegen zwei Bauten nie dichter (s. `testTimelapseNeverRebuildsInsideTheFade`),
    /// die Blende endet also vor dem nächsten Bau, und kein halb aufgelöster
    /// Stand wird verworfen. Länger hieße genau das; kürzer hieße Stillstand
    /// zwischen den Bauten.
    func testRibbonFadeLastsExactlyTheRebuildCap() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "const RIBBON_FADE_SECONDS := \(glsl(RenderState.ribbonRebuildSeconds))",
                       hint: "Band-Blende == RenderState.ribbonRebuildSeconds")
        assertContains(main, "var ribbon_fade := Crossfade.new(&\"ribbon_blend\", RIBBON_FADE_SECONDS)",
                       hint: "Die Bänder haben ihre EIGENE Blende mit fester Dauer")
        assertContains(main, "if _fixed_seconds > 0.0:\n\t\t\tseconds = _fixed_seconds",
                       hint: "Crossfade nimmt die feste Dauer statt des Upload-Abstands")
    }

    /// Verhalten, auf das die Blende baut: im Zeitraffer baut `RenderState`
    /// die Bänder nie schneller als `ribbonRebuildSeconds`, auch bei
    /// unregelmäßigem Takt. Die Zentrumslinie wandert jeden Takt über die
    /// Rebuild-Schwelle, gebaut wird also bei jeder fälligen Prüfung.
    func testTimelapseNeverRebuildsInsideTheFade() {
        let terrain = Terrain(config: renderConfig(), seed: 1337)
        terrain.meander.channels = [
            RiverChannel(nodes: [MeanderNode(x: 10, z: 10), MeanderNode(x: 12, z: 12)],
                         discharge: [100, 100]),
        ]
        let render = RenderState(geometryMode: true)
        _ = render.frame(terrain, .settled, now: 0)
        let ticks = [0.27, 0.25, 0.31, 0.05, 0.6, 0.27, 0.27, 0.9, 0.12, 0.33, 0.27, 0.27, 0.4, 0.27]
        var now = 0.0, lastBuild = 0.0, builds = 0
        for k in 0..<120 {
            now += ticks[k % ticks.count]
            terrain.meander.channels[0].nodes[0].x += 0.1
            guard render.frame(terrain, .timelapse, now: now).ribbonsRebuilt else { continue }
            XCTAssertGreaterThanOrEqual(now - lastBuild, RenderState.ribbonRebuildSeconds - 1e-9,
                                        "Band-Bau bei \(now) s mitten in der Blende des vorigen")
            lastBuild = now
            builds += 1
        }
        XCTAssertGreaterThan(builds, 20, "Testlauf ohne Band-Bauten sagt nichts")
    }

    /// Verdrahtung in `Main.gd`: zwei Band-Meshes, das alte wandert NUR im
    /// Zeitraffer-Takt ins ausblendende (Pinsel, Sprung, Laden zeigen den
    /// neuen Stand sofort), und es ist im selben Aufruf sichtbar, in dem die
    /// Blende auf 0 springt — sonst fehlte für ein Bild jedes Band.
    func testMainHandsTheOldBandsToTheOutgoingMesh() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        let body = try XCTUnwrap(try main.captures(
            pattern: "func _upload_ribbon_mesh\\(frame: Dictionary\\) -> void:\\n((?:\\t.*\\n|\\n)*)").first)
        for needle in ["var fade := _timelapse_fading()",
                       "river_mesh = river_prev_mesh",
                       "river_prev_mesh = shown",
                       "ribbon_fade.start(_now(), fade)",
                       "river_prev_mi.visible = fade"] {
            XCTAssertTrue(body.contains(needle), "_upload_ribbon_mesh: \(needle)")
        }
        assertContains(main, "river_prev_mi = _make_river_instance(river_prev_mesh, true)",
                       hint: "Das ausblendende Mesh trägt `ribbon_outgoing`")
        assertContains(main, "ribbon_fade.bind(river_mat)", hint: "Neuer Stand an der Band-Blende")
        assertContains(main, "ribbon_fade.bind(river_prev_mat)", hint: "Alter Stand an derselben Blende")
        assertContains(main, "ribbon_fade.advance(delta)", hint: "Die Band-Blende läuft je Frame")
        assertContains(main, "water_mats.append(river_prev_mat)",
                       hint: "Auch der alte Stand bekommt Kalibrierung und Wolken")
    }

    /// Alter und neuer Stand teilen sich die optische Dicke (Befund #174,
    /// Seed 1337 / Jahr 2.305): wo beide liegen, decken sie zusammen GENAU wie
    /// ein Band — lineares Mischen machte stehende Läufe mitten in der Blende
    /// durchsichtiger (0,95 → 0,72) und pulste im Band-Takt. Wo nur einer
    /// liegt, blendet er stetig, ohne Pixel-Los: das zeichnete körnige Ufer.
    func testFadeSplitsOpticalDepthBetweenOldAndNewBands() {
        for a in [0.0, 0.3, 0.6, 0.95, 0.99, 1.0] {
            let capped = min(a, WaterRender.ribbonFadeOpacityCap)
            for k in 0...20 {
                let t = Double(k) / 20
                let new = WaterRender.ribbonFadeOpacity(alpha: a, share: t)
                let old = WaterRender.ribbonFadeOpacity(alpha: a, share: 1 - t)
                let both = 1 - (1 - new) * (1 - old)
                // Innerhalb der Blende gilt der Deckel; an den Enden das Band selbst.
                let expected = (t == 0 || t == 1) ? a : capped
                XCTAssertEqual(both, expected, accuracy: 1e-9,
                               "übereinander: Deckkraft \(a) bei Blende \(t)")
            }
        }
        // Allein liegend: stetig und monoton von 0 bis zur eigenen Deckkraft.
        var last = -1.0
        for k in 0...100 {
            let v = WaterRender.ribbonFadeOpacity(alpha: 1, share: Double(k) / 100)
            XCTAssertGreaterThanOrEqual(v, last, "monoton bei \(k) %")
            XCTAssertLessThan(v - max(last, 0), 0.1, "kein Sprung bei \(k) %")
            last = v
        }
        XCTAssertEqual(WaterRender.ribbonFadeOpacity(alpha: 0.7, share: 0), 0, "Blende 0: unsichtbar")
        XCTAssertEqual(WaterRender.ribbonFadeOpacity(alpha: 0.7, share: 1), 0.7, "ohne Blende unverändert")
    }

    /// Der Shader rechnet dieselbe Formel, ohne Pixel-Los.
    func testWaterShaderSplitsOpticalDepthLikeWaterRender() throws {
        let shader = try RepoSource.probe("game/shaders/water.gdshader")
        assertContains(shader, "uniform float ribbon_blend = 1.0;", hint: "Band-Blende, ohne Bau voll")
        assertContains(shader, "uniform bool ribbon_outgoing = false;", hint: "Rolle des Meshes")
        assertContains(shader, "float share = ribbon_outgoing ? 1.0 - ribbon_blend : ribbon_blend;",
                       hint: "Alter und neuer Stand teilen sich die Blende komplementär")
        assertContains(shader, "return 1.0 - pow(1.0 - clamp(a, 0.0, water_ribbon_fade_cap), max(share, 0.0));",
                       hint: "WaterRender.ribbonFadeOpacity")
        assertContains(shader, "ALPHA = ribbon_fade_alpha(", hint: "Die Blende wirkt auf die fertige Deckkraft")
        XCTAssertEqual(shader.count(ofIdentifier: "discard"), 0, "kein Pixel-Los mehr: es zeichnete körnige Ufer")
        // Deklaration + die beiden Lesestellen in `ribbon_fade_alpha`, sonst nichts.
        XCTAssertEqual(shader.count(ofIdentifier: "ribbon_blend"), 3,
                       "ribbon_blend nur in ribbon_fade_alpha: als linearer Faktor pulsierte der Lauf")
    }

    // MARK: - Sedimentfahne

    /// Die Fahne kommt mit den Overlays und blendet mit ihnen (#174): die
    /// Mip-Weichzeichnung allein glättete den Sprung nicht.
    func testPlumeFadesWithTheOverlays() throws {
        let ocean = try RepoSource.probe("game/shaders/ocean.gdshader")
        assertContains(ocean, "uniform sampler2D plume_prev_tex", hint: "Vorgängerstand der Fahne")
        assertContains(ocean, "mix(textureLod(plume_prev_tex, uv, lod).r, s, overlay_blend)",
                       hint: "plume_at mischt über die Overlay-Blende")
        XCTAssertEqual(ocean.count(of: "textureLod(plume_tex,"), 1,
                       "plume_tex nur in plume_at lesen")
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "overlay_fade.bind(ocean_mat)", hint: "Das Meer hängt an der Overlay-Blende")
        assertContains(main, "plume_prev_tex.update(previous)",
                       hint: "Der alte Stand wandert vor dem Upload nach plume_prev_tex")
    }

    // MARK: - Messlauf

    /// Ein Stützpunkt eines gebauten Bands: Mitte, Halbbreite (Zellen), Alpha.
    private struct BandSample { var x: Double; var z: Double; var half: Double; var alpha: Double }

    private static func bandSamples(_ mesh: RibbonMesh, cfg: SimConfig) -> [BandSample] {
        let cs = cfg.cellSize, half = cfg.world / 2
        var out: [BandSample] = []
        let starts = mesh.stripStarts.map(Int.init) + [mesh.vertices.count]
        for s in 0..<(starts.count - 1) {
            for k in stride(from: starts[s], to: starts[s + 1] - 1, by: 2) {
                let l = mesh.vertices[k], r = mesh.vertices[k + 1]
                let mx = (Double(l.x + r.x) / 2 + half) / cs
                let mz = (Double(l.z + r.z) / 2 + half) / cs
                let dx = Double(r.x - l.x), dz = Double(r.z - l.z)
                let w = (dx * dx + dz * dz).squareRoot() / 2 / cs
                out.append(BandSample(x: mx, z: mz, half: w, alpha: Double(mesh.colors[k].w)))
            }
        }
        return out
    }

    /// Abstand jedes sichtbaren Stützpunkts von `to` zum nächsten von `from`
    /// (Zellen), gedeckelt bei `cap` (= „kein Gegenstück").
    private static func nearest(_ to: [BandSample], from: [BandSample], cap: Double) -> [Double] {
        nearestMatch(to, from: from, cap: cap).map(\.distance)
    }

    private static func nearestMatch(_ to: [BandSample], from: [BandSample],
                                     cap: Double) -> [(distance: Double, index: Int)] {
        let bucket = 4.0
        var grid: [Int: [Int]] = [:]
        func key(_ i: Int, _ j: Int) -> Int { j * 100_000 + i }
        for (k, s) in from.enumerated() {
            grid[key(Int(s.x / bucket), Int(s.z / bucket)), default: []].append(k)
        }
        let reach = Int((cap / bucket).rounded(.up))
        return to.filter { $0.alpha > 0.05 }.map { s in
            let bi = Int(s.x / bucket), bj = Int(s.z / bucket)
            var best = cap * cap, index = -1
            for j in (bj - reach)...(bj + reach) {
                for i in (bi - reach)...(bi + reach) {
                    for k in grid[key(i, j)] ?? [] {
                        let dx = from[k].x - s.x, dz = from[k].z - s.z
                        if dx * dx + dz * dz < best { best = dx * dx + dz * dz; index = k }
                    }
                }
            }
            return (best.squareRoot(), index)
        }
    }

    private static func quantile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))]
    }

    /// Messlauf: was springt bei 60 J/s, in welchem Takt, wie weit?
    /// Produktionswelt Seed 1337 nach dem Einlauf, Zeitraffer-Takt wie
    /// `Main.gd` bei 60 FPS (ein Sim-Takt alle 16 Frames = 0,267 s, 16 Jahre),
    /// Frames über `RenderState.frame(.timelapse)` mit dieser Uhr.
    ///
    /// Bänder: je Band-Bau der Abstand jedes sichtbaren neuen Stützpunkts zum
    /// nächsten des vorigen Baus (Zellen); „> Halbbreite" = die neue Bandmitte
    /// liegt außerhalb des alten Bands, „neu"/„weg" = kein Gegenstück binnen
    /// 8 Zellen. Raster-Wasser: Sprung der SICHTBARKEIT (Fluss-Fenster
    /// `riverMask*`, See-Gate `lakeGate*`) je Overlay-Upload über den nassen
    /// Zellen. Bank-Sand (A der Makrofarbe), Schutzmaske, Fahne: Änderung je
    /// Overlay-Upload. Ob ein Kanal schon blendet, steht nicht hier, sondern in
    /// den Quelltext-Wächtern unten und im Inventar des Commits.
    func testRiverJumpsPerUploadDiagnostic() throws {
        try skipUnlessMeasuring()
        let terrain = Terrain(config: SimConfig.production, seed: 1337,
                              settleYears: SimConfig.productionSettleYears)
        let cfg = terrain.cfg
        let n = cfg.n
        for age in [terrain.years, 20_000.0, 100_000.0] {
            while terrain.years < age { terrain.step(dtYears: min(1000, age - terrain.years)) }
            let render = RenderState(geometryMode: true)
            var now = 0.0
            var last = try XCTUnwrap(render.frame(terrain, .settled, now: now).overlays)
            var lastMesh = render.riverRibbonMesh
            var lastBuild = now
            var shifts: [Double] = [], outside = 0, born = 0, gone = 0, matched = 0
            var halves: [Double] = [], alphaJumps: [Double] = [], widthJumps: [Double] = []
            var gaps: [Double] = []
            var waterJumps: [Double] = [], waterBig = 0, waterCells = 0, waterUploads = 0
            var sandJumps: [Double] = [], protectFlips = 0, plumeChange = 0.0, plumeMass = 0.0
            let tick = 16.0 / 60.0, years = 16.0
            for _ in 0..<(30 * 60 / 16) {   // 30 s Zeitraffer
                now += tick
                terrain.step(dtYears: years)
                render.invalidate(terrain, .advanced)
                let frame = render.frame(terrain, .timelapse, now: now)
                if frame.ribbonsRebuilt {
                    let mesh = render.riverRibbonMesh
                    let old = Self.bandSamples(lastMesh, cfg: cfg)
                    let new = Self.bandSamples(mesh, cfg: cfg)
                    let visibleNew = new.filter { $0.alpha > 0.05 }
                    let d = Self.nearestMatch(new, from: old, cap: 8)
                    for (s, (dist, index)) in zip(visibleNew, d) {
                        if index < 0 { born += 1; continue }
                        matched += 1
                        alphaJumps.append(abs(s.alpha - old[index].alpha))
                        widthJumps.append(abs(s.half - old[index].half))
                        shifts.append(dist)
                        halves.append(s.half)
                        if dist > s.half { outside += 1 }
                    }
                    gone += Self.nearest(old, from: new, cap: 8).filter { $0 >= 8 }.count
                    gaps.append(now - lastBuild)
                    lastBuild = now
                    lastMesh = mesh
                }
                guard let o = frame.overlays else { continue }
                waterUploads += 1
                for k in 0..<(n * n) {
                    func vis(_ w: [UInt8]) -> Double {
                        let r = Double(w[4 * k]) / 255, g = Double(w[4 * k + 1]) / 255
                        return max(WaterRender.smoothstep(WaterRender.riverMaskLo, WaterRender.riverMaskHi, r),
                                   WaterRender.smoothstep(WaterRender.lakeGateLo, WaterRender.lakeGateHi, g))
                    }
                    let a = vis(last.water), b = vis(o.water)
                    if a > 0.01 || b > 0.01 {
                        waterCells += 1
                        let j = abs(b - a)
                        waterJumps.append(j)
                        if j > 0.1 { waterBig += 1 }
                    }
                    let sa = Double(last.colors[4 * k + 3]), sb = Double(o.colors[4 * k + 3])
                    if sa > 0 || sb > 0 { sandJumps.append(abs(sb - sa) / 255) }
                    if last.protectMask[k] != o.protectMask[k] { protectFlips += 1 }
                }
                // Fahne so, wie der Shader sie frühestens sieht: Mip-Stufe
                // `oceanPlumeLod` mittelt 2^lod × 2^lod Zellen.
                let block = 1 << Int(WaterRender.oceanPlumeLod)
                func blocks(_ f: [Float]) -> [Double] {
                    let m = n / block
                    var out = [Double](repeating: 0, count: m * m)
                    for j in 0..<(m * block) { for i in 0..<(m * block) {
                        out[(j / block) * m + i / block] += Double(f[j * n + i])
                    } }
                    return out
                }
                let pa = blocks(last.plume), pb = blocks(o.plume)
                for k in pa.indices { plumeChange += abs(pb[k] - pa[k]); plumeMass += pb[k] }
                last = o
            }
            func f(_ x: Double) -> String { String(format: "%.2f", x) }
            print("== Jahr \(Int(age)) (Seed 1337, Produktion, 60 J/s, 30 s) ==")
            print("Bänder: \(gaps.count) Bauten, Abstand Ø \(f(gaps.reduce(0, +) / Double(max(1, gaps.count)))) s "
                  + "(min \(f(gaps.min() ?? .nan)), max \(f(gaps.max() ?? .nan)))")
            print("  Alpha-Sprung je Bau: Ø \(f(alphaJumps.reduce(0, +) / Double(max(1, alphaJumps.count)))) "
                  + "p99 \(f(Self.quantile(alphaJumps, 0.99))) · Halbbreiten-Sprung Ø "
                  + "\(f(widthJumps.reduce(0, +) / Double(max(1, widthJumps.count)))) p99 \(f(Self.quantile(widthJumps, 0.99))) Zellen")
            print("  Verschiebung je Bau (Zellen): Ø \(f(shifts.reduce(0, +) / Double(max(1, shifts.count)))) "
                  + "p50 \(f(Self.quantile(shifts, 0.5))) p90 \(f(Self.quantile(shifts, 0.9))) "
                  + "p99 \(f(Self.quantile(shifts, 0.99))) · Halbbreite Ø \(f(halves.reduce(0, +) / Double(max(1, halves.count))))")
            let total = Double(max(1, matched + born))
            print("  außerhalb des alten Bands: \(f(100 * Double(outside) / total)) % · neu: "
                  + "\(f(100 * Double(born) / total)) % · weg: \(gone) Stützpunkte")
            print("Raster-Wasser: \(waterUploads) Uploads, Sichtbarkeits-Sprung Ø \(f(waterJumps.reduce(0, +) / Double(max(1, waterJumps.count)))) "
                  + "p99 \(f(Self.quantile(waterJumps, 0.99))) · > 0,1: \(f(100 * Double(waterBig) / Double(max(1, waterCells)))) % der nassen Zellen")
            print("Bank-/Strand-Sand (A): Sprung Ø \(f(sandJumps.reduce(0, +) / Double(max(1, sandJumps.count)))) "
                  + "p99 \(f(Self.quantile(sandJumps, 0.99)))")
            print("Schutzmaske: \(f(Double(protectFlips) / Double(max(1, waterUploads)))) Zellen kippen je Upload · "
                  + "Fahne (8×8-Mittel): \(f(100 * plumeChange / max(plumeMass, 1e-9))) % der Masse je Upload")
        }
    }
}

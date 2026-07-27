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
                    // Fels-first, naturalistisch entsättigt (Vorbild nickmcd): grauer
                    // Fels dominiert, Grün nur in feuchten flachen Tälern, helle
                    // Gipfel/Schnee. Die Zerklüftung/Schattierung macht das Licht.
                    // Steigung GROB (±2 Zellen): seit der Pre-Erosion trägt jede Zelle
                    // feine Rinnen — die Per-Zell-Steigung wäre überall „steil" und
                    // würde die Vegetation aus allen Tälern waschen. Für die Biom-
                    // Färbung zählt der Hang-Charakter, nicht die Rinnen-Textur.
                    var slope = 0.0
                    if i > 1 && i < n - 2 && j > 1 && j < n - 2 {
                        slope = (abs(h[k + 2] - h[k - 2]) + abs(h[k + 2 * n] - h[k - 2 * n])) * 0.125
                    }
                    let steep = min(1, slope * 45)                // 0 flach … 1 steil
                    r = 0.38 + 0.05 * steep                       // grauer Fels; steiler nur LEICHT heller
                    g = 0.39 + 0.05 * steep                       // (0.11 wusch die dichten 100k-Rinnen weiß)
                    b = 0.40 + 0.05 * steep
                    let moist = min(1, rain[k] * 1.2)             // Vegetation: moosgrün in
                    let gentle = max(0, 1 - steep * 0.9)          // Tälern + unteren Hängen (hält sich an Rinnen etwas länger)
                    let altVeg = v < 0.6 ? 1 : max(0, 1 - (v - 0.6) / 0.18)
                    let vegAmt = min(1, (0.5 + 0.5 * veg[k]) * moist * gentle * altVeg * 1.3)
                    r += (0.19 - r) * vegAmt; g += (0.42 - g) * vegAmt; b += (0.14 - b) * vegAmt // kräftigeres Moosgrün
                    if v > 0.58 {                                 // Hochlagen: neutral-grauer Fels (nicht pastell/weiß)
                        let wg = min(1, (v - 0.58) / 0.40)
                        r += (0.43 - r) * wg; g += (0.44 - g) * wg; b += (0.45 - b) * wg
                    }
                    if v > 1.05 {                                 // Schnee nur auf den allerhöchsten Gipfeln
                        let ws = min(1, (v - 1.05) / 0.08)
                        r += (0.93 - r) * ws; g += (0.94 - g) * ws; b += (0.96 - b) * ws
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
    // Persistente, zeitlich geglättete Wasserfelder (EWMA-Gedächtnis über Rebuilds).
    // Ohne sie wird das Feld jeden Tick frisch aus `hf` berechnet und flackert/springt;
    // mit ihnen BLENDET der Lauf zwischen Positionen (`blend` klein im Zeitraffer,
    // 1.0 bei Sprüngen/Sculpting = sofort übernehmen). Reiner Render-Zustand.
    private var sdS: [Double] = []
    private var lakeS: [Double] = []
    private var dxS: [Double] = []
    private var dzS: [Double] = []

    @Callable func waterFieldBytes(blend: Double) -> PackedByteArray {
        let n = terrain.cfg.n
        let sea = terrain.cfg.sea
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        let creek = terrain.cfg.renderMinCells // Render-Schwelle sichtbarer Läufe — ENTKOPPELT vom Braid-Physik-Gate (braidMinCells): 30→120→280 erhöht (User: „zu viele Flüsse"), die Braiding-Physik behält ihr eigenes Gate. Die Mäander-Hauptläufe kommen ohnehin direkt aus den Zentrumslinien.
        // areaMFD (Multi-Flow): stetige Fluss-Intensität → Läufe gleiten statt zu
        // springen und können sich um Bänke teilen. Erosion nutzt weiter D8-`area`.
        let h = terrain.h, hf = terrain.hf, area = terrain.areaMFD, rec = terrain.receiver

        // Stream-Map mit ABFLUSS-ABHÄNGIGER BREITE: ein Fluss wird stromab breiter &
        // kräftiger (Hauptflüsse breit + tiefblau, Bäche dünn). Effizient über
        // schwellen-gestufte Max-Dilatation: dünne Intensität ∝ log(Einzugsgebiet)
        // je Fluss-Zelle, dann 3 Dilatations-Pässe, in denen höhere Pässe nur noch
        // KRÄFTIGE Flüsse weiter verbreitern → Breiten-Hierarchie. Sequenziell,
        // cache-freundlich (kein Scheiben-Stempeln mit verstreuten Zugriffen).
        var sd = [Double](repeating: 0, count: n * n)
        // nickmcd-Rendering: gemalt wird die STREAM-MAP (zeitgemittelte Tropfen-
        // Pfade = wo Wasser wirklich fließt, scharfe Fäden), die Intensität/
        // Breiten-Hierarchie kommt weiter aus dem Abfluss (areaMFD). Die reine
        // Abflussfläche als Maske malte dispergierten Sheet-Flow auf frisch
        // entwässerte Ebenen als flächigen Wash. Nicht unter substanziellen Seen
        // (Tiefe > 0.03) malen: dort deckt die Seefläche.
        let smap = terrain.streamMap
        for k in 0..<(n * n) where hf[k] > sea && h[k] > sea && hf[k] - h[k] <= 0.01 {
            let cu = area[k] / cellArea
            if cu < creek { continue }
            let m = min(max((smap[k] - 0.18) / 0.24, 0), 1) // Track-Maske 0.18..0.42 (von 0.12..0.35 angehoben: Zufallspfad-Speckle bleibt drunter, konsistente Läufe drüber)
            if m <= 0 { continue }
            sd[k] = min(1, 0.4 + log(cu / creek + 1) / 4) * (0.35 + 0.65 * m)
        }
        // WASSERSPIEGEL-BEWUSST dilatieren: Wasser verbreitert sich nur auf Zellen,
        // die nicht nennenswert über dem WASSERSPIEGEL (hf) des Nachbarlaufs liegen
        // (barTol < braidBarHeight). Mittelbänke (Braiding!) und Ufer-/Talkanten
        // bleiben trocken, statt von der Kosmetik-Breite übermalt zu werden —
        // flache Auen und geflutete Ebenen tragen weiter die volle Breiten-
        // Hierarchie (hf, nicht h: seichtes Ponding blockt die Breite nicht).
        // KONTINUITÄT: Intensität dem D8-Empfänger entlang bergab propagieren
        // (leichter Abfall je Zelle). Die Track-Maske lässt sonst Lücken — seit
        // der Alle-Zellen-Dilatations-Pass weg ist (der überbrückte sie), zerfielen
        // gealterte Läufe in Punktketten. Ein sichtbarer Fluss läuft jetzt
        // garantiert durchgängig bis Mündung/See — 1 Zelle breit, Breite macht
        // weiterhin nur die (schwellen-gestufte) Dilatation darunter.
        for start in 0..<(n * n) where sd[start] > 0 {
            var val = sd[start] - 0.015
            var r = rec[start]
            while r >= 0 && val > 0.3 {
                let ri = Int(r)
                if sd[ri] >= val { break }   // Kette ab hier schon (stärker) gemalt
                sd[ri] = val
                val -= 0.015
                r = rec[ri]
            }
        }
        let barTol = 0.004
        // NUR kräftige Läufe verbreitern (kein Alle-Läufe-Pass mehr): Bäche bleiben
        // fadendünn (1 Zelle), Hauptflüsse verlieren ~1 Zelle Breite — die Breiten-
        // Hierarchie bleibt, ihr Absolutniveau sinkt (User: „proportional zu dick";
        // die alte Kalibrierung stammt von der kleineren 640er-Map).
        let widenThresh = [0.55, 0.80]
        var a = sd, b = [Double](repeating: 0, count: n * n)  // Ping-Pong: keine COW-Kopien
        for thresh in widenThresh {
            for j in 0..<n {
                for i in 0..<n {
                    let k = j * n + i
                    var m = a[k]
                    if i > 0 && a[k - 1] > thresh && h[k] - hf[k - 1] < barTol { m = max(m, a[k - 1] - 0.09) }
                    if i < n - 1 && a[k + 1] > thresh && h[k] - hf[k + 1] < barTol { m = max(m, a[k + 1] - 0.09) }
                    if j > 0 && a[k - n] > thresh && h[k] - hf[k - n] < barTol { m = max(m, a[k - n] - 0.09) }
                    if j < n - 1 && a[k + n] > thresh && h[k] - hf[k + n] < barTol { m = max(m, a[k + n] - 0.09) }
                    b[k] = m
                }
            }
            swap(&a, &b)
        }
        sd = a
        let cnt = n * n

        // DIREKT-RENDERING der Mäander-Entitäten: die persistenten Zentrumslinien und
        // Altarme werden GARANTIERT ins Feld gestempelt — unabhängig davon, ob die
        // D8-Drainage dem gecarvten sinuosen Bett folgt. Erst so werden „Arme, die
        // sich schlängeln und als Altarm-Seen abschnüren" wirklich sichtbar (der
        // Mäander IST die Fluss-Entität, nicht ein Nebenprodukt der D8-Karte).
        var mdx = [Double](repeating: 0, count: cnt)   // gestempelte Fließrichtung
        var mdz = [Double](repeating: 0, count: cnt)
        var mstamp = [Bool](repeating: false, count: cnt)
        var oxb = [Double](repeating: 0, count: cnt)   // Altarm-See-Overlay (mit Alter ausgeblendet)
        let noMeanderPaint = ProcessInfo.processInfo.environment["RS_NO_MEANDER_PAINT"] != nil // Debug-Schalter
        for ch in noMeanderPaint ? [] : terrain.meander.channels {
            let nodes = ch.nodes
            if nodes.count < 2 { continue }
            for i in 0..<(nodes.count - 1) {
                let ax = nodes[i].x, az = nodes[i].z, bx = nodes[i + 1].x, bz = nodes[i + 1].z
                let q = 0.5 * (ch.discharge[i] + ch.discharge[i + 1])   // Abfluss (Zellen) am Segment
                // Render-Gate wie beim Abfluss-Feld: Mäander-ENTITÄTEN existieren ab
                // meanderMinCells (85) und migrieren weiter, GEMALT werden Segmente
                // erst ab der Render-Schwelle — sonst stempeln hunderte Mini-Läufe
                // an renderMinCells vorbei (User: „zu viele Flüsse").
                if q < creek { continue }
                // Halbbreite ∝ log(Abfluss), Deckel 1 Zelle (war 3): über 10k+ Jahre
                // verknäulen die migrierten Linien auf den Ebenen — breite Stempel
                // machten aus den Knäueln blaue Blob-Felder („zu viele Flüsse").
                let hw = max(0.0, min(1.0, 0.3 + log(max(q, 1) / creek + 1) / 2.6))
                let rad = Int(hw.rounded())
                let intens = min(1.0, 0.6 + log(max(q, 1) / creek + 1) / 4)
                var tx = bx - ax, tz = bz - az
                let tl = (tx * tx + tz * tz).squareRoot(); if tl > 1e-6 { tx /= tl; tz /= tl }
                let steps = max(1, Int(tl.rounded()))
                for s in 0...steps {
                    let t = Double(s) / Double(steps)
                    let cx = Int((ax + (bx - ax) * t).rounded()), cy = Int((az + (bz - az) * t).rounded())
                    let jLo = max(0, cy - rad), jHi = min(n - 1, cy + rad)
                    let iLo = max(0, cx - rad), iHi = min(n - 1, cx + rad)
                    if jLo > jHi || iLo > iHi { continue }
                    for jj in jLo...jHi {
                        for ii in iLo...iHi {
                            let dd = (ii - cx) * (ii - cx) + (jj - cy) * (jj - cy)
                            if dd > rad * rad { continue }
                            let kk = jj * n + ii
                            // Intensität mit der Stream-Map gewichten: wo dem gestempelten
                            // Bett real kein Wasser folgt (verwaiste/verknäulte Linien),
                            // verblasst der Stempel, statt voll zu leuchten.
                            let mM = min(max((smap[kk] - 0.10) / 0.20, 0), 1)
                            let iM = intens * (0.30 + 0.70 * mM)
                            if sd[kk] < iM { sd[kk] = iM }
                            mstamp[kk] = true; mdx[kk] = tx; mdz[kk] = tz
                        }
                    }
                }
            }
        }
        // Altarme (abgeschnürte Schleifen) als See-Overlay — verblassen mit dem Alter.
        // NUR substanzielle Schleifen (≥ 10 Knoten ≈ 15 Zellen Bogen): die Mäander-
        // Migration schnürt auch winzige 2–4-Knoten-Schlingen ab, die als
        // gestreute 3–6-Zell-Blobs die Ebenen sprenkelten („zu viele Flüsse/Seen"-
        // Eindruck) — erst ab dieser Länge liest sich ein Altarm als Altarm.
        for li in terrain.meander.oxbows.indices {
            if terrain.meander.oxbows[li].count < 10 { continue }
            let age = li < terrain.meander.oxbowAge.count ? terrain.meander.oxbowAge[li] : 0
            let fade = max(0, 1 - age / terrain.cfg.oxbowMaxAge)
            if fade <= 0 { continue }
            for nd in terrain.meander.oxbows[li] {
                let cx = Int(nd.x.rounded()), cy = Int(nd.z.rounded())
                for (ddx, ddy) in [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let ii = cx + ddx, jj = cy + ddy
                    if ii < 0 || ii >= n || jj < 0 || jj >= n { continue }
                    let kk = jj * n + ii
                    if oxb[kk] < 0.7 * fade { oxb[kk] = 0.7 * fade }
                }
            }
        }

        // See-Feld (substanzielle Seen, Tiefe > 0.03 — seichte Flutungs-Pfützen
        // NICHT malen, User: „zu viele Seen") + Altarm-Overlay.
        // KOHÄRENZ-FILTER über Fluss- UND See-Zellen GEMEINSAM: die rauen Braid-
        // Ebenen tragen tausende isolierte Wasser-Fetzen (Pfützen-Cluster +
        // Stream-Map-Patches, seit die Track-Maske Zufallspfade strenger schneidet),
        // die als blaue Punktfelder dithern („zu viele Flüsse/Seen"-Eindruck im
        // gealterten Terrain). Nur zusammenhängende Wasser-Komponenten ab
        // `minWetCells` (4er-Nachbarschaft) werden gemalt: echte Flüsse sind dank
        // der Downstream-Propagation immer LANGE Ketten bis Mündung/See, echte
        // Seen große Flächen — isolierte Patches fliegen raus. Zubringer, die in
        // einen See münden, überleben über die gemeinsame Komponente. Flood-Fill
        // ist O(n²) und läuft eh nur je Render-Tick. Altarme separat via oxb.
        let minWetCells = 25
        var rawWet = [Bool](repeating: false, count: cnt)
        for k in 0..<cnt { rawWet[k] = hf[k] > sea && hf[k] - h[k] > 0.03 }
        var mask = [Bool](repeating: false, count: cnt)
        for k in 0..<cnt { mask[k] = rawWet[k] || sd[k] >= 0.16 }
        var keep = [Bool](repeating: false, count: cnt)
        var seen = [Bool](repeating: false, count: cnt)
        var comp = [Int]()
        var stack = [Int]()
        for start in 0..<cnt where mask[start] && !seen[start] {
            comp.removeAll(keepingCapacity: true)
            stack.removeAll(keepingCapacity: true)
            stack.append(start); seen[start] = true
            while let k = stack.popLast() {
                comp.append(k)
                let i = k % n, j = k / n
                if i > 0 && mask[k - 1] && !seen[k - 1] { seen[k - 1] = true; stack.append(k - 1) }
                if i < n - 1 && mask[k + 1] && !seen[k + 1] { seen[k + 1] = true; stack.append(k + 1) }
                if j > 0 && mask[k - n] && !seen[k - n] { seen[k - n] = true; stack.append(k - n) }
                if j < n - 1 && mask[k + n] && !seen[k + n] { seen[k + n] = true; stack.append(k + n) }
            }
            if comp.count >= minWetCells {
                for k in comp { keep[k] = true }
            }
        }
        var lk = [Double](repeating: 0, count: cnt)
        for k in 0..<cnt {
            if !keep[k] { sd[k] = 0 }
            if keep[k] && rawWet[k] { lk[k] = min(1, (hf[k] - h[k] - 0.03) / 0.10) }
            if oxb[k] > lk[k] { lk[k] = oxb[k] }
        }
        // RÄUMLICH glätten: die Felder sind zell-binär geschwellt (creek/Tiefe) →
        // ohne Glättung wirken Flussränder und Seeufer als Pixel-Grieß. max(Kern,
        // 3×3-Blur) statt reinem Blur: die Kern-Intensität bleibt voll (sonst
        // verblassen dünne Läufe in der Übersicht), nur die Ränder bekommen einen
        // weichen Saum, den der Shader sauber smoothstept.
        func blur3(_ src: [Double]) -> [Double] {
            var dst = [Double](repeating: 0, count: cnt)
            for j in 0..<n {
                for i in 0..<n {
                    let k = j * n + i
                    var s = 0.0, c = 0.0
                    for dj in max(0, j-1)...min(n-1, j+1) {
                        for di in max(0, i-1)...min(n-1, i+1) {
                            s += src[dj * n + di]; c += 1
                        }
                    }
                    dst[k] = s / c
                }
            }
            return dst
        }
        let sdB = blur3(sd), lkB = blur3(lk)
        for k in 0..<cnt {
            sd[k] = max(sd[k], sdB[k])
            lk[k] = max(lk[k], lkB[k])
        }

        // EWMA-Puffer bei Bedarf initialisieren (erstes Feld = sofort übernehmen).
        if sdS.count != cnt {
            sdS = [Double](repeating: 0, count: cnt); lakeS = sdS; dxS = sdS; dzS = sdS
        }
        let bl = min(max(blend, 0), 1) // 1 = Sprung sofort, klein = weiches Blenden

        var out = [UInt8](repeating: 0, count: cnt * 4)
        for k in 0..<cnt {
            let lake = lk[k]
            // Richtung: gestempelte Mäander-Tangente, sonst rohe D8-Nachbardifferenz
            // (∈ {-1,0,1}; der Shader normalisiert selbst → kein sqrt hier). Wird
            // mitgeglättet, damit die Strömungsrichtung nicht schlagartig kippt.
            var dx = 0.0, dz = 0.0
            if mstamp[k] {
                dx = mdx[k]; dz = mdz[k]
            } else {
                let r = rec[k]
                if r >= 0 { dx = Double(Int(r) % n - k % n); dz = Double(Int(r) / n - k / n) }
            }
            // EWMA: geglättetes Feld Richtung frischem Wert ziehen (Gedächtnis über Rebuilds).
            sdS[k]   += bl * (sd[k] - sdS[k])
            lakeS[k] += bl * (lake  - lakeS[k])
            dxS[k]   += bl * (dx    - dxS[k])
            dzS[k]   += bl * (dz    - dzS[k])
            let o = k * 4
            out[o] = UInt8(min(max(sdS[k], 0), 1) * 255)
            out[o + 1] = UInt8(min(max(lakeS[k], 0), 1) * 255)
            out[o + 2] = UInt8((min(max(dxS[k], -1), 1) * 0.5 + 0.5) * 255)
            out[o + 3] = UInt8((min(max(dzS[k], -1), 1) * 0.5 + 0.5) * 255)
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

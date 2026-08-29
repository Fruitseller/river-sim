import Foundation
import SimCore

/// RASTER-Pfad des Wassers (Issue #53 aus `SimNode` ausgelagert): baut aus den
/// Sim-Feldern die kontinuierliche Wasser-Textur, die `terrain.gdshader` als
/// glattes Overlay rendert — dendritische Zubringer, Seen, Meer und der
/// Nass-Saum unter der Band-Geometrie.
///
/// Die andere Hälfte des Wassers malt `RiverRibbonRenderer` als Geometrie; die
/// Grenze zwischen beiden ist die Wassersäule `WaterRender.lakeRawWetDepth`
/// (Issue #34). Alle Schwellen dieses Pfads stehen im Kalibrier-Vertrag
/// `SimCore.WaterRender`; sein Verhalten wird headless in `SimCoreTests`
/// zusammen mit diesem Renderer ausgeführt.
///
/// Eigene Klasse statt freier Funktion, weil der Pfad ZUSTAND hat: die
/// zeitlich geglätteten Ausgabefelder (EWMA über Render-Ticks) und die
/// Arbeitspuffer der vielen Vollbild-Pässe. Reiner Render-Zustand, keine
/// Sim-Rückwirkung.
public final class WaterFieldRenderer {
    public init() {}



    // Persistente, zeitlich geglättete Wasserfelder (EWMA-Gedächtnis über Rebuilds).
    // Ohne sie wird das Feld jeden Tick frisch aus `hf` berechnet und flackert/springt;
    // mit ihnen BLENDET der Lauf zwischen Positionen (`blend` klein im Zeitraffer,
    // 1.0 bei Sprüngen/Sculpting = sofort übernehmen). Reiner Render-Zustand.
    private var sdS: [Double] = []
    private var lakeS: [Double] = []
    private var dxS: [Double] = []
    private var dzS: [Double] = []
    // Die Wasseraufbereitung läuft über viele Vollbild-Pässe. Diese temporären
    // Felder gehören deshalb zum Renderer statt bei jedem Render-Tick neu zu
    // allokieren.
    private var waterStream: [Double] = []
    private var waterWiden: [Double] = []
    private var waterLake: [Double] = []
    private var waterBlur: [Double] = []
    private var waterRawWet: [Bool] = []
    private var waterMask: [Bool] = []
    private var waterComponentFade: [Double] = []
    private var waterSeen: [Bool] = []
    private var waterMDX: [Double] = []
    private var waterMDZ: [Double] = []
    private var waterStamp: [Bool] = []
    private var waterCapStamp: [Bool] = []
    private var waterOxbow: [Double] = []
    private var waterBytes: [UInt8] = []
    private var waterComponent: [Int] = []
    private var waterStack: [Int] = []

    /// Kontinuierliches Wasser-Feld als RGBA8-Puffer (n×n), das der Terrain-Shader
    /// linear gefiltert und geshadet als glattes Overlay rendert — statt blockiger
    /// Pro-Zell-Quads und Ribbon-Meshes. Kanäle:
    ///   R = Fluss-Intensität (Stream-Map: log-skalierter, dilatierter Abfluss)
    ///   G = See-GATE (wo Seen/Altarme sichtbar sind: Komponenten-Fade, geblurt —
    ///       die Ufer-KONTUR und die Tiefe zeichnet der Shader per Pixel aus
    ///       waterLevel − h, Issue #32)
    ///   B,A = Fließrichtung (aus dem Empfänger, kodiert *0.5+0.5) für die Animation
    ///
    /// `geometryMode` = die Mäander-Hauptläufe und Altarme malt die Band-Geometrie
    /// (Standard seit #34); dieses Feld trägt sie dann nur als Nass-Saum.
    /// `bandChannelFlags` = das ECHTE Bau-Ergebnis des letzten Ribbon-Builds je
    /// Kanal-Index (`RiverRibbonRenderer.bandChannelFlags`): nur Kanäle, die
    /// wirklich ein Band bekamen, stempeln einen Saum-Korridor samt Raster-
    /// Deckel. Die vom Strahler-/Kohärenz-Gate verworfenen stempeln NICHTS —
    /// ihr Wasser malt das D8/MFD-Raster wie bei den dendritischen Zubringern.
    /// Vorher deckelte der Korridor ALLE Kanäle und die verworfenen renderten
    /// als Saum ohne Wasser darin (52 % der sichtbaren Zentrumslinien-Zellen).
    /// `deferTail` = die Schwanzstufen (räumlicher Blur, zeitliche EWMA,
    /// Quantisierung) macht der GPU-Pass `game/shaders/water_field_*.gdshader`
    /// statt dieser Funktion. Alles davor bleibt hier: die beiden teuren Stufen
    /// des Pfads sind SEQUENZIELLE Graph-Algorithmen (Kontinuitäts-Kette entlang
    /// der D8-Empfänger, Flood-Fill der Wasser-Komponenten) und passen in kein
    /// Pixel-Programm; sie GPU-seitig zu wollen kostete Readbacks mitten in der
    /// Kette. GEMESSEN in situ (n = 832, M4 Max, game/tests/sculpt_cost.gd):
    /// 14,8 ms mit Schwanz, 13,0 ms ohne — 1,8 ms, und ohne messbare Wirkung auf
    /// die Bildrate (Protokoll: docs/perf-measurements.md §J). Der GPU-Pfad in
    /// Main.gd ist deshalb standardmäßig AUS; dieser Ausgang bleibt, weil er auf
    /// schwacher CPU mit freier GPU gewinnen kann.
    /// Das Kanal-Layout ist in BEIDEN Fällen dasselbe, die Kalibrier-Schwellen
    /// bleiben vollständig hier (der Vertrag `WaterRender` wandert NICHT in den
    /// Shader).
    public func bytes(_ terrain: Terrain, blend: Double, geometryMode: Bool,
                      bandChannelFlags: [Bool], bandCoverage: [Double],
                      deferTail: Bool = false) -> [UInt8] {
        let n = terrain.cfg.n
        let cnt = n * n
        let sea = terrain.cfg.sea
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        let cellDiagonal = terrain.cfg.cellSize * (2.0).squareRoot()
        let creek = terrain.cfg.renderMinCells // Render-Schwelle sichtbarer Läufe — ENTKOPPELT vom Braid-Physik-Gate (braidMinCells): 30→120→280 erhöht (User: „zu viele Flüsse"), die Braiding-Physik behält ihr eigenes Gate. Die Mäander-Hauptläufe kommen ohnehin direkt aus den Zentrumslinien.
        // areaMFD (Multi-Flow): stetige Fluss-Intensität → Läufe gleiten statt zu
        // springen und können sich um Bänke teilen. Erosion nutzt weiter D8-`area`.
        // See-Nässe aus dem ratenbegrenzten Seespiegel statt hf — das Overlay
        // muss zur (ebenfalls waterLevel-gehobenen) See-Geometrie passen und nicht
        // mit jedem hf-Sprung flackern (s. Terrain.waterLevel). Seit Issue #32
        // trägt der G-Kanal das Sichtbarkeits-GATE, keine Tiefe: die Tiefe rechnet
        // der Shader per Pixel aus derselben Wassersäule.
        let h = terrain.h, hf = terrain.waterLevel, area = terrain.areaMFD, rec = terrain.receiver

        if waterStream.count != cnt {
            waterStream = [Double](repeating: 0, count: cnt)
            waterWiden = [Double](repeating: 0, count: cnt)
            waterLake = [Double](repeating: 0, count: cnt)
            waterBlur = [Double](repeating: 0, count: cnt)
            waterMDX = [Double](repeating: 0, count: cnt)
            waterMDZ = [Double](repeating: 0, count: cnt)
            waterOxbow = [Double](repeating: 0, count: cnt)
            waterRawWet = [Bool](repeating: false, count: cnt)
            waterMask = [Bool](repeating: false, count: cnt)
            waterComponentFade = [Double](repeating: 0, count: cnt)
            waterSeen = [Bool](repeating: false, count: cnt)
            waterStamp = [Bool](repeating: false, count: cnt)
            waterCapStamp = [Bool](repeating: false, count: cnt)
            waterBytes = [UInt8](repeating: 0, count: cnt * 4)
            waterComponent.removeAll(keepingCapacity: false)
            waterStack.removeAll(keepingCapacity: false)
        }

        // Lokale Variablen halten die Hot-Loops schnell; durch das Tauschen mit
        // persistentem Speicher bleiben sie dabei über Render-Ticks allokationsfrei.
        var sd: [Double] = []; swap(&sd, &waterStream)
        var b: [Double] = []; swap(&b, &waterWiden)
        var lk: [Double] = []; swap(&lk, &waterLake)
        var blur: [Double] = []; swap(&blur, &waterBlur)
        var rawWet: [Bool] = []; swap(&rawWet, &waterRawWet)
        var mask: [Bool] = []; swap(&mask, &waterMask)
        var componentFade: [Double] = []; swap(&componentFade, &waterComponentFade)
        var seen: [Bool] = []; swap(&seen, &waterSeen)
        var mdx: [Double] = []; swap(&mdx, &waterMDX)
        var mdz: [Double] = []; swap(&mdz, &waterMDZ)
        var mstamp: [Bool] = []; swap(&mstamp, &waterStamp)
        var capStamp: [Bool] = []; swap(&capStamp, &waterCapStamp)
        var oxb: [Double] = []; swap(&oxb, &waterOxbow)
        var out: [UInt8] = []; swap(&out, &waterBytes)
        defer {
            swap(&sd, &waterStream); swap(&b, &waterWiden)
            swap(&lk, &waterLake); swap(&blur, &waterBlur)
            swap(&rawWet, &waterRawWet); swap(&mask, &waterMask)
            swap(&componentFade, &waterComponentFade); swap(&seen, &waterSeen)
            swap(&mdx, &waterMDX); swap(&mdz, &waterMDZ)
            swap(&mstamp, &waterStamp); swap(&capStamp, &waterCapStamp)
            swap(&oxb, &waterOxbow)
            swap(&out, &waterBytes)
        }

        // Stream-Map mit ABFLUSS-ABHÄNGIGER BREITE: ein Fluss wird stromab breiter &
        // kräftiger (Hauptflüsse breit + tiefblau, Bäche dünn). Effizient über
        // schwellen-gestufte Max-Dilatation: dünne Intensität ∝ log(Einzugsgebiet)
        // je Fluss-Zelle, dann 3 Dilatations-Pässe, in denen höhere Pässe nur noch
        // KRÄFTIGE Flüsse weiter verbreitern → Breiten-Hierarchie. Sequenziell,
        // cache-freundlich (kein Scheiben-Stempeln mit verstreuten Zugriffen).
        sd.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        // nickmcd-Rendering: gemalt wird die STREAM-MAP (zeitgemittelte Tropfen-
        // Pfade = wo Wasser wirklich fließt, scharfe Fäden), die Intensität/
        // Breiten-Hierarchie kommt weiter aus dem Abfluss (areaMFD). Die reine
        // Abflussfläche als Maske malte dispergierten Sheet-Flow auf frisch
        // entwässerte Ebenen als flächigen Wash. Nicht unter substanziellen Seen
        // (Tiefe > 0.03) malen: dort deckt die Seefläche.
        let smap = terrain.streamMap
        // Per-Zelle unabhängig → parallel (bit-identisch zur sequenziellen Schleife).
        sd.withUnsafeMutableBufferPointer { sdb in
        h.withUnsafeBufferPointer { hb in hf.withUnsafeBufferPointer { hfb in
        area.withUnsafeBufferPointer { ab in smap.withUnsafeBufferPointer { smb in
            let psd = sdb.baseAddress!, ph = hb.baseAddress!, phf = hfb.baseAddress!
            let pa = ab.baseAddress!, psm = smb.baseAddress!
            parallelChunks(cnt) { lo, hi in
                for k in lo..<hi where phf[k] > sea && ph[k] > sea
                                       && phf[k] - ph[k] <= WaterRender.streamPondTolerance {
                    let cu = pa[k] / cellArea
                    if cu < creek { continue }
                    // Track-Maske und Abfluss-Abstufung stehen im Kalibrier-
                    // Vertrag (`WaterRender`) statt hier und werden zusammen mit
                    // diesem ausführbaren Pfad headless geprüft (Issues #51/#82).
                    let m = WaterRender.trackMask(streamMap: psm[k])
                    if m <= 0 { continue }
                    psd[k] = WaterRender.streamIntensity(dischargeCells: cu, creekCells: creek)
                        * WaterRender.trackWeight(mask: m)
                }
            }
        }}}}}
        // WASSERSPIEGEL-BEWUSST dilatieren: Wasser verbreitert sich nur auf Zellen,
        // deren Bett NAHE am WASSERSPIEGEL (hf) des Nachbarlaufs liegt
        // (|Δ| < barTol, barTol < braidBarHeight — Begründung der Symmetrie am
        // Pass unten). Mittelbänke (Braiding!) und Ufer-/Talkanten
        // bleiben trocken, statt von der Kosmetik-Breite übermalt zu werden —
        // flache Auen und geflutete Ebenen tragen weiter die volle Breiten-
        // Hierarchie (hf, nicht h: seichtes Ponding blockt die Breite nicht).
        // KONTINUITÄT: Intensität dem D8-Empfänger entlang bergab propagieren
        // (leichter Abfall je Zelle, GEKLEMMT auf `continuityFloor`). Die
        // Track-Maske lässt sonst Lücken — seit der Alle-Zellen-Dilatations-Pass
        // weg ist (der überbrückte sie), zerfielen gealterte Läufe in
        // Punktketten. Die Kette endet erst am offenen Wasser (See-Kanal/Meer
        // übernimmt) oder am Kettenende — NICHT mehr, wenn der Abfall die
        // Untergrenze erreicht: mit dem Abbruch dort trug eine Quelle knapp
        // über dem Boden nur (val − floor)/decay ≈ 7 Zellen weit, und der
        // „garantiert durchgängige" Lauf riss in der Praxis genau dann ab, wenn
        // die Track-Maske ohnehin dünn war (User: „kein zusammenhängender
        // Lauf"). Quellen UNTER dem Boden propagieren weiterhin nicht — sonst
        // würde die Klemme isolierten Speckle zu langen Fäden verstärken.
        // 1 Zelle breit; Breite macht weiterhin nur die (schwellen-gestufte)
        // Dilatation darunter.
        for start in 0..<(n * n) where sd[start] > WaterRender.continuityFloor {
            var val = max(sd[start] - WaterRender.continuityDecayPerCell,
                          WaterRender.continuityFloor)
            var r = rec[start]
            while r >= 0 {
                let ri = Int(r)
                if sd[ri] >= val { break }   // Kette ab hier schon (stärker) gemalt
                // Offenes Wasser erreicht: ab hier malen See-Kanal bzw. Meer.
                if h[ri] <= sea || hf[ri] - h[ri] > WaterRender.lakeRawWetDepth { break }
                sd[ri] = val
                val = max(val - WaterRender.continuityDecayPerCell,
                          WaterRender.continuityFloor)
                r = rec[ri]
            }
        }
        let barTol = WaterRender.widenBarTolerance
        // NUR kräftige Läufe verbreitern (kein Alle-Läufe-Pass mehr): Bäche bleiben
        // fadendünn (1 Zelle), Hauptflüsse verlieren ~1 Zelle Breite — die Breiten-
        // Hierarchie bleibt, ihr Absolutniveau sinkt (User: „proportional zu dick";
        // die alte Kalibrierung stammt von der kleineren 640er-Map).
        // Die Bank-Toleranz gilt SYMMETRISCH (|Bett − Nachbar-Spiegel| < barTol):
        // einseitig („nicht nennenswert DARÜBER") durfte sich Wasser bergab
        // unbegrenzt verbreitern — an Steilwänden liegt jede Zelle unter dem
        // Spiegel des Laufs darüber, die Dilatation fächerte hangabwärts als
        // Dreiecks-Federn aus, und das gröbere Render-Gitter streckt genau
        // diese Zellen zu großen Splittern (User-Screenshot Jahr 0, steile
        // Canyons). Physisch steht Wasser nie an einer Wand UNTER dem Fluss;
        // auf Ebenen ändert die zweite Schranke nichts (Differenzen ≪ barTol).
        let widenThresh = WaterRender.widenThresholds
        let widenFalloff = WaterRender.widenFalloff
        for thresh in widenThresh {
            // Liest sd/h/hf, schreibt nur b[k] → zeilenparallel, bit-identisch.
            sd.withUnsafeBufferPointer { sdb in
            b.withUnsafeMutableBufferPointer { bb in
            h.withUnsafeBufferPointer { hb in hf.withUnsafeBufferPointer { hfb in
                let psd = sdb.baseAddress!, pb = bb.baseAddress!
                let ph = hb.baseAddress!, phf = hfb.baseAddress!
                parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<n {
                        let k = j * n + i
                        var m = psd[k]
                        if i > 0 && psd[k - 1] > thresh && abs(ph[k] - phf[k - 1]) < barTol { m = max(m, psd[k - 1] - widenFalloff) }
                        if i < n - 1 && psd[k + 1] > thresh && abs(ph[k] - phf[k + 1]) < barTol { m = max(m, psd[k + 1] - widenFalloff) }
                        if j > 0 && psd[k - n] > thresh && abs(ph[k] - phf[k - n]) < barTol { m = max(m, psd[k - n] - widenFalloff) }
                        if j < n - 1 && psd[k + n] > thresh && abs(ph[k] - phf[k + n]) < barTol { m = max(m, psd[k + n] - widenFalloff) }
                        pb[k] = m
                    }
                }
                }
            }}}}
            swap(&sd, &b)
        }

        // DIREKT-RENDERING der Mäander-Entitäten: die persistenten Zentrumslinien und
        // Altarme werden GARANTIERT ins Feld gestempelt — unabhängig davon, ob die
        // D8-Drainage dem gecarvten sinuosen Bett folgt. Erst so werden „Arme, die
        // sich schlängeln und als Altarm-Seen abschnüren" wirklich sichtbar (der
        // Mäander IST die Fluss-Entität, nicht ein Nebenprodukt der D8-Karte).
        mdx.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        mdz.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        mstamp.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        capStamp.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        oxb.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) } // Altarm-See-Overlay (mit Alter ausgeblendet)
        let noMeanderPaint = ProcessInfo.processInfo.environment["RS_NO_MEANDER_PAINT"] != nil // Debug-Schalter
        // GEOMETRIE-MODUS (Issue #31, seit #34 Standard): das Wasser der Mäander
        // rendert die Band-Geometrie (riverRibbon*-Puffer), NICHT mehr dieses Feld.
        // Der Korridor wird trotzdem gestempelt — aber nur mit SAUM-Intensität:
        // unter der Wasser-Schwelle des Terrain-Shaders (`riverMaskLo`, derselbe
        // Wert ist unten die Kohärenz-Schwelle der Komponenten-Maske), über seiner
        // Ufer-Schwelle (`shoreLo`). Beide Schwellen und der Halo stehen zusammen
        // in `WaterRender`, damit man sie nicht einzeln verschieben kann.
        // Das Ribbon liegt so in einem weichen Nass-Halo aus dem bestehenden
        // Ufer-Saum — adressiert die dokumentierte Rückbau-Ursache von f3556c8
        // („harte Kanten am Ribbon↔Ufer-Übergang").
        let haloIntensity = WaterRender.ribbonHaloIntensity
        // Stempelt einen Korridor (Saum oder voller Lauf) um eine Rasterposition.
        // Als lokale Funktion, weil sie sd/mstamp/mdx/mdz schreibt — dieselbe
        // Scheibe wie die Segment-Schleife darunter. `capToHalo` markiert die
        // Zellen für den Raster-Deckel unten: nur unter einem ECHTEN Band darf
        // das D8-Feld auf Saum-Intensität gedrückt werden.
        func stampCorridor(cx: Int, cy: Int, rad: Int, intens: Double,
                           dirX: Double, dirZ: Double, capToHalo: Bool) {
            let jLo = max(0, cy - rad), jHi = min(n - 1, cy + rad)
            let iLo = max(0, cx - rad), iHi = min(n - 1, cx + rad)
            if jLo > jHi || iLo > iHi { return }
            for jj in jLo...jHi {
                for ii in iLo...iHi {
                    let dd = (ii - cx) * (ii - cx) + (jj - cy) * (jj - cy)
                    if dd > rad * rad { continue }
                    let kk = jj * n + ii
                    // Nicht unter die Meeresoberfläche stempeln (Issue #34).
                    // Dort ist `pond` per Definition 0 (Priority-Flood füllt das
                    // Meer nicht auf), der Ufer-Saum des Shaders also voll
                    // eingeschaltet: der Korridor malte eine HELLE Sandplatte auf
                    // den Meeresgrund, die unter der durchscheinenden
                    // Wasser-Ebene als rechteckiger Ausleger vor jeder Mündung
                    // stand (im A/B-Screenshot gefunden). Der Abfluss-Stempel
                    // selbst hält sich schon ans Land (`ph[k] > sea`).
                    if h[kk] <= sea { continue }
                    // Intensität mit der Stream-Map gewichten: wo dem gestempelten
                    // Bett real kein Wasser folgt (verwaiste/verknäulte Linien),
                    // verblasst der Stempel, statt voll zu leuchten.
                    let mM = WaterRender.corridorMask(streamMap: smap[kk])
                    let iM = intens * WaterRender.corridorWeight(mask: mM)
                    if sd[kk] < iM { sd[kk] = iM }
                    mstamp[kk] = true; mdx[kk] = dirX; mdz[kk] = dirZ
                    if capToHalo { capStamp[kk] = true }
                }
            }
        }
        for (chIndex, ch) in (noMeanderPaint ? [] : terrain.meander.channels).enumerated() {
            let nodes = ch.nodes
            if nodes.count < 2 { continue }
            // Korridor nur unter einem ECHTEN Band (Bau-Ergebnis des letzten
            // Ribbon-Builds, s. Doc-Kommentar von `bytes`): Saum + Raster-Deckel.
            // Kanäle OHNE Band werden hier GAR NICHT gestempelt — ihr Wasser
            // malt das D8/MFD-Raster oben mit derselben Track-Masken-Disziplin
            // wie die dendritischen Zubringer. Ein voller Legacy-Stempel wäre
            // die falsche Alternative: sein `corridorWeight`-Boden (0.3 × 0.6 =
            // 0.18) liegt ÜBER der Wasser-Schwelle 0.16 und malte in frischen
            // Welten (Stream-Map leer) jede getrasste Linie als blaue Splitter
            // in die Canyonwände. Fallback für die Frames zwischen einer
            // Struktur-Änderung der Kanalliste und dem (auf 1 Hz gedeckelten)
            // Rebuild: Saum wie bisher — der nächste Build korrigiert.
            let hasBand = geometryMode
                && (chIndex < bandChannelFlags.count ? bandChannelFlags[chIndex] : true)
            if geometryMode && !hasBand { continue }
            for i in 0..<(nodes.count - 1) {
                let ax = nodes[i].x, az = nodes[i].z, bx = nodes[i + 1].x, bz = nodes[i + 1].z
                let q = 0.5 * (ch.discharge[i] + ch.discharge[i + 1])   // Abfluss (Zellen) am Segment
                // Render-Gate wie beim Abfluss-Feld: Mäander-ENTITÄTEN existieren ab
                // meanderMinCells (85) und migrieren weiter, GEMALT werden Segmente
                // erst ab der Render-Schwelle — sonst stempeln hunderte Mini-Läufe
                // an renderMinCells vorbei (User: „zu viele Flüsse").
                if q < creek { continue }
                // Halbbreite ∝ log(Abfluss) mit 1-Zellen-Deckel (Stempel-Modus)
                // bzw. Ribbon-Halbbreite + Rand (Geometrie-Modus, damit der Halo
                // das Band ganz umfasst). Beide Kurven stehen in `WaterRender`.
                let hw = hasBand
                    ? ribbonHalfWidthCells(q, cfg: terrain.cfg) + WaterRender.ribbonHaloMarginCells
                    : WaterRender.stampHalfWidthCells(dischargeCells: q, creekCells: creek)
                let rad = Int(hw.rounded())
                let intens = hasBand ? haloIntensity
                    : WaterRender.stampIntensity(dischargeCells: q, creekCells: creek)
                var tx = bx - ax, tz = bz - az
                let tl = (tx * tx + tz * tz).squareRoot(); if tl > 1e-6 { tx /= tl; tz /= tl }
                let steps = max(1, Int(tl.rounded()))
                for s in 0...steps {
                    let t = Double(s) / Double(steps)
                    let cx = Int((ax + (bx - ax) * t).rounded()), cy = Int((az + (bz - az) * t).rounded())
                    stampCorridor(cx: cx, cy: cy, rad: rad, intens: intens,
                                  dirX: tx, dirZ: tz, capToHalo: hasBand)
                }
            }
            // MÜNDUNGS-KORRIDOR (Issue #34): unter einem echten Band läuft es
            // über die Zentrumslinie hinaus bis in die Wasserfläche. Ohne den
            // Saum-Stempel auf demselben Stück malte das D8-Raster dort unter
            // dem Band die sprenklige Textur-Version des Laufs. Ohne Band gibt
            // es nichts zu überlappen — der Stempel endet wie vor #34.
            if hasBand {
                let last = nodes[nodes.count - 1]
                let q = ch.discharge[nodes.count - 1]
                if q >= creek {
                    let rad = Int((ribbonHalfWidthCells(q, cfg: terrain.cfg)
                                   + WaterRender.ribbonHaloMarginCells).rounded())
                    var previousX = last.x, previousZ = last.z
                    for point in mouthPath(terrain, fromX: last.x, fromZ: last.z) {
                        var dirX = point.x - previousX, dirZ = point.z - previousZ
                        let dl = (dirX * dirX + dirZ * dirZ).squareRoot()
                        if dl > 1e-6 { dirX /= dl; dirZ /= dl }
                        stampCorridor(cx: Int(point.x.rounded()), cy: Int(point.z.rounded()),
                                      rad: rad, intens: haloIntensity,
                                      dirX: dirX, dirZ: dirZ, capToHalo: true)
                        previousX = point.x; previousZ = point.z
                    }
                }
            }
        }
        // Altarme (abgeschnürte Schleifen) als See-Overlay — verblassen mit dem Alter.
        // NUR substanzielle Schleifen (≥ 10 Knoten ≈ 15 Zellen Bogen): die Mäander-
        // Migration schnürt auch winzige 2–4-Knoten-Schlingen ab, die als
        // gestreute 3–6-Zell-Blobs die Ebenen sprenkelten („zu viele Flüsse/Seen"-
        // Eindruck) — erst ab dieser Länge liest sich ein Altarm als Altarm. Die
        // Cutoff-Enden liegen per Definition eng beieinander; würden wir sie beide
        // breit stempeln, schlösse sich der Altarm zu einem unnatürlichen Wasserring.
        // Deshalb Hals-Enden trimmen/ausblenden und nur Zellen mit echter Wassersäule
        // markieren: sichtbar bleibt der offene, physisch gefüllte Hufeisenbogen.
        // Filter/Trimmung/Fade sind GEMEINSAME Konstanten mit der Geometrie
        // (`appendOxbowRibbons`) — beide Pfade müssen dieselben Schleifen meinen.
        let minimumOxbowNodes = WaterRender.oxbowMinimumNodes
        let maximumTrimmedNodes = WaterRender.oxbowMaximumTrimmedNodes
        let fullEndFadeSteps = WaterRender.oxbowEndFadeSteps
        // KEINE eigene Tiefen-Rampe mehr (Issue #32): der Shader multipliziert den
        // G-Kanal mit der per-Pixel-Uferkontur smoothstep(pondContourLo,
        // pondContourHi, pond). Eine zweite Rampe hier hätte sie QUADRIERT — frische
        // Altarme verloren so 40–60 % Deckkraft (bei 0.01 Wassersäule: 0,25 → 0,05).
        // Die Kontur macht dasselbe besser: per Pixel statt zell-quantisiert.
        // Gestempelt wird deshalb nur noch PRÄSENZ (echte Wassersäule über dem
        // Kontur-Fuß) mit der Alters-/Rand-Deckkraft; die Ausblendung im seichten
        // Bogen-Ende übernimmt die Kontur. Präsenz-Schwelle == Kontur-Fuß: was der
        // Shader nicht mehr zeichnen kann, muss auch nicht gestempelt werden — und
        // umgekehrt darf der Stempel nicht früher aufhören als die Kontur, sonst
        // fehlen genau die seichten Enden.
        //
        // Seit Issue #34 hat dieses Feld ZWEI Rollen, je nach Modus:
        //  - Geometrie-Modus (Standard): die Altarm-Bänder malen das Wasser
        //    (`appendOxbowRibbons`). `oxb` markiert dann nur noch, WO ein Altarm
        //    liegt, und trägt dort den Nass-Saum ein; ins See-GATE geht es nicht
        //    mehr ein. (Die Abgrenzung zum See-Kanal macht nicht dieses Feld,
        //    sondern die Übergabe im Band selbst: ein Altarm, der tiefer als
        //    `lakeRawWetDepth` gefüllt ist, IST ein kleiner See und wird auch als
        //    solcher gerendert — s. `lakeHandoverFade`.)
        //  - Stempel-Modus (`RS_WATER_STAMP`, Legacy-A/B): unverändert das
        //    See-Overlay von vor #34.
        let minimumPondDepth = WaterRender.pondContourLo
        let maximumOxbowOpacity = WaterRender.oxbowMaximumOpacity
        for oxbowIndex in terrain.meander.oxbows.indices {
            let oxbow = terrain.meander.oxbows[oxbowIndex]
            if oxbow.count < minimumOxbowNodes { continue }
            let age = oxbowIndex < terrain.meander.oxbowAge.count
                ? terrain.meander.oxbowAge[oxbowIndex]
                : 0
            let fade = max(0, 1 - age / WaterRender.oxbowVisibleYears)
            if fade <= 0 { continue }
            let trim = min(maximumTrimmedNodes, max(1, oxbow.count / 8))
            let first = trim, last = oxbow.count - trim - 1
            if first > last { continue }
            for nodeIndex in first...last {
                let node = oxbow[nodeIndex]
                let edgeSteps = min(nodeIndex - first, last - nodeIndex)
                let endFade = min(1, Double(edgeSteps + 1) / fullEndFadeSteps)
                let centerX = Int(node.x.rounded()), centerY = Int(node.z.rounded())
                for (offsetX, offsetY) in [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let neighborX = centerX + offsetX, neighborY = centerY + offsetY
                    if neighborX < 0 || neighborX >= n || neighborY < 0 || neighborY >= n {
                        continue
                    }
                    let cellIndex = neighborY * n + neighborX
                    let pondDepth = hf[cellIndex] - h[cellIndex]
                    if hf[cellIndex] <= sea || h[cellIndex] <= sea || pondDepth <= minimumPondDepth {
                        continue
                    }
                    let value = maximumOxbowOpacity * fade * endFade
                    if oxb[cellIndex] < value { oxb[cellIndex] = value }
                }
            }
        }

        // See-Feld (substanzielle Seen, Tiefe > 0.03 — seichte Flutungs-Pfützen
        // NICHT malen, User: „zu viele Seen") + Altarm-Overlay.
        // KOHÄRENZ-FILTER über Fluss- UND See-Zellen GEMEINSAM: die rauen Braid-
        // Ebenen tragen tausende isolierte Wasser-Fetzen (Pfützen-Cluster +
        // Stream-Map-Patches, seit die Track-Maske Zufallspfade strenger schneidet),
        // die als blaue Punktfelder dithern („zu viele Flüsse/Seen"-Eindruck im
        // gealterten Terrain). Zusammenhängende Wasser-Komponenten (4er-Nachbar-
        // schaft) unter `componentFadeLoCells` bleiben unsichtbar, bis
        // `componentFadeHiCells` steigt die Deckkraft linear (Issue #32: FADE statt
        // hartem Cutoff bei 25 — beim Überschreiten PLOPPTEN wachsende Seen).
        // Echte Flüsse sind dank der Downstream-Propagation LANGE Ketten bis See/Meer,
        // echte Seen große Flächen — beide liegen weit über dem Fenster. Zubringer,
        // die in einen See münden, überleben über die gemeinsame Komponente.
        // Flood-Fill ist O(n²) und läuft eh nur je Render-Tick. Altarme separat
        // via oxb.
        // Der Fade wirkt auf die beiden Kanäle VERSCHIEDEN: der See-Kanal blendet
        // weich ein (dort lag die Ploppe), der Fluss-Kanal wird nur GEGATET —
        // Herleitung und Fenster in `WaterRender`, headless abgesichert durch
        // `SimCoreTests/WaterRenderTests.swift`.
        rawWet.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        // EIN Durchlauf für drei Dinge, die alle vor der Kohärenz-Maske stehen
        // müssen (jede eigene Vollbild-Schleife kostete hier messbar Frames:
        // die Wasseraufbereitung läuft in JEDEM Textur-Update):
        //  1. `rawWet` — Schwelle == `WaterRender.lakeRawWetDepth` (0.03,
        //     unverändert): sie ist seit #34 zugleich die Delta-FRONT der
        //     Geometrie — der Fächer malt den Apron davor, der See-Kanal die
        //     Fläche dahinter.
        //  2. Korridor-Deckel (Geometrie-Modus): unter einem ECHTEN Band darf
        //     auch das D8-Abflussfeld nur Saum-Intensität tragen — die
        //     D8-Drainage folgt dem gecarvten Bett und würde sonst die
        //     „sprenklige" Textur-Version UNTER dem Band rendern. Der Deckel
        //     gilt nur für `capStamp`-Zellen (Band- und Altarm-Korridore):
        //     Kanäle OHNE Band (Strahler-/Kohärenz-Gate) stempeln keinen
        //     Korridor, und ihr D8-Raster-Wasser zu deckeln hieße Saum ohne
        //     Wasser darin.
        //  3. Altarm-Saum (Geometrie-Modus): Altarme malt dort das BAND, aber nur
        //     im Flachwasser (s. `lakeHandoverFade`). Ein Altarm, der tief genug
        //     gefüllt ist, dass der See-Kanal ihn malen kann, IST ein kleiner See
        //     und wird auch so behandelt (Uferkontur + Komponenten-Fade aus #32).
        //     `rawWet` bleibt deshalb unangetastet — eine Ausnahme hier würde
        //     genau die tiefen, ISOLIERT liegenden Altarme unsichtbar machen.
        //     Was das Feld beisteuert, ist der Nass-Saum um den Bogen: derselbe
        //     Halo wie unter den Fluss-Bändern, damit auch ein Altarm ein Ufer
        //     hat statt einer Farbkante.
        for k in 0..<cnt {
            rawWet[k] = hf[k] > sea && hf[k] - h[k] > WaterRender.lakeRawWetDepth
            if geometryMode {
                if oxb[k] > 0 {
                    // Altarm-Korridor: das Band malt sicher (Raster und
                    // Geometrie teilen die Altarm-Filter, s. o.) → deckeln.
                    if sd[k] < haloIntensity { sd[k] = haloIntensity }
                    mstamp[k] = true
                    capStamp[k] = true
                }
                // Deckung des Bands an DIESER Zelle (echtes Bau-Ergebnis,
                // s. RiverRibbonRenderer.bandCoverage). Fehlt das Feld (erster
                // Frame vor dem ersten Ribbon-Build), gilt wie früher „voll".
                let cover = k < bandCoverage.count ? bandCoverage[k] : 1.0
                if capStamp[k] && sd[k] > haloIntensity {
                    // Kaskaden-Zellen behalten ihr Raster-Wasser: dort blendet
                    // das BAND über dieselbe Funktion aus (s.
                    // WaterRender.cascadeWeight) — deckelte man sie trotzdem,
                    // hätte die Steilstrecke weder Band noch Raster. Neigung
                    // als MAX-Gefälle zur 8er-Nachbarschaft: die ebenen
                    // STUFENBECKEN inmitten einer Kaskade zählen so mit
                    // (spiegelbildlich zur ±2-Zellen-Dilatation der Band-Seite).
                    var maxSlope = 0.0
                    let ki = k % n, kj = k / n
                    for dj in -1...1 {
                        for di in -1...1 where di != 0 || dj != 0 {
                            let ni = ki + di, nj = kj + dj
                            if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                            let dist = (di * di + dj * dj == 2)
                                ? cellDiagonal : terrain.cfg.cellSize
                            maxSlope = max(maxSlope,
                                           abs(h[k] - h[nj * n + ni]) / dist)
                        }
                    }
                    if WaterRender.cascadeWeight(slope: maxSlope) < 0.5 {
                        // ANTEILIG statt binär: nur so weit zurücknehmen, wie
                        // das Band an dieser Stelle wirklich deckt. Wo sein
                        // Alpha ausläuft (Enden-Taper, Abfluss-Rampe,
                        // Kohärenz), behält das Raster sein Wasser — sonst
                        // reißt der Lauf dort ab, wo beide Pfade schweigen.
                        sd[k] += (haloIntensity - sd[k]) * cover
                    }
                }
            }
            // Kohärenz-Maske über die Wasser-Schwelle des Shaders: was er als
            // Fluss malen WÜRDE, zählt für die Komponente.
            mask[k] = rawWet[k] || sd[k] >= WaterRender.riverMaskLo
        }
        componentFade.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        seen.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        waterComponent.removeAll(keepingCapacity: true)
        waterStack.removeAll(keepingCapacity: true)
        for start in 0..<cnt where mask[start] && !seen[start] {
            waterComponent.removeAll(keepingCapacity: true)
            waterStack.removeAll(keepingCapacity: true)
            waterStack.append(start); seen[start] = true
            while let k = waterStack.popLast() {
                waterComponent.append(k)
                let i = k % n, j = k / n
                if i > 0 && mask[k - 1] && !seen[k - 1] { seen[k - 1] = true; waterStack.append(k - 1) }
                if i < n - 1 && mask[k + 1] && !seen[k + 1] { seen[k + 1] = true; waterStack.append(k + 1) }
                if j > 0 && mask[k - n] && !seen[k - n] { seen[k - n] = true; waterStack.append(k - n) }
                if j < n - 1 && mask[k + n] && !seen[k + n] { seen[k + n] = true; waterStack.append(k + n) }
            }
            // Verschmelzen zweier Komponenten kann `fade` in einem Tick springen
            // (Teich berührt Flusskette) — im Zeitraffer dämpft das die EWMA
            // unten, bei Sprüngen (blend = 1) ist Sofort-Übernahme gewollt.
            let fade = WaterRender.componentFade(cells: waterComponent.count)
            if fade > 0 {
                for k in waterComponent { componentFade[k] = fade }
            }
        }
        // G-Kanal = See-GATE statt Tiefen-Rampe (Issue #32): WO ein See sichtbar
        // ist (inkl. Komponenten-Fade), sagt dieses Feld — die FORM der Uferlinie
        // und die Tiefe fürs Shading rechnet der Shader per Pixel aus
        // waterLevel − h (volle Sim-Auflösung, bilinear). Ein zell-binär
        // geschwelltes Tiefenfeld kann nach Blur + Smoothstep nur Zell-Treppen
        // liefern; das Gate darf grob sein, die pond-Kontur schneidet es
        // pixelgenau zu.
        lk.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        for k in 0..<cnt {
            // Fluss-Kanal: GATE, kein weicher Fade. Der Shader liest ihn als
            // Intensität, und sein Unter-Wasser-Bereich IST das Saum-Fenster —
            // ein skalierter voller Lauf (stream 0.15) malt sandbraunen Saum ohne
            // Wasser darin. `WaterRender.streamGate` schaltet erst ab der Fade-
            // Höhe, bei der ein voller Lauf schon deckt (28 Zellen).
            // Der Ribbon-Saum (WaterRender.ribbonHaloIntensity) ist davon
            // ausgenommen: Korridor-Zellen sind per Definition Teil eines echten
            // Laufs (Zentrumslinie), nicht Speckle (Issue #31).
            if !(geometryMode && mstamp[k]) {
                sd[k] *= WaterRender.streamGate(componentFade: componentFade[k])
            }
            // See-Kanal: weicher Fade (Issue #32) — und NICHT vom Korridor
            // ausgenommen, ein Ribbon-Korridor darf keine Kleinst-Pfütze als See
            // malen.
            if rawWet[k] { lk[k] = componentFade[k] }
            // Altarm-Overlay nur noch im Legacy-Stempel-Modus (Issue #34): im
            // Geometrie-Modus malt das Altarm-BAND, hier bliebe sonst eine
            // zweite, fließend schattierte Kopie derselben Schleife stehen.
            if !geometryMode && oxb[k] > lk[k] { lk[k] = oxb[k] }
        }
        // RÄUMLICH glätten: die Felder sind zell-binär geschwellt (creek/Tiefe) →
        // ohne Glättung wirken Flussränder und Seeufer als Pixel-Grieß. max(Kern,
        // 3×3-Blur) statt reinem Blur: die Kern-Intensität bleibt voll (sonst
        // verblassen dünne Läufe in der Übersicht), nur die Ränder bekommen einen
        // weichen Saum, den der Shader sauber smoothstept.
        func blur3(_ src: [Double], into dst: inout [Double]) {
            // Schreibt nur dst[k] → zeilenparallel, bit-identisch.
            src.withUnsafeBufferPointer { sb in
            dst.withUnsafeMutableBufferPointer { db in
                let ps = sb.baseAddress!, pd = db.baseAddress!
                parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<n {
                        let k = j * n + i
                        var s = 0.0, c = 0.0
                        for dj in max(0, j-1)...min(n-1, j+1) {
                            for di in max(0, i-1)...min(n-1, i+1) {
                                s += ps[dj * n + di]; c += 1
                            }
                        }
                        pd[k] = s / c
                    }
                }
                }
            }}
        }
        // max(Kern, Blur) statt reinem Blur: Kern-Intensität bleibt voll, nur die
        // Ränder bekommen einen weichen Saum.
        func blurMax(_ field: inout [Double], passes: Int) {
            for _ in 0..<passes {
                blur3(field, into: &blur)
                for k in 0..<cnt { field[k] = max(field[k], blur[k]) }
            }
        }
        if deferTail {
            // Nur packen — dieselben vier Kanäle wie unten, aber UNGEBLURT und
            // OHNE EWMA. Die EWMA-Felder (sdS…) bleiben unangetastet: schaltet
            // man per RS_WATER_GPU zurück, blendet der CPU-Pfad aus seinem
            // eigenen Gedächtnis weiter.
            //
            // 8 Bit sind hier kein Verlust gegenüber der CPU-Fassung: die
            // quantisiert am Ende genauso. Nur der EWMA-ZUSTAND braucht mehr
            // Auflösung, und der liegt GPU-seitig in einem Half-Float-Target
            // (in 8 Bit bliebe die Blende bei kleinem `blend` stehen, weil das
            // Inkrement unter 1/255 rundet).
            out.withUnsafeMutableBufferPointer { ob in
            rec.withUnsafeBufferPointer { rcb in
                let pout = ob.baseAddress!, prec = rcb.baseAddress!
                parallelChunks(cnt) { lo, hi in
                for k in lo..<hi {
                    var dx = 0.0, dz = 0.0
                    if mstamp[k] {
                        dx = mdx[k]; dz = mdz[k]
                    } else {
                        let r = prec[k]
                        if r >= 0 { dx = Double(Int(r) % n - k % n); dz = Double(Int(r) / n - k / n) }
                    }
                    let o = k * 4
                    pout[o] = UInt8(min(max(sd[k], 0), 1) * 255)
                    pout[o + 1] = UInt8(min(max(lk[k], 0), 1) * 255)
                    pout[o + 2] = UInt8((min(max(dx, -1), 1) * 0.5 + 0.5) * 255)
                    pout[o + 3] = UInt8((min(max(dz, -1), 1) * 0.5 + 0.5) * 255)
                }
                }
            }}
            return out
        }

        blurMax(&sd, passes: 1)
        // See-Gate ZWEIMAL bluren: es muss den seichten Ufersaum (Wassersäule
        // unter der rawWet-Schwelle 0.03) überdecken, damit die per-Pixel-Kontur
        // im Shader dort nicht vom Gate abgeschnitten wird — der Überstand aufs
        // Trockene ist unsichtbar, weil pond dort 0 ist.
        blurMax(&lk, passes: 2)

        // EWMA-Puffer bei Bedarf initialisieren (erstes Feld = sofort übernehmen).
        if sdS.count != cnt {
            sdS = [Double](repeating: 0, count: cnt)
            lakeS = [Double](repeating: 0, count: cnt)
            dxS = [Double](repeating: 0, count: cnt)
            dzS = [Double](repeating: 0, count: cnt)
        }
        let bl = min(max(blend, 0), 1) // 1 = Sprung sofort, klein = weiches Blenden

        // Per-Zelle unabhängig (schreibt nur die eigenen EWMA-Felder + 4 Bytes)
        // → parallel, bit-identisch.
        sdS.withUnsafeMutableBufferPointer { s1 in
        lakeS.withUnsafeMutableBufferPointer { s2 in
        dxS.withUnsafeMutableBufferPointer { s3 in
        dzS.withUnsafeMutableBufferPointer { s4 in
        out.withUnsafeMutableBufferPointer { ob in
        rec.withUnsafeBufferPointer { rcb in
            let psdS = s1.baseAddress!, plakeS = s2.baseAddress!
            let pdxS = s3.baseAddress!, pdzS = s4.baseAddress!
            let pout = ob.baseAddress!, prec = rcb.baseAddress!
            parallelChunks(cnt) { lo, hi in
            for k in lo..<hi {
                let lake = lk[k]
                // Richtung: gestempelte Mäander-Tangente, sonst rohe D8-Nachbardifferenz
                // (∈ {-1,0,1}; der Shader normalisiert selbst → kein sqrt hier). Wird
                // mitgeglättet, damit die Strömungsrichtung nicht schlagartig kippt.
                var dx = 0.0, dz = 0.0
                if mstamp[k] {
                    dx = mdx[k]; dz = mdz[k]
                } else {
                    let r = prec[k]
                    if r >= 0 { dx = Double(Int(r) % n - k % n); dz = Double(Int(r) / n - k / n) }
                }
                // EWMA: geglättetes Feld Richtung frischem Wert ziehen (Gedächtnis über Rebuilds).
                psdS[k]   += bl * (sd[k] - psdS[k])
                plakeS[k] += bl * (lake  - plakeS[k])
                pdxS[k]   += bl * (dx    - pdxS[k])
                pdzS[k]   += bl * (dz    - pdzS[k])
                let o = k * 4
                pout[o] = UInt8(min(max(psdS[k], 0), 1) * 255)
                pout[o + 1] = UInt8(min(max(plakeS[k], 0), 1) * 255)
                pout[o + 2] = UInt8((min(max(pdxS[k], -1), 1) * 0.5 + 0.5) * 255)
                pout[o + 3] = UInt8((min(max(pdzS[k], -1), 1) * 0.5 + 0.5) * 255)
            }
            }
        }}}}}}
        // Der Byte-Puffer bleibt über den `defer`-Rücktausch im Renderer und
        // wird über Render-Ticks wiederverwendet; `[UInt8]` teilt ihn per CoW.
        return out
    }
}

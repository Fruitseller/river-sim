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

    /// A/B-Arm der Verbreiterung (Issue #174): `true` = die alte Diamant-
    /// Dilatation (zwei Pässe), `false` = Scheibenstempel (Standard). Nur für
    /// Messläufe und Wächter, die beide Fassungen im selben Build vergleichen
    /// (`RectWaterTests`); der Betrieb läuft immer auf dem Standard.
    var legacyWiden = ProcessInfo.processInfo.environment["RS_WIDEN_DIAMOND"] != nil

    /// Baut die Diagnose-Meldung für einen Feldgrößen-Mismatch (Bug: Feld-Korruption).
    /// Bewusst REIN (kein Trap, keine Assertion): Der Mismatch-Pfad ist unter
    /// `swift test` (Debug-Build) sonst nicht testbar — ein Guard mit `assertionFailure`
    /// würde den Test-Runner mitten im Frame trappen. Nur `internal` (Tests kommen
    /// über `@testable` herein): reines Diagnose-Format für einen Pfad, der im
    /// Betrieb eigentlich nie erreicht wird.
    static func fieldSizeMismatchDetail(n: Int, cnt: Int,
                                        fieldCounts: [(name: String, count: Int)]) -> String? {
        guard fieldCounts.contains(where: { $0.count != cnt }) else { return nil }
        let fields = fieldCounts.map { "\($0.name)=\($0.count)" }.joined(separator: ", ")
        return "Feldgrößen-Mismatch: n=\(n), cnt=\(cnt), \(fields)"
    }

    /// Prüft die Feldgrößen der direkt gelesenen Felder gegen `cnt`, um
    /// Out-of-Bounds-Zugriffe und Traps auf 0-zähligen Pufferzeigern sicher
    /// auszuschließen. Rückgabe nil = alle stimmig, sonst die Diagnose-Meldung
    /// aus `fieldSizeMismatchDetail`.
    ///
    /// Die Entscheidung steht HIER an EINER Stelle, weil sie beide Guards
    /// (`flowDetailField` und `bytes`) betrifft: DEBUG bricht bewusst LAUT ab
    /// (`assertionFailure` ist genau dort aktiv); der RELEASE-Pfad liefert still
    /// einen leeren Puffer zurück statt laut zu scheitern (preconditionFailure) —
    /// dieser Code läuft pro Textur-Update im Render-Pfad (Godot/GDExtension),
    /// und ein harter Crash mitten im Frame ist dort ein größerer Schaden als
    /// ein leeres Render-Ergebnis.
    private static func validateFields(n: Int, cnt: Int,
                                       fields: [(name: String, count: Int)]) -> String? {
        fieldSizeMismatchDetail(n: n, cnt: cnt, fieldCounts: fields)
    }



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
    private var waterCapped: [Bool] = []
    private var waterOxbow: [Double] = []
    private var waterBytes: [UInt8] = []
    private var waterComponent: [Int] = []
    private var waterStack: [Int] = []
    /// Abfluss der sichtbaren Bänder je Zentrumslinien-Zelle — für die
    /// Bank-Schranke des Raster-Flusses (`WaterRender.rasterBarBandReachCells`).
    private var waterBandQ: [Double] = []
    /// Wo die Kontinuitäts-Kette an einem Tümpel-Rand endete (Zelle und
    /// Intensität dort) — für die Fortsetzung durch nasse Wiese.
    private var waterPondEntries: [(cell: Int, value: Double)] = []
    /// Nasse Wiese (Issue #174, Paket C) des letzten `bytes`-Laufs: Zellen
    /// kleiner See-Komponenten, die das Raster NICHT als Wasser malt
    /// (`WaterRender.isWetMeadow`). `RenderState` reicht die Maske an
    /// Material und Schutzmaske weiter; leer bis zum ersten Lauf.
    public private(set) var wetMeadow: [Bool] = []
    /// Kennzahlen der Tümpel (See-Komponenten) des letzten Laufs — nur für die
    /// Messreihe (`RiverCoastRenderTests`), kein Render-Zustand.
    struct ComponentStat {
        /// Zellen des Tümpels (stehendes Wasser, 4er-Nachbarschaft).
        let cells: Int
        /// Hängt an einem Band-/Altarm-Korridor.
        let banded: Bool
        /// Vor #174 sichtbar (Komponenten-Fade der Wasser-Komponente > 0).
        let visible: Bool
    }
    private(set) var componentStats: [ComponentStat] = []
    /// Größen der Rest-Flecken am Band, die der letzte Lauf zurückgenommen hat.
    private(set) var remnantStats: [Int] = []
    // Persistenter Ausgabepuffer des Abfluss-Felds fürs Shader-Detail (R8).
    private var flowDetail: [UInt8] = []

    /// R8-Feld (n×n) der log-normierten MFD-Abflussdichte unterhalb der
    /// Sichtbarkeits-Schwelle des Wassers — moduliert im Terrain-Shader die
    /// Stärke der kosmetischen Erosionsrinnen (`flow_tex`), damit sie sich in
    /// echten Abflussbahnen bündeln statt als uniformes Muster zu wiederholen.
    /// Kalibrierung und Begründung: `WaterRender.flowDetailIntensity` ff.
    /// Per-Zelle unabhängig → parallel, bit-identisch zur sequenziellen Schleife.
    public func flowDetailField(_ terrain: Terrain) -> [UInt8] {
        let n = terrain.cfg.n
        // n == 0 ist der etablierte Vertrag für leere Texturen (vgl. #122, #123).
        guard n > 0 else { return [] }
        let cnt = n * n
        let h = terrain.h, area = terrain.areaMFD
        // Begründung der Entscheidung (Debug laut / Release still `[]`) steht am
        // gemeinsamen Helfer `validateFields` — EINE Stelle statt driftender
        // Doppel-Pflege. Der Guard selbst würde unter `swift test` (Debug) den
        // Runner trappen, die Diagnose ist deshalb über den trap-freien Helfer
        // `fieldSizeMismatchDetail` headless testbar.
        if let mismatch = Self.validateFields(
            n: n, cnt: cnt, fields: [("h", h.count), ("areaMFD", area.count)]) {
            assertionFailure(mismatch)
            return []
        }
        let sea = terrain.cfg.sea
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        let creek = terrain.cfg.renderMinCells
        if flowDetail.count != cnt { flowDetail = [UInt8](repeating: 0, count: cnt) }
        var out: [UInt8] = []; swap(&out, &flowDetail)
        defer { swap(&out, &flowDetail) }
        // cellSize 0 (keine definierte Schrittweite): kein Detail-Overlay ohne Zellfläche,
        // sonst pa[k] / 0 = inf und fehlerhafte Vollaussteuerung 255 auf allen Landzellen.
        guard cellArea > 0, cellArea.isFinite else {
            out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
            return out
        }
        out.withUnsafeMutableBufferPointer { ob in
        h.withUnsafeBufferPointer { hb in area.withUnsafeBufferPointer { ab in
            let po = ob.baseAddress!, ph = hb.baseAddress!, pa = ab.baseAddress!
            parallelChunks(cnt) { lo, hi in
                for k in lo..<hi {
                    guard ph[k] > sea else { po[k] = 0; continue }
                    let v = WaterRender.flowDetailIntensity(
                        dischargeCells: pa[k] / cellArea, creekCells: creek)
                    po[k] = UInt8(v * 255.0 + 0.5)
                }
            }
        }}}
        return out
    }

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
        // n == 0 ist der etablierte Vertrag für leere Texturen (vgl. #122, #123).
        guard n > 0 else { return [] }
        let cnt = n * n
        let h = terrain.h, hf = terrain.waterLevel, area = terrain.areaMFD, rec = terrain.receiver
        // Derselbe gemeinsame Helfer wie in `flowDetailField` (Begründung und
        // Diagnose an EINER Stelle, s. dort).
        if let mismatch = Self.validateFields(
            n: n, cnt: cnt,
            fields: [("h", h.count), ("waterLevel", hf.count),
                     ("areaMFD", area.count), ("receiver", rec.count),
                     ("streamMap", terrain.streamMap.count)]) {
            assertionFailure(mismatch)
            return []
        }
        let sea = terrain.cfg.sea
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        let creek = terrain.cfg.renderMinCells // Render-Schwelle sichtbarer Läufe — ENTKOPPELT vom Braid-Physik-Gate (braidMinCells): 30→120→280 erhöht (User: „zu viele Flüsse"), die Braiding-Physik behält ihr eigenes Gate. Die Mäander-Hauptläufe kommen ohnehin direkt aus den Zentrumslinien.
        // areaMFD (Multi-Flow): stetige Fluss-Intensität → Läufe gleiten statt zu
        // springen und können sich um Bänke teilen. Erosion nutzt weiter D8-`area`.
        // See-Nässe aus dem ratenbegrenzten Seespiegel statt hf — das Overlay
        // muss zur (ebenfalls waterLevel-gehobenen) See-Geometrie passen und nicht
        // mit jedem hf-Sprung flackern (s. Terrain.waterLevel). Seit Issue #32
        // trägt der G-Kanal das Sichtbarkeits-GATE, keine Tiefe: die Tiefe rechnet
        // der Shader per Pixel aus derselben Wassersäule.

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
            waterCapped = [Bool](repeating: false, count: cnt)
            waterBytes = [UInt8](repeating: 0, count: cnt * 4)
            wetMeadow = [Bool](repeating: false, count: cnt)
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
        var capped: [Bool] = []; swap(&capped, &waterCapped)
        var oxb: [Double] = []; swap(&oxb, &waterOxbow)
        var out: [UInt8] = []; swap(&out, &waterBytes)
        defer {
            swap(&sd, &waterStream); swap(&b, &waterWiden)
            swap(&lk, &waterLake); swap(&blur, &waterBlur)
            swap(&rawWet, &waterRawWet); swap(&mask, &waterMask)
            swap(&componentFade, &waterComponentFade); swap(&seen, &waterSeen)
            swap(&mdx, &waterMDX); swap(&mdz, &waterMDZ)
            swap(&mstamp, &waterStamp); swap(&capStamp, &waterCapStamp)
            swap(&capped, &waterCapped)
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
        // Band in der Nähe (Abfluss-Vertrauen nur in Band-Lücken, s.
        // `WaterRender.ribbonTrustBandClearanceCells`): größte Band-Deckung im
        // Quadrat ±Abstand um jede Zelle, separabel (Zeilen nach `blur`, dann
        // Spalten nach `b`). Beide Puffer sind hier nur Zwischenspeicher: `b`
        // überschreiben die Verbreiterungs-Pässe, `blur` der Rand-Blur, beide
        // vollständig. Ohne gebautes Band (Stempel-Modus, erster Frame) bleibt
        // das Feld 0, das Vertrauen gilt dann überall.
        let clearance = WaterRender.ribbonTrustBandClearanceCells
        let bandNearby = geometryMode && bandCoverage.count == cnt
        b.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        if bandNearby {
            bandCoverage.withUnsafeBufferPointer { cb in
            blur.withUnsafeMutableBufferPointer { rb in
                let pc = cb.baseAddress!, pr = rb.baseAddress!
                parallelChunks(n) { jLo, jHi in
                    for j in jLo..<jHi {
                        for i in 0..<n {
                            var m = 0.0
                            for di in max(0, i - clearance)...min(n - 1, i + clearance) {
                                m = max(m, pc[j * n + di])
                            }
                            pr[j * n + i] = m
                        }
                    }
                }
            }}
            blur.withUnsafeBufferPointer { rb in
            b.withUnsafeMutableBufferPointer { nb in
                let pr = rb.baseAddress!, pn = nb.baseAddress!
                parallelChunks(n) { jLo, jHi in
                    for j in jLo..<jHi {
                        for i in 0..<n {
                            var m = 0.0
                            for dj in max(0, j - clearance)...min(n - 1, j + clearance) {
                                m = max(m, pr[dj * n + i])
                            }
                            pn[j * n + i] = m
                        }
                    }
                }
            }}
        }
        // cellSize 0 (keine definierte Schrittweite): keine Fluss-Intensität ohne Zellfläche,
        // sonst pa[k] / 0 = inf >= creek und fehlerhafte Vollaussteuerung auf allen Stream-Map-Zellen.
        if cellArea > 0, cellArea.isFinite {
            // Per-Zelle unabhängig → parallel (bit-identisch zur sequenziellen Schleife).
            sd.withUnsafeMutableBufferPointer { sdb in
            h.withUnsafeBufferPointer { hb in hf.withUnsafeBufferPointer { hfb in
            area.withUnsafeBufferPointer { ab in smap.withUnsafeBufferPointer { smb in
            b.withUnsafeBufferPointer { nb in
                let psd = sdb.baseAddress!, ph = hb.baseAddress!, phf = hfb.baseAddress!
                let pa = ab.baseAddress!, psm = smb.baseAddress!, pnear = nb.baseAddress!
                parallelChunks(cnt) { lo, hi in
                    for k in lo..<hi where phf[k] > sea && ph[k] > sea
                                           && phf[k] - ph[k] <= WaterRender.streamPondTolerance {
                        let cu = pa[k] / cellArea
                        if cu < creek { continue }
                        // Track-Maske und Abfluss-Abstufung stehen im Kalibrier-
                        // Vertrag (`WaterRender`) statt hier und werden zusammen mit
                        // diesem ausführbaren Pfad headless geprüft (Issues #51/#82).
                        // Abfluss-Vertrauen (#174 C2, wie im Band): ein großer
                        // D8-Lauf ist Wasser, auch wo die Stream-Map ihn nicht
                        // trackt — sonst riss der Hauptlauf in der Übersicht ab.
                        // Nur in den LÜCKEN des Bands: wo ein Band in der Nähe
                        // malt, trägt es den Lauf, und das Vertrauen malte die
                        // D8-Treppe als zweites Wasser daneben und darunter.
                        let trust = WaterRender.ribbonTrust(dischargeCells: cu, referenceCells: creek)
                            * (1 - min(1, pnear[k]))
                        let m = max(WaterRender.trackMask(streamMap: psm[k]), trust)
                        if m <= 0 { continue }
                        psd[k] = WaterRender.streamIntensity(dischargeCells: cu, creekCells: creek)
                            * WaterRender.trackWeight(mask: m)
                    }
                }
            }}}}}}
        }
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
        // TÜMPEL-EINTRITT: ob der Tümpel unter der Kette nasse Wiese ist (dann
        // malt der See-Kanal ihn nicht und der Bach hätte dort eine Lücke),
        // steht erst nach den Komponenten unten fest. Die Kette merkt sich
        // deshalb, wo und mit welchem Wert sie am Tümpel-Rand endet, und läuft
        // dort weiter (`pondEntries`, s. nach der nassen Wiese).
        waterPondEntries.removeAll(keepingCapacity: true)
        for start in 0..<(n * n) where sd[start] > WaterRender.continuityFloor {
            var val = max(sd[start] - WaterRender.continuityDecayPerCell,
                          WaterRender.continuityFloor)
            var r = rec[start]
            while r >= 0 && r < cnt {
                let ri = Int(r)
                if sd[ri] >= val { break }   // Kette ab hier schon (stärker) gemalt
                // Offenes Wasser erreicht: ab hier malen See-Kanal bzw. Meer.
                if h[ri] <= sea { break }
                if hf[ri] - h[ri] > WaterRender.lakeRawWetDepth {
                    waterPondEntries.append((cell: ri, value: val))
                    break
                }
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
        if legacyWiden {
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

        } else {
            // Scheibenstempel statt Diamant-Dilatation (Issue #174, „Kästen"):
            // `WaterRender` § „Verbreiterung als Scheibe".
            RiverWidening.widen(sd, into: &b, h: h, hf: hf, receiver: rec, n: n)
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
            // Kanäle mit unvollständigem/nicht-endlichem Abfluss oder extremen Koordinaten
            // überspringen, um OOB-Traps und Double-to-Int-Konvertierungsfehler zu verhindern (analog RiverRibbonRenderer).
            guard ch.discharge.count >= nodes.count else { continue }
            guard !nodes.contains(where: {
                !$0.x.isFinite || !$0.z.isFinite || abs($0.x) > 1e9 || abs($0.z) > 1e9
            }) else { continue }
            guard !ch.discharge.prefix(nodes.count).contains(where: { !$0.isFinite || abs($0) > 1e9 }) else { continue }
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
        // Filter und Trimmung stehen in `oxbowNodeRange`, Fade und Deckkraft in
        // `WaterRender` — GEMEINSAM mit der Geometrie (`appendOxbowRibbons`) und
        // dem Gürtel-Material: alle müssen dieselben Schleifen meinen.
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
            guard let nodeRange = oxbowNodeRange(count: oxbow.count) else { continue }
            let first = nodeRange.lowerBound, last = nodeRange.upperBound
            let age = oxbowIndex < terrain.meander.oxbowAge.count
                ? terrain.meander.oxbowAge[oxbowIndex]
                : 0
            let fade = clamp01(1 - age / WaterRender.oxbowVisibleYears)
            if fade <= 0 { continue }
            for nodeIndex in nodeRange {
                let node = oxbow[nodeIndex]
                guard node.x.isFinite, node.z.isFinite,
                      abs(node.x) < 1e9, abs(node.z) < 1e9 else { continue }
                let edgeSteps = min(nodeIndex - first, last - nodeIndex)
                let endFade = clamp01(Double(edgeSteps + 1) / fullEndFadeSteps)
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
        capped.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
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
        // Bank-Schranke (`WaterRender.rasterBarBandReachCells`): Abfluss der
        // sichtbaren Bänder an ihren Zentrumslinien-Zellen.
        let barAge = terrain.barAge
        let barCheck = geometryMode && bandCoverage.count == cnt && barAge.count == cnt
            && cellArea > 0 && cellArea.isFinite
        if barCheck {
            if waterBandQ.count != cnt { waterBandQ = [Double](repeating: 0, count: cnt) }
            waterBandQ.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
            for (chIndex, ch) in terrain.meander.channels.enumerated()
            where chIndex < bandChannelFlags.count && bandChannelFlags[chIndex] {
                for (i, node) in ch.nodes.enumerated() where i < ch.discharge.count {
                    guard node.x.isFinite, node.z.isFinite, ch.discharge[i].isFinite else { continue }
                    let ci = min(max(Int(node.x.rounded()), 0), n - 1)
                    let cj = min(max(Int(node.z.rounded()), 0), n - 1)
                    let k = cj * n + ci
                    if bandCoverage[k] >= WaterRender.rasterBarBandCoverage {
                        waterBandQ[k] = max(waterBandQ[k], ch.discharge[i])
                    }
                }
            }
        }
        let reach = WaterRender.rasterBarBandReachCells
        let bandQ = waterBandQ   // lokal: die Suche liest es je Kandidat bis zu 33² Mal
        for k in 0..<cnt {
            // Raster-Fluss auf einer Bank neben einem Band, das denselben oder
            // einen größeren Fluss trägt: das ist die D8-Abkürzung über den
            // Gleithang, das Band ist hier der Fluss → nur Saum. Gesucht wird
            // nur für die wenigen Bank-Zellen mit Raster-Fluss (Abbruch beim
            // ersten Treffer); ein Vollbild-Maximumfilter kostete gemessen
            // 2 ms je Aufruf.
            if barCheck && barAge[k] >= 0 && sd[k] > haloIntensity {
                let need = WaterRender.rasterBarBandDischargeRatio * area[k] / cellArea
                let i = k % n, j = k / n
                var found = false
                search: for jj in max(0, j - reach)...min(n - 1, j + reach) {
                    for ii in max(0, i - reach)...min(n - 1, i + reach) where bandQ[jj * n + ii] >= need
                        && bandQ[jj * n + ii] > 0 {
                        found = true; break search
                    }
                }
                if found { sd[k] = haloIntensity }
            }
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
                    // ANTEILIG statt binär: nur so weit zurücknehmen, wie das
                    // Band an dieser Stelle wirklich deckt. Wo sein Alpha
                    // ausläuft (Enden-Taper, Abfluss-Rampe, Kohärenz, und an
                    // KASKADEN über `WaterRender.cascadeWeight`), behält das
                    // Raster sein Wasser — sonst reißt der Lauf dort ab, wo
                    // beide Pfade schweigen.
                    // Bis #174 C2 stand hier zusätzlich eine eigene
                    // Kaskaden-Ausnahme (Max-Gefälle zur 8er-Nachbarschaft,
                    // Raster dann ungedeckelt). Die Deckung trägt die
                    // Kaskaden-Blende des Bands aber schon; die Zell-Neigung
                    // sah dagegen auch das Quergefälle an Talwänden und ließ
                    // das Raster unter einem voll deckenden Band stehen:
                    // doppeltes Wasser in Zellblöcken (Review #181, Messung:
                    // docs/river-belt-render-measurements.md §C).
                    sd[k] += (haloIntensity - sd[k]) * cover
                    // Als Rest-Kandidat zählt nur, wo das Band wirklich trägt
                    // (`remnantMinBandCoverage`). An einer Steilstufe läuft
                    // seine Deckung über kleine Werte gegen 0 aus; dort ist
                    // das Raster die Kaskade, und ein kleines Stück davon
                    // fiele sonst als „Rest-Fleck" auf den Saum zurück.
                    if cover >= WaterRender.remnantMinBandCoverage { capped[k] = true }
                }
            }
            // Kohärenz-Maske über die Wasser-Schwelle des Shaders: was er als
            // Fluss malen WÜRDE, zählt für die Komponente.
            mask[k] = rawWet[k] || sd[k] >= WaterRender.riverMaskLo
        }
        componentFade.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        seen.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        wetMeadow.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        remnantStats.removeAll(keepingCapacity: true)
        waterComponent.removeAll(keepingCapacity: true)
        waterStack.removeAll(keepingCapacity: true)
        for start in 0..<cnt where mask[start] && !seen[start] {
            waterComponent.removeAll(keepingCapacity: true)
            waterStack.removeAll(keepingCapacity: true)
            waterStack.append(start); seen[start] = true
            var allCapped = true
            while let k = waterStack.popLast() {
                waterComponent.append(k)
                // Stehendes Wasser gehört nie zum Rest: ein Mündungs-Korridor
                // reicht in den See, und dessen Fläche malt das Raster.
                if !capped[k] || rawWet[k] { allCapped = false }
                let i = k % n, j = k / n
                if i > 0 && mask[k - 1] && !seen[k - 1] { seen[k - 1] = true; waterStack.append(k - 1) }
                if i < n - 1 && mask[k + 1] && !seen[k + 1] { seen[k + 1] = true; waterStack.append(k + 1) }
                if j > 0 && mask[k - n] && !seen[k - n] { seen[k - n] = true; waterStack.append(k - n) }
                if j < n - 1 && mask[k + n] && !seen[k + n] { seen[k + n] = true; waterStack.append(k + n) }
            }
            // REST-FLECKEN am Band (Issue #174 C): eine kleine Komponente, die
            // NUR aus anteilig gedeckelten Korridor-Zellen besteht (Band deckt
            // dort, aber nicht voll), ist kein eigener Lauf, sondern der
            // Raster-Rest unter einer Bandkante. Korridor-Zellen sind vom
            // Kohärenz-Gate ausgenommen; diese Reste standen deshalb als
            // blaue Flecken neben den Bändern (Messreihe §A: 95 % der
            // sichtbaren Fluss-Fragmente unter 50 Zellen liegen ≤ 2 Zellen
            // an einem Band). Sie fallen auf den Saum zurück und werden
            // nasse Wiese. `capped` heißt: das Band deckt dort mindestens
            // `remnantMinBandCoverage`. Kaskaden-Zellen, an denen das Band
            // ausblendet, erreichen die Schwelle nicht (eine eigene
            // Kaskaden-Ausnahme gibt es seit #174 C2 nicht mehr, s. o.): die
            // Raster-Übergabe an Steilstrecken bleibt unberührt.
            if allCapped && waterComponent.count < WaterRender.wetMeadowMaxCells {
                remnantStats.append(waterComponent.count)
                for k in waterComponent {
                    if sd[k] > haloIntensity { sd[k] = haloIntensity }
                    wetMeadow[k] = true
                }
                continue
            }
            // Verschmelzen zweier Komponenten kann `fade` in einem Tick springen
            // (Teich berührt Flusskette) — im Zeitraffer dämpft das die EWMA
            // unten, bei Sprüngen (blend = 1) ist Sofort-Übernahme gewollt.
            let fade = WaterRender.componentFade(cells: waterComponent.count)
            if fade > 0 {
                for k in waterComponent { componentFade[k] = fade }
            }
        }
        // NASSE WIESE statt Tümpel-Teppich (Issue #174 C): stehendes Wasser
        // (`rawWet`) als EIGENE Komponenten, ohne die Zubringer — ein Tümpel,
        // den ein Bach mit dem Flussnetz verbindet, bleibt ein Tümpel. Kleine
        // Tümpel ohne Band-/Altarm-Korridor malt der See-Kanal nicht; sie
        // gehen als `wetMeadow` an Material und Schutzmaske. Der Korridor
        // liegt mit Saum-Intensität außerhalb von `rawWet` (Mündungs-
        // Korridore reichen dagegen IN den See), deshalb zählt auch der
        // 4er-Nachbar. Die Fluss-Intensität der Zellen bleibt unberührt.
        seen.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        componentStats.removeAll(keepingCapacity: true)
        for start in 0..<cnt where rawWet[start] && !seen[start] {
            waterComponent.removeAll(keepingCapacity: true)
            waterStack.removeAll(keepingCapacity: true)
            waterStack.append(start); seen[start] = true
            var banded = false
            while let k = waterStack.popLast() {
                waterComponent.append(k)
                let i = k % n, j = k / n
                if mstamp[k] || (i > 0 && mstamp[k - 1]) || (i < n - 1 && mstamp[k + 1])
                    || (j > 0 && mstamp[k - n]) || (j < n - 1 && mstamp[k + n]) {
                    banded = true
                }
                if i > 0 && rawWet[k - 1] && !seen[k - 1] { seen[k - 1] = true; waterStack.append(k - 1) }
                if i < n - 1 && rawWet[k + 1] && !seen[k + 1] { seen[k + 1] = true; waterStack.append(k + 1) }
                if j > 0 && rawWet[k - n] && !seen[k - n] { seen[k - n] = true; waterStack.append(k - n) }
                if j < n - 1 && rawWet[k + n] && !seen[k + n] { seen[k + n] = true; waterStack.append(k + n) }
            }
            let visible = waterComponent.contains { componentFade[$0] > 0 }
            componentStats.append(ComponentStat(cells: waterComponent.count,
                                                banded: banded, visible: visible))
            if WaterRender.isWetMeadow(pondCells: waterComponent.count, banded: banded) {
                for k in waterComponent { wetMeadow[k] = true }
            }
        }
        // BACH DURCH NASSE WIESE: die Kontinuitäts-Kette oben endet an jedem
        // Tümpel-Rand, weil dort der See-Kanal übernimmt. Bei nasser Wiese
        // malt er nicht, und der Bach risse an ihr ab (Review #174 C): Fluss-
        // Pass und Kette lassen die Tümpel-Zellen aus, hinter dem Tümpel
        // beginnt der Bach neu. Die Kette läuft deshalb durch die Wiese weiter,
        // mit derselben Regel wie oben (Abfall je Zelle, geklemmt, Ende an
        // einer stärker gemalten Zelle, am Meer oder an einem Tümpel, der
        // Wasser BLEIBT). Der Tümpel selbst bleibt Wiese: es ist ein Faden
        // von einer Zelle, kein See-Gate.
        for entry in waterPondEntries where wetMeadow[entry.cell] {
            var val = entry.value
            var ri = entry.cell
            while sd[ri] < val {
                sd[ri] = val
                val = max(val - WaterRender.continuityDecayPerCell,
                          WaterRender.continuityFloor)
                let r = rec[ri]
                guard r >= 0 && r < cnt else { break }
                ri = Int(r)
                if h[ri] <= sea { break }
                if hf[ri] - h[ri] > WaterRender.lakeRawWetDepth && !wetMeadow[ri] { break }
            }
        }

        // G-Kanal = See-GATE statt Tiefen-Rampe (Issue #32): WO ein See sichtbar
        // ist (inkl. Komponenten-Fade), sagt dieses Feld — die FORM der Uferlinie
        // und die Tiefe fürs Shading rechnet der Shader per Pixel aus
        // waterLevel − h (volle Sim-Auflösung, bilinear). Ein zell-binär
        // geschwelltes Tiefenfeld kann nach Blur + Smoothstep nur Zell-Treppen
        // liefern; das Gate darf grob sein, die pond-Kontur schneidet es
        // pixelgenau zu.
        sd.withUnsafeMutableBufferPointer { sdb in
        lk.withUnsafeMutableBufferPointer { lkb in
        mstamp.withUnsafeBufferPointer { msb in
        componentFade.withUnsafeBufferPointer { cfb in
        rawWet.withUnsafeBufferPointer { rwb in
        wetMeadow.withUnsafeBufferPointer { wmb in
        oxb.withUnsafeBufferPointer { oxbPtr in
            let pwm = wmb.baseAddress!
            let psd = sdb.baseAddress!, plk = lkb.baseAddress!
            let pms = msb.baseAddress!, pcf = cfb.baseAddress!
            let prw = rwb.baseAddress!, pox = oxbPtr.baseAddress!
            plk.update(repeating: 0, count: cnt)
            parallelChunks(cnt) { lo, hi in
                for k in lo..<hi {
                    // Fluss-Kanal: GATE, kein weicher Fade. Der Shader liest ihn als
                    // Intensität, und sein Unter-Wasser-Bereich IST das Saum-Fenster —
                    // ein skalierter voller Lauf (stream 0.15) malt sandbraunen Saum ohne
                    // Wasser darin. `WaterRender.streamGate` schaltet erst ab der Fade-
                    // Höhe, bei der ein voller Lauf schon deckt (28 Zellen).
                    // Der Ribbon-Saum (WaterRender.ribbonHaloIntensity) ist davon
                    // ausgenommen: Korridor-Zellen sind per Definition Teil eines echten
                    // Laufs (Zentrumslinie), nicht Speckle (Issue #31).
                    // Seit #174 gilt die Ausnahme nur für den Saum selbst: was ein
                    // Korridor darüber trägt (D8-Raster neben der Bandkante, wo
                    // das Band nicht deckt), unterliegt dem Gate wie überall —
                    // sonst standen Ein- bis Drei-Zell-Flecken als runde blaue
                    // Punkte mit Uferring neben den Bändern.
                    let gate = WaterRender.streamGate(componentFade: pcf[k])
                    if geometryMode && pms[k] {
                        if gate == 0 && psd[k] > haloIntensity { psd[k] = haloIntensity }
                    } else {
                        psd[k] *= gate
                    }
                    // See-Kanal: weicher Fade (Issue #32) — und NICHT vom Korridor
                    // ausgenommen, ein Ribbon-Korridor darf keine Kleinst-Pfütze als See
                    // malen.
                    if prw[k] && !pwm[k] { plk[k] = pcf[k] }
                    // Altarm-Overlay nur noch im Legacy-Stempel-Modus (Issue #34): im
                    // Geometrie-Modus malt das Altarm-BAND, hier bliebe sonst eine
                    // zweite, fließend schattierte Kopie derselben Schleife stehen.
                    if !geometryMode && pox[k] > plk[k] { plk[k] = pox[k] }
                }
            }
        }}}}}}}
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
                field.withUnsafeMutableBufferPointer { fb in
                blur.withUnsafeBufferPointer { bb in
                    let pf = fb.baseAddress!, pb = bb.baseAddress!
                    parallelChunks(cnt) { lo, hi in
                        for k in lo..<hi { pf[k] = max(pf[k], pb[k]) }
                    }
                }}
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
            sd.withUnsafeBufferPointer { sdb in
            lk.withUnsafeBufferPointer { lkb in
            mstamp.withUnsafeBufferPointer { msb in
            mdx.withUnsafeBufferPointer { mdxb in
            mdz.withUnsafeBufferPointer { mdzb in
                let pout = ob.baseAddress!, prec = rcb.baseAddress!
                let psd = sdb.baseAddress!, plk = lkb.baseAddress!
                let pms = msb.baseAddress!, pmdx = mdxb.baseAddress!, pmdz = mdzb.baseAddress!
                parallelChunks(cnt) { lo, hi in
                for k in lo..<hi {
                    var dx = 0.0, dz = 0.0
                    if pms[k] {
                        dx = pmdx[k]; dz = pmdz[k]
                    } else {
                        let r = prec[k]
                        if r >= 0 && r < cnt { dx = Double(Int(r) % n - k % n); dz = Double(Int(r) / n - k / n) }
                    }
                    let o = k * 4
                    pout[o] = byte01(psd[k])
                    pout[o + 1] = byte01(plk[k])
                    pout[o + 2] = byte01(min(1, max(-1, dx)) * 0.5 + 0.5)
                    pout[o + 3] = byte01(min(1, max(-1, dz)) * 0.5 + 0.5)
                }
                }
            }}}}}}}
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
        let bl = clamp01(blend) // 1 = Sprung sofort, klein = weiches Blenden

        // Per-Zelle unabhängig (schreibt nur die eigenen EWMA-Felder + 4 Bytes)
        // → parallel, bit-identisch.
        sdS.withUnsafeMutableBufferPointer { s1 in
        lakeS.withUnsafeMutableBufferPointer { s2 in
        dxS.withUnsafeMutableBufferPointer { s3 in
        dzS.withUnsafeMutableBufferPointer { s4 in
        out.withUnsafeMutableBufferPointer { ob in
        rec.withUnsafeBufferPointer { rcb in
        sd.withUnsafeBufferPointer { sdb in
        lk.withUnsafeBufferPointer { lkb in
        mstamp.withUnsafeBufferPointer { msb in
        mdx.withUnsafeBufferPointer { mdxb in
        mdz.withUnsafeBufferPointer { mdzb in
            let psdS = s1.baseAddress!, plakeS = s2.baseAddress!
            let pdxS = s3.baseAddress!, pdzS = s4.baseAddress!
            let pout = ob.baseAddress!, prec = rcb.baseAddress!
            let psd = sdb.baseAddress!, plk = lkb.baseAddress!
            let pms = msb.baseAddress!, pmdx = mdxb.baseAddress!, pmdz = mdzb.baseAddress!
            parallelChunks(cnt) { lo, hi in
            for k in lo..<hi {
                let lake = plk[k]
                // Richtung: gestempelte Mäander-Tangente, sonst rohe D8-Nachbardifferenz
                // (∈ {-1,0,1}; der Shader normalisiert selbst → kein sqrt hier). Wird
                // mitgeglättet, damit die Strömungsrichtung nicht schlagartig kippt.
                var dx = 0.0, dz = 0.0
                if pms[k] {
                    dx = pmdx[k]; dz = pmdz[k]
                } else {
                    let r = prec[k]
                    if r >= 0 && r < cnt { dx = Double(Int(r) % n - k % n); dz = Double(Int(r) / n - k / n) }
                }
                // EWMA: geglättetes Feld Richtung frischem Wert ziehen (Gedächtnis über Rebuilds).
                psdS[k]   += bl * (psd[k] - psdS[k])
                plakeS[k] += bl * (lake   - plakeS[k])
                pdxS[k]   += bl * (dx     - pdxS[k])
                pdzS[k]   += bl * (dz     - pdzS[k])
                let o = k * 4
                pout[o] = byte01(psdS[k])
                pout[o + 1] = byte01(plakeS[k])
                pout[o + 2] = byte01(min(1, max(-1, pdxS[k])) * 0.5 + 0.5)
                pout[o + 3] = byte01(min(1, max(-1, pdzS[k])) * 0.5 + 0.5)
            }
            }
        }}}}}}}}}}}
        // Der Byte-Puffer bleibt über den `defer`-Rücktausch im Renderer und
        // wird über Render-Ticks wiederverwendet; `[UInt8]` teilt ihn per CoW.
        return out
    }
}

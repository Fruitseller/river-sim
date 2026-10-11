import Foundation
import SimCore

/// Wie sich das Terrain geändert hat (Argument von `RenderState.invalidate`).
public enum TerrainChange {
    /// Die Sim ist fortgeschritten (`step`): Render-Gedächtnisse laufen weiter.
    case advanced
    /// Pinsel oder Nachzug danach (`sculpt`, `brush`, `recomputeFlow`):
    /// dieselbe Welt, aber kein Gedächtnis darf den alten Stand zeigen.
    case edited
    /// Eine ANDERE Welt (neu generiert oder geladen).
    case replaced
}

/// Der Render-Zustand EINER Welt: die drei zustandstragenden Renderer mit ihren
/// EWMA-Feldern, Arbeitspuffern und Dirty-Snapshots plus die Caches der
/// zustandslosen Pässe `TerrainColorRenderer` (Issue #93), `WaterProtectMask`
/// (Issue #154) und `ForestCanopyMask` (Issue #152).
///
/// Warum als eigener Typ und warum hier: dieser Zustand gehörte bis #93 der
/// GDExtension, obwohl die Brücke laut `AGENTS.md` §Architektur reines
/// Marshalling sein soll. Praktische Folge war, dass die Cache-Invalidierung
/// dort SECHSMAL von Hand stand und Neu-Generieren und Laden zwei verschiedene
/// Politiken fuhren: das Laden verwarf die Dirty-Snapshots ausdrücklich, das
/// Generieren verließ sich auf die Delta-Heuristik. Hier gibt es genau EINEN
/// Einstieg (`invalidate`), und der Unterschied zwischen „dieselbe Welt hat
/// sich geändert" und „es ist eine ANDERE Welt" ist ein benannter Parameter
/// statt zweier Aufrufstellen.
///
/// Wie die Renderer selbst liest der Typ das Terrain und ändert es nie; die
/// Physik bleibt vollständig in `SimCore`. Die WELT reist deshalb als Parameter
/// durch jeden Einstieg und wohnt nicht hier: Besitzer des `Terrain` bleibt die
/// Brücke — #93 verschiebt den Render-ZUSTAND, nicht die Sim-Ownership, und die
/// Renderer darunter nehmen das Terrain ohnehin je Aufruf.
public final class RenderState {

    /// `geometryMode` = malen die Mäander-Hauptläufe und Altarme als
    /// Band-Geometrie (Standard seit #34) oder als Raster-Stempel? Der
    /// Legacy-A/B-Schalter `RS_WATER_STAMP` ist damit hier aufgelöst, wo das
    /// Wasserfeld ihn braucht, statt in der Brücke (`Main.gd` liest dieselbe
    /// Umgebungsvariable und baut dann kein Ribbon-Mesh).
    public let geometryMode: Bool

    /// `geometryMode` ist injizierbar, damit die Wächter beide Pfade fahren
    /// können, ohne die Prozess-Umgebung zu verstellen. Die Umgebung wird EINMAL
    /// hier gelesen statt je Aufruf: sie ändert sich im laufenden Prozess nicht,
    /// und der Schalter darf nicht mitten in einer Sitzung umspringen.
    public init(geometryMode: Bool = ProcessInfo.processInfo
                    .environment["RS_WATER_STAMP"] == nil) {
        self.geometryMode = geometryMode
    }

    // MARK: - Frame-Taktung (Issue #94, Werte aus `Main.gd` übernommen)

    /// Wasser-Blend im Zeitraffer: 0.15 statt 0.35 — bei 60 J/s sind 0,3 s
    /// schon 18 Sim-Jahre; mit 0.35 schnappten Läufe und Seeufer sichtbar um
    /// (Nutzer: „super schlimm"), mit 0.15 gleiten sie über ~2 s in die neue
    /// Lage. Alle anderen Auslöser übernehmen den frischen Stand (1.0).
    public static let timelapseWaterBlend = 0.15
    /// Overlay-Drossel im Zeitraffer: Wasser, Farbe, Material, Masken und Bänder
    /// höchstens alle 0,30 s; die Höhe folgt jedem Sim-Takt.
    public static let overlayIntervalSeconds = 0.30
    /// Band-Deckel (1 Hz) für Zeitraffer UND Sprung-Chunks: Strahler + Mesh
    /// sind CPU-seitig; 0,30 s kosteten im Zeitraffer messbar ~4 % FPS.
    public static let ribbonRebuildSeconds = 1.0
    /// Band-Rebuild erst ab dieser Knoten-Verschiebung (Zellen). Struktur-
    /// Änderungen (Cutoff, neuer/verschwundener Kanal) melden ein Riesen-Delta
    /// und bauen damit beim nächsten fälligen Frame sofort.
    public static let ribbonRebuildDelta = 0.05

    /// Zeitpunkt des letzten Overlay-Uploads bzw. der letzten Band-Prüfung
    /// (Sekunden, Uhr des Aufrufers). `nil` = noch keiner → sofort fällig.
    private var lastOverlayTime: Double?
    private var lastRibbonCheckTime: Double?

    /// `RS_WATER_GPU`: das Wasserfeld kommt roh, Blur/EWMA laufen auf der GPU.
    public var deferWaterTail = false

    private let waterField = WaterFieldRenderer()
    private let ribbons = RiverRibbonRenderer()
    private let diagnostics = TerrainDiagnostics()

    /// Farbe und Materialgewichte entstehen gemeinsam und bleiben bis zur
    /// nächsten Terrain-Änderung gepuffert. Godot lädt sie als drei Texturen,
    /// die teure Standortauswertung läuft aber nur einmal.
    private var materials: TerrainColorRenderer.Buffers?
    /// Nasse Wiese des zuletzt ausgelieferten Wasserfelds (Issue #174 C,
    /// `WaterFieldRenderer.wetMeadow`). Sie geht ins Material (`WetMeadow`)
    /// und in die Schutzmaske; ändert sie sich, fällt der Material-Cache.
    private var visibleWetMeadow: [Bool] = []
    /// Nasse Wiese des zuletzt ausgelieferten Wasserfelds (leer vor dem ersten).
    public var wetMeadowMask: [Bool] { visibleWetMeadow }

    /// Quellen der Sedimentfahnen (Issue #174 C, `SedimentPlume`), gepuffert
    /// bis zur nächsten Terrain-Änderung.
    private var plumeCache: [Float]?

    /// Material des Mäandergürtels (Issue #174 C2): Sand, Scroll-Rippen,
    /// Altarm-Verlandung. Liest nur das Terrain, fällt also mit dem
    /// Material-Cache; Farbe und Schutzmaske lesen DASSELBE Feld.
    private var barCache: BarMaterial.Field?

    /// Schutzmaske für Kronendach und Verschiebung (R8), gepuffert bis sich
    /// eine ihrer beiden Quellen ändert: das zuletzt ausgelieferte Wasserfeld
    /// (`visibleWater`) oder die Bandabdeckung (`buildRiverRibbons`).
    private var protectMaskCache: [UInt8]?
    /// Das zuletzt an Godot ausgelieferte Wasserfeld, also das, was der Spieler
    /// gerade SIEHT. Die Maske folgt ihm statt dem Terrain: nach einem
    /// Pinselstrich zeigt Godot bis zum nächsten Wasser-Upload noch das alte
    /// Feld, und genau das muss geschützt bleiben. Ein eigenes Nachrechnen
    /// kostete außerdem einen zweiten Wasserfeld-Lauf (~13 ms).
    private var visibleWater: [UInt8]?

    /// Waldmaske des Kronendachs (R8). Sie liest Materialgewichte UND
    /// Schutzmaske und fällt deshalb mit beiden (`dropMasks`).
    private var forestMaskCache: [UInt8]?
    /// Lichtungs-Rauschen: hängt nur an Gittergröße und Weltbreite, einmal
    /// gerechnet.
    private var clumpField: [Float] = []
    private var clumpWorld = 0.0
    /// Gedächtnis der Waldmaske (Issue #167, s. `ForestCanopyMask.regrow`):
    /// der zuletzt gezeigte Wald je Zelle und das Sim-Jahr dazu. Leer = kein
    /// Gedächtnis, die nächste Maske übernimmt das Ziel.
    private var forestMemory: [Float] = []
    private var forestMemoryYear = 0.0

    /// Schutz- und Waldmaske fallen immer gemeinsam: die Waldmaske endet an
    /// der Schutzmaske, ein veralteter Wald stünde sonst über neuem Wasser.
    private func dropMasks() {
        protectMaskCache = nil
        forestMaskCache = nil
    }

    // MARK: - Invalidierung (DER eine Einstieg)

    /// Meldet, dass sich das Terrain geändert hat: der Material-Cache fällt,
    /// die nächste Abfrage rechnet gegen den frischen Stand. `change` sagt,
    /// WIE (s. `TerrainChange`).
    ///
    /// `.replaced` = es ist eine ANDERE Welt (neu generiert oder geladen).
    /// Dann fällt zusätzlich alles, was gegen den VORHERIGEN Stand vergleicht:
    /// - der Dirty-Snapshot der Bänder, damit der nächste Frame sie neu baut
    ///   statt über eine Delta-Heuristik gegen eine fremde Welt zu prüfen
    ///   (ohne Vergleichsstand meldet er „riesig", 1e9 — weit über
    ///   `ribbonRebuildDelta`),
    /// - der Vergleichspunkt der Diagnose, damit die Δ-Karte zeigt, was die Sim
    ///   AB JETZT tut, und nicht die Differenz zur alten Welt.
    ///
    /// Bis #93 tat das nur das Laden; das Generieren ließ die Snapshots stehen.
    /// Die Asymmetrie war keine Entscheidung, sondern Altbestand — eine frisch
    /// generierte Welt teilt mit der alten nichts, gegen das ein Snapshot noch
    /// etwas aussagen könnte.
    ///
    /// `.edited` und `.replaced` setzen außerdem das Gedächtnis der Waldmaske
    /// zurück (Issue #167): nach Pinsel, Neugenerieren und Laden steht der Wald
    /// sofort dort, wo er hingehört, statt über Jahrhunderte nachzuwachsen.
    /// Nur `.advanced` lässt ihn nachwachsen.
    ///
    /// AUSGENOMMEN, bewusst: das EWMA-Gedächtnis des Wasserfelds
    /// (`WaterFieldRenderer`). Es fällt auch bei `.replaced` nicht, weil es
    /// keine Aussage über die alte Welt ist, sondern eine zeitliche Glättung mit
    /// einem Mischfaktor — und jeder Weltwechsel endet in einem
    /// `frame(.settled)`, dessen Blend 1.0 das Gedächtnis ohnehin vollständig
    /// überschreibt. Ein Reset hier wäre damit wirkungslos (geprüft mit #94,
    /// das die Taktung hierher gezogen hat).
    public func invalidate(_ terrain: Terrain, _ change: TerrainChange) {
        materials = nil
        plumeCache = nil
        barCache = nil
        dropMasks()
        if change != .advanced { forestMemory = [] }
        guard change == .replaced else { return }
        // Eine ANDERE Welt: das alte Wasserfeld passt nicht mehr dazu.
        visibleWater = nil
        visibleWetMeadow = []
        ribbons.invalidateSnapshot()
        diagnostics.capture(terrain)
    }

    // MARK: - Frame (Issue #94)

    /// Die Puffer eines Frames, in der einzigen gültigen Reihenfolge:
    /// Bänder → Wasserfeld (liest `bandChannelFlags`/`bandCoverage` DIESES
    /// Builds) → Schutzmaske (liest beides) → Waldmaske (liest die Schutzmaske).
    /// Bis #94 stand die
    /// Reihenfolge als Kommentar an drei Stellen in `Main.gd`, und Zeitraffer
    /// und Pinsel-Nachzug bauten die Bänder tatsächlich NACH dem Wasserfeld.
    ///
    /// `now` = monotone Uhr des Aufrufers in Sekunden (Godot:
    /// `Time.get_ticks_msec() / 1000`). Die Drosseln vergleichen nur Abstände;
    /// über die Uhr bleiben sie headless prüfbar.
    public func frame(_ terrain: Terrain, _ trigger: FrameTrigger, now: Double) -> RenderFrame {
        var out = RenderFrame()
        if trigger == .timelapse, let last = lastOverlayTime,
           now - last < Self.overlayIntervalSeconds {
            return out
        }
        lastOverlayTime = now

        out.ribbonsRebuilt = rebuildRibbonsIfDue(
            terrain, now: now, force: trigger == .settled || trigger == .stroke)

        let blend = trigger == .timelapse ? Self.timelapseWaterBlend : 1.0
        // GPU-Pfad: die CPU liefert das ungeglättete Feld, gemischt wird im Shader.
        let water = waterFieldBytes(terrain, blend: deferWaterTail ? 1.0 : blend,
                                    deferTail: deferWaterTail)
        out.overlays = RenderFrame.Overlays(
            water: water, waterBlend: blend,
            colors: terrainColorBytes(terrain), surfaces: terrainSurfaceBytes(terrain),
            covers: terrainCoverBytes(terrain), flowDetail: flowDetailBytes(terrain), protectMask: protectMaskBytes(terrain),
            forestMask: forestMaskBytes(terrain), plume: sedimentPlume(terrain))
        return out
    }

    /// Bänder neu bauen, wenn der Deckel abgelaufen ist (oder `force`) UND sich
    /// die Zentrumslinien merklich bewegt haben. Der Deckel zählt die PRÜFUNG,
    /// nicht den Bau: auch eine Prüfung ohne Rebuild startet ihn neu.
    private func rebuildRibbonsIfDue(_ terrain: Terrain, now: Double, force: Bool) -> Bool {
        guard geometryMode else { return false }
        if !force, let last = lastRibbonCheckTime, now - last < Self.ribbonRebuildSeconds {
            return false
        }
        lastRibbonCheckTime = now
        guard riversMaxDelta(terrain) > Self.ribbonRebuildDelta else { return false }
        buildRiverRibbons(terrain, hscale: RenderContract.heightScale,
                          lift: RenderContract.riverLift)
        markRiversBuilt(terrain)
        return true
    }

    // MARK: - Material-Puffer (Farbe + Gewichte, gemeinsam berechnet)

    /// Großräumige Biom-/Höhen-Farbe als RGBA8-Puffer.
    public func terrainColorBytes(_ terrain: Terrain) -> [UInt8] {
        cachedMaterials(terrain).colors
    }

    /// R = Vegetation, G = freier Fels, B = Schnee/Eis, A = Lithologie-Härte.
    public func terrainSurfaceBytes(_ terrain: Terrain) -> [UInt8] {
        cachedMaterials(terrain).surfaces
    }

    /// R = Schutthalde, G = blankes Gletschereis, B = Rohboden,
    /// A = Talboden-Wiese (Issue #174 D).
    public func terrainCoverBytes(_ terrain: Terrain) -> [UInt8] {
        cachedMaterials(terrain).covers
    }

    private func cachedMaterials(_ terrain: Terrain) -> TerrainColorRenderer.Buffers {
        if let materials { return materials }
        let buffers = WetMeadow.apply(TerrainColorRenderer.buffers(terrain, bars: barMaterial(terrain)),
                                      mask: visibleWetMeadow)
        materials = buffers
        return buffers
    }

    // MARK: - Sedimentfahnen (Issue #174 C)

    /// Quellfeld der Sedimentfahnen (Float32, n×n) — s. `SedimentPlume`.
    public func sedimentPlume(_ terrain: Terrain) -> [Float] {
        if let plumeCache { return plumeCache }
        let field = SedimentPlume.field(terrain)
        plumeCache = field
        return field
    }

    // MARK: - Mäandergürtel (Issue #174 C2)

    /// Gürtel-Material (Issue #174 C2) — s. `BarMaterial`.
    public func barMaterial(_ terrain: Terrain) -> BarMaterial.Field {
        if let barCache { return barCache }
        let field = BarMaterial.field(terrain)
        barCache = field
        return field
    }

    // MARK: - Wasser-Feld (Raster-Pfad)

    /// Wasser-Feld (Flüsse/Seen/Altarme) als RGBA8-Puffer — Kanäle und
    /// Kalibrierung: `WaterFieldRenderer`. `blend` glättet zeitlich (1 = Sprung
    /// sofort übernehmen), `deferTail` überlässt die Schwanzstufen dem
    /// GPU-Pass (`RS_WATER_GPU`).
    ///
    /// Die Kopplung der beiden Wasser-Pfade liegt hier, nicht beim Aufrufer:
    /// `bandChannelFlags`/`bandCoverage` sind das ECHTE Bau-Ergebnis des
    /// letzten Ribbon-Builds, und nur Kanäle MIT Band werden im Feld zum Saum
    /// gedeckelt (Issue #34).
    public func waterFieldBytes(_ terrain: Terrain, blend: Double,
                                deferTail: Bool = false) -> [UInt8] {
        let bytes = waterField.bytes(terrain, blend: blend, geometryMode: geometryMode,
                                     bandChannelFlags: ribbons.bandChannelFlags,
                                     bandCoverage: ribbons.bandCoverage,
                                     deferTail: deferTail)
        // Auch die Rohbytes des `deferTail`-Pfads (RS_WATER_GPU) zählen: sie sind
        // ungeblurt um höchstens die zwei Blur-Pässe schmaler als das Sichtbare,
        // und genau so weit reicht der Saum (`WaterRender.protectSeamCells`).
        visibleWater = bytes
        // Nasse Wiese (#174 C): ändert sie sich, gilt das Material nicht mehr.
        if waterField.wetMeadow != visibleWetMeadow {
            visibleWetMeadow = waterField.wetMeadow
            materials = nil
        }
        dropMasks()
        return bytes
    }

    // MARK: - Schutzmaske (Issue #154)

    /// Schutzmaske für Kronendach und Verschiebung (R8-Puffer, n×n).
    /// Vereint das zuletzt ausgelieferte Wasserfeld (s. `visibleWater`), die
    /// gebauten Flussbänder und einen Saum. Vor dem ersten `waterFieldBytes`
    /// einer Welt schützt sie nur die Bänder; der Wasser-Upload folgt in
    /// `Main.gd` im selben Frame und verwirft diesen Stand wieder.
    public func protectMaskBytes(_ terrain: Terrain) -> [UInt8] {
        if let protectMaskCache { return protectMaskCache }
        let mask = WaterProtectMask.bytes(n: terrain.cfg.n,
                                          bandCoverage: ribbons.bandCoverage,
                                          waterBytes: visibleWater ?? [],
                                          wetMeadow: visibleWetMeadow,
                                          barSand: barMaterial(terrain).sand)
        protectMaskCache = mask
        return mask
    }

    // MARK: - Kronendach (Issue #152)

    /// Waldmaske des Kronendachs (R8-Puffer, n×n) — s. `ForestCanopyMask`.
    /// Folgt Terrain, Wasser-Upload und Band-Bau wie die Schutzmaske; wo der
    /// Wald zurückkommt, wächst er über Sim-Jahre nach (Issue #167).
    public func forestMaskBytes(_ terrain: Terrain) -> [UInt8] {
        if let forestMaskCache { return forestMaskCache }
        let n = terrain.cfg.n
        if clumpField.count != n * n || clumpWorld != terrain.cfg.world {
            clumpField = ForestCanopyMask.clumpField(n: n, world: terrain.cfg.world)
            clumpWorld = terrain.cfg.world
        }
        let target = ForestCanopyMask.bytes(terrain, surfaces: terrainSurfaceBytes(terrain),
                                            protect: protectMaskBytes(terrain), clump: clumpField)
        // Eine Uhr, die rückwärts läuft, gehört zu keiner fortgeschriebenen Welt.
        if terrain.years < forestMemoryYear { forestMemory = [] }
        let mask = ForestCanopyMask.regrow(&forestMemory, toward: target,
                                           dtYears: terrain.years - forestMemoryYear,
                                           tau: CanopyRender.regrowYears)
        forestMemoryYear = terrain.years
        forestMaskCache = mask
        return mask
    }

    // MARK: - Diagnose

    /// Setzt den Vergleichspunkt der Δ-Karte auf den aktuellen Zustand.
    /// Abfluss-Dichte fürs Shader-Detail (R8) — s. `WaterFieldRenderer.flowDetailField`.
    public func flowDetailBytes(_ terrain: Terrain) -> [UInt8] {
        waterField.flowDetailField(terrain)
    }

    public func captureDebugReference(_ terrain: Terrain) { diagnostics.capture(terrain) }

    /// Kennzahlen-Vertrag für GDScript — Reihenfolge: `TerrainDiagnostics.stats`.
    public func debugTerrainStats(_ terrain: Terrain) -> [Float] { diagnostics.stats(terrain) }

    /// Δ-Karte gegen den Vergleichspunkt (blau = abgetragen, rot = aufgebaut).
    public func heightDifferenceBytes(_ terrain: Terrain, scale: Double) -> [UInt8] {
        diagnostics.differenceBytes(terrain, scale: scale)
    }

    // MARK: - Wasser-Geometrie (Band-Pfad)

    public func riversMaxDelta(_ terrain: Terrain) -> Double { ribbons.maxDelta(terrain) }

    public func markRiversBuilt(_ terrain: Terrain) { ribbons.markBuilt(terrain) }

    /// Baut die Bänder der Mäander-Hauptläufe, Delta-Arme und Altarme.
    /// `hscale` = Render-Überhöhung, `lift` = Anhebung über Gelände (Welt-Y).
    public func buildRiverRibbons(_ terrain: Terrain, hscale: Double, lift: Double) {
        ribbons.build(terrain, hscale: hscale, lift: lift)
        dropMasks()
    }

    /// Letztes Band-Bauergebnis als POD-Puffer (die Brücke wrappt sie in
    /// `Packed*Array`).
    public var riverRibbonMesh: RibbonMesh { ribbons.mesh }

    /// Auflösung des Terrain-Render-Gitters (Main.gd `terrain_grid`): die
    /// Land-Bänder sampeln ihre Höhen von der SICHTBAREN Oberfläche statt von
    /// den Sim-Höhen. 0 = unbekannt = volle Auflösung.
    public var renderGrid: Int {
        get { ribbons.renderGrid }
        set { ribbons.renderGrid = newValue }
    }
}

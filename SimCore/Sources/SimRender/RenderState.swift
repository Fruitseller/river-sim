import Foundation
import SimCore

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

    private let waterField = WaterFieldRenderer()
    private let ribbons = RiverRibbonRenderer()
    private let diagnostics = TerrainDiagnostics()

    /// Farbe und Materialgewichte entstehen gemeinsam und bleiben bis zur
    /// nächsten Terrain-Änderung gepuffert. Godot lädt sie als zwei Texturen,
    /// die teure Standortauswertung läuft aber nur einmal.
    private var materials: TerrainColorRenderer.Buffers?

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

    /// Schutz- und Waldmaske fallen immer gemeinsam: die Waldmaske endet an
    /// der Schutzmaske, ein veralteter Wald stünde sonst über neuem Wasser.
    private func dropMasks() {
        protectMaskCache = nil
        forestMaskCache = nil
    }

    // MARK: - Invalidierung (DER eine Einstieg)

    /// Meldet, dass sich das Terrain geändert hat: der Material-Cache fällt,
    /// die nächste Abfrage rechnet gegen den frischen Stand.
    ///
    /// `worldReplaced` = es ist eine ANDERE Welt (neu generiert oder geladen).
    /// Dann fällt zusätzlich alles, was gegen den VORHERIGEN Stand vergleicht:
    /// - der Dirty-Snapshot der Bänder, damit der nächste Frame sie neu baut
    ///   statt über eine Delta-Heuristik gegen eine fremde Welt zu prüfen
    ///   (ohne Vergleichsstand meldet er „riesig", 1e9 — weit über der
    ///   Schwelle in `Main.gd`),
    /// - der Vergleichspunkt der Diagnose, damit die Δ-Karte zeigt, was die Sim
    ///   AB JETZT tut, und nicht die Differenz zur alten Welt.
    ///
    /// Bis #93 tat das nur das Laden; das Generieren ließ die Snapshots stehen.
    /// Die Asymmetrie war keine Entscheidung, sondern Altbestand — eine frisch
    /// generierte Welt teilt mit der alten nichts, gegen das ein Snapshot noch
    /// etwas aussagen könnte.
    ///
    /// AUSGENOMMEN, bewusst: das EWMA-Gedächtnis des Wasserfelds
    /// (`WaterFieldRenderer`). Es fällt auch bei `worldReplaced` nicht, weil es
    /// keine Aussage über die alte Welt ist, sondern eine zeitliche Glättung mit
    /// einem Mischfaktor, den der Aufrufer je Frame mitgibt — die erste Abfrage
    /// nach einem Weltwechsel läuft in der Produktion ohnehin über
    /// `waterFieldBytes(blend: 1.0)` (Textur-Neuaufbau), und ein Reset hier wäre
    /// eine Verhaltensänderung, die dieser Prefactor nicht mitbringt. Wer die
    /// Taktung anfasst, entscheidet sie mit (Issue #94).
    public func invalidate(_ terrain: Terrain, worldReplaced: Bool = false) {
        materials = nil
        dropMasks()
        guard worldReplaced else { return }
        // Eine ANDERE Welt: das alte Wasserfeld passt nicht mehr dazu.
        visibleWater = nil
        ribbons.invalidateSnapshot()
        diagnostics.capture(terrain)
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

    private func cachedMaterials(_ terrain: Terrain) -> TerrainColorRenderer.Buffers {
        if let materials { return materials }
        let buffers = TerrainColorRenderer.buffers(terrain)
        materials = buffers
        return buffers
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
                                          waterBytes: visibleWater ?? [])
        protectMaskCache = mask
        return mask
    }

    // MARK: - Kronendach (Issue #152)

    /// Waldmaske des Kronendachs (R8-Puffer, n×n) — s. `ForestCanopyMask`.
    /// Folgt Terrain, Wasser-Upload und Band-Bau wie die Schutzmaske.
    public func forestMaskBytes(_ terrain: Terrain) -> [UInt8] {
        if let forestMaskCache { return forestMaskCache }
        let n = terrain.cfg.n
        if clumpField.count != n * n || clumpWorld != terrain.cfg.world {
            clumpField = ForestCanopyMask.clumpField(n: n, world: terrain.cfg.world)
            clumpWorld = terrain.cfg.world
        }
        let mask = ForestCanopyMask.bytes(terrain, surfaces: terrainSurfaceBytes(terrain),
                                          protect: protectMaskBytes(terrain), clump: clumpField)
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

import Foundation
import SimCore

/// Der Render-Zustand EINER Welt: die fünf Renderer mit ihren EWMA-Feldern,
/// Arbeitspuffern und Dirty-Snapshots plus der Material-Cache (Issue #93).
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
/// Physik bleibt vollständig in `SimCore`.
public final class RenderState {

    /// `geometryMode` = malen die Mäander-Hauptläufe und Altarme als
    /// Band-Geometrie (Standard seit #34) oder als Raster-Stempel? Der
    /// Legacy-A/B-Schalter `RS_WATER_STAMP` ist damit hier aufgelöst, wo das
    /// Wasserfeld ihn braucht, statt in der Brücke (`Main.gd` liest dieselbe
    /// Umgebungsvariable und baut dann kein Ribbon-Mesh).
    public let geometryMode: Bool

    /// `geometryMode` ist injizierbar, damit die Wächter beide Pfade fahren
    /// können, ohne die Prozess-Umgebung zu verstellen.
    public init(geometryMode: Bool = ProcessInfo.processInfo
                    .environment["RS_WATER_STAMP"] == nil) {
        self.geometryMode = geometryMode
    }

    private let waterField = WaterFieldRenderer()
    private let ribbons = RiverRibbonRenderer()
    private let trees = TreeInstanceRenderer()
    private let diagnostics = TerrainDiagnostics()

    /// Farbe und Materialgewichte entstehen gemeinsam und bleiben bis zur
    /// nächsten Terrain-Änderung gepuffert. Godot lädt sie als zwei Texturen,
    /// die teure Standortauswertung läuft aber nur einmal.
    private var materials: TerrainColorRenderer.Buffers?

    // MARK: - Invalidierung (DER eine Einstieg)

    /// Meldet, dass sich das Terrain geändert hat: der Material-Cache fällt,
    /// die nächste Abfrage rechnet gegen den frischen Stand.
    ///
    /// `worldReplaced` = es ist eine ANDERE Welt (neu generiert oder geladen).
    /// Dann fällt zusätzlich alles, was gegen den VORHERIGEN Stand vergleicht:
    /// - die Dirty-Snapshots von Bäumen und Bändern, damit der nächste Frame
    ///   beide neu baut statt sie über eine Delta-Heuristik gegen eine
    ///   fremde Welt zu prüfen (ohne Vergleichsstand melden beide „riesig":
    ///   Bäume 1, Bänder 1e9 — weit über den Schwellen in `Main.gd`),
    /// - der Vergleichspunkt der Diagnose, damit die Δ-Karte zeigt, was die Sim
    ///   AB JETZT tut, und nicht die Differenz zur alten Welt.
    ///
    /// Bis #93 tat das nur das Laden; das Generieren ließ die Snapshots stehen.
    /// Die Asymmetrie war keine Entscheidung, sondern Altbestand — eine frisch
    /// generierte Welt teilt mit der alten nichts, gegen das ein Snapshot noch
    /// etwas aussagen könnte.
    public func invalidate(_ terrain: Terrain, worldReplaced: Bool = false) {
        materials = nil
        guard worldReplaced else { return }
        trees.invalidateSnapshot()
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
        waterField.bytes(terrain, blend: blend, geometryMode: geometryMode,
                         bandChannelFlags: ribbons.bandChannelFlags,
                         bandCoverage: ribbons.bandCoverage,
                         deferTail: deferTail)
    }

    // MARK: - Diagnose

    /// Setzt den Vergleichspunkt der Δ-Karte auf den aktuellen Zustand.
    public func captureDebugReference(_ terrain: Terrain) { diagnostics.capture(terrain) }

    /// Kennzahlen-Vertrag für GDScript — Reihenfolge: `TerrainDiagnostics.stats`.
    public func debugTerrainStats(_ terrain: Terrain) -> [Float] { diagnostics.stats(terrain) }

    /// Δ-Karte gegen den Vergleichspunkt (blau = abgetragen, rot = aufgebaut).
    public func heightDifferenceBytes(_ terrain: Terrain, scale: Double) -> [UInt8] {
        diagnostics.differenceBytes(terrain, scale: scale)
    }

    // MARK: - Baum-Instanzen

    public func treeVegMaxDelta(_ terrain: Terrain) -> Double { trees.maxDelta(terrain) }

    public func markTreesBuilt(_ terrain: Terrain) { trees.markBuilt(terrain) }

    public func treeInstanceBuffer(_ terrain: Terrain, variant: Int, hscale: Double,
                                   coverage: Int) -> [Float] {
        trees.buffer(terrain, variant: variant, hscale: hscale, coverage: coverage)
    }

    // MARK: - Wasser-Geometrie (Band-Pfad)

    public func riversMaxDelta(_ terrain: Terrain) -> Double { ribbons.maxDelta(terrain) }

    public func markRiversBuilt(_ terrain: Terrain) { ribbons.markBuilt(terrain) }

    /// Baut die Bänder der Mäander-Hauptläufe, Delta-Arme und Altarme.
    /// `hscale` = Render-Überhöhung, `lift` = Anhebung über Gelände (Welt-Y).
    public func buildRiverRibbons(_ terrain: Terrain, hscale: Double, lift: Double) {
        ribbons.build(terrain, hscale: hscale, lift: lift)
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

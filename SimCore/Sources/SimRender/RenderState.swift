import Foundation
import SimCore

public enum TerrainChange {
    case advanced
    case edited
    case replaced
}

public final class RenderState {

    let geometryMode: Bool

    init(geometryMode: Bool = ProcessInfo.processInfo
                .environment["RS_WATER_STAMP"] == nil) {
        self.geometryMode = geometryMode
    }

    public static let timelapseWaterBlend = 0.15
    public static let overlayIntervalSeconds = 0.30
    public static let ribbonRebuildSeconds = 1.0
    public static let ribbonRebuildDelta = 0.05

    private var lastOverlayTime: Double?
    private var lastRibbonCheckTime: Double?

    var deferWaterTail = false

    private let waterField = WaterFieldRenderer()
    private let ribbons = RiverRibbonRenderer()
    private let diagnostics = TerrainDiagnostics()

    private var materials: TerrainColorRenderer.Buffers?
    private var visibleWetMeadow: [Bool] = []
    var wetMeadowMask: [Bool] { visibleWetMeadow }
    var bandCore: [Double] { ribbons.bandVisibleCoverage }

    private var plumeCache: [Float]?

    private var barCache: BarMaterial.Field?

    private var protectMaskCache: [UInt8]?
    private var visibleWater: [UInt8]?

    private var forestMaskCache: [UInt8]?
    private var clumpField: [Float] = []
    private var riparianNoise: [Float] = []
    private var clumpWorld = 0.0
    private var forestMemory: [Float] = []
    private var editedSinceRibbonBuild = false
    private var forestMemoryYear = 0.0

    private func dropMasks() {
        protectMaskCache = nil
        forestMaskCache = nil
    }

    public func invalidate(_ terrain: Terrain, _ change: TerrainChange) {
        materials = nil
        plumeCache = nil
        barCache = nil
        dropMasks()
        if change == .edited { editedSinceRibbonBuild = true }
        if change != .advanced {
            forestMemory = []
            ribbons.endTransitions(otherWorld: change == .replaced)
        }
        guard change == .replaced else { return }
        visibleWater = nil
        visibleWetMeadow = []
        ribbons.invalidateSnapshot()
        diagnostics.capture(terrain)
    }

    public func frame(_ terrain: Terrain, _ trigger: FrameTrigger, now: Double) -> RenderFrame {
        var out = RenderFrame()
        if trigger == .timelapse, let last = lastOverlayTime,
           now - last < Self.overlayIntervalSeconds {
            return out
        }
        lastOverlayTime = now

        out.ribbonsRebuilt = rebuildRibbonsIfDue(
            terrain, now: now, force: trigger == .settled || trigger == .stroke,
            afterEdit: trigger == .settled && editedSinceRibbonBuild)

        let blend = trigger == .timelapse ? Self.timelapseWaterBlend : 1.0
        let water = waterFieldBytes(terrain, blend: deferWaterTail ? 1.0 : blend,
                                    deferTail: deferWaterTail)
        out.overlays = RenderFrame.Overlays(
            water: water, waterBlend: blend,
            colors: terrainColorBytes(terrain), surfaces: terrainSurfaceBytes(terrain),
            covers: terrainCoverBytes(terrain), flowDetail: flowDetailBytes(terrain), protectMask: protectMaskBytes(terrain),
            forestMask: forestMaskBytes(terrain), plume: sedimentPlume(terrain))
        return out
    }

    private func rebuildRibbonsIfDue(_ terrain: Terrain, now: Double, force: Bool,
                                     afterEdit: Bool = false) -> Bool {
        guard geometryMode else { return false }
        if !force, let last = lastRibbonCheckTime, now - last < Self.ribbonRebuildSeconds {
            return false
        }
        lastRibbonCheckTime = now
        guard afterEdit || riversMaxDelta(terrain) > Self.ribbonRebuildDelta
                || ribbons.inTransition else { return false }
        buildRiverRibbons(terrain, hscale: RenderContract.heightScale,
                          lift: RenderContract.riverLift)
        markRiversBuilt(terrain)
        editedSinceRibbonBuild = false
        return true
    }

    func terrainColorBytes(_ terrain: Terrain) -> [UInt8] {
        cachedMaterials(terrain).colors
    }

    func terrainSurfaceBytes(_ terrain: Terrain) -> [UInt8] {
        cachedMaterials(terrain).surfaces
    }

    func terrainCoverBytes(_ terrain: Terrain) -> [UInt8] {
        cachedMaterials(terrain).covers
    }

    private func cachedMaterials(_ terrain: Terrain) -> TerrainColorRenderer.Buffers {
        if let materials { return materials }
        let buffers = WetMeadow.apply(TerrainColorRenderer.buffers(terrain, bars: barMaterial(terrain)),
                                      mask: visibleWetMeadow)
        materials = buffers
        return buffers
    }

    func sedimentPlume(_ terrain: Terrain) -> [Float] {
        if let plumeCache { return plumeCache }
        let field = SedimentPlume.field(terrain)
        plumeCache = field
        return field
    }

    func barMaterial(_ terrain: Terrain) -> BarMaterial.Field {
        if let barCache { return barCache }
        let field = BarMaterial.field(terrain)
        barCache = field
        return field
    }

    func waterFieldBytes(_ terrain: Terrain, blend: Double,
                                deferTail: Bool = false) -> [UInt8] {
        let bytes = waterField.bytes(terrain, blend: blend, geometryMode: geometryMode,
                                     bandChannelFlags: ribbons.bandChannelFlags,
                                     bandCoverage: ribbons.bandCoverage,
                                     bandOwner: ribbons.bandOwner,
                                     deferTail: deferTail)
        visibleWater = bytes
        if waterField.wetMeadow != visibleWetMeadow {
            visibleWetMeadow = waterField.wetMeadow
            materials = nil
        }
        dropMasks()
        return bytes
    }

    func protectMaskBytes(_ terrain: Terrain) -> [UInt8] {
        if let protectMaskCache { return protectMaskCache }
        let mask = WaterProtectMask.bytes(n: terrain.cfg.n,
                                          bandCoverage: ribbons.bandCoverage,
                                          waterBytes: visibleWater ?? [],
                                          wetMeadow: visibleWetMeadow,
                                          barSand: barMaterial(terrain).sand)
        protectMaskCache = mask
        return mask
    }

    func forestMaskBytes(_ terrain: Terrain) -> [UInt8] {
        if let forestMaskCache { return forestMaskCache }
        let n = terrain.cfg.n
        if clumpField.count != n * n || clumpWorld != terrain.cfg.world {
            clumpField = ForestCanopyMask.clumpField(n: n, world: terrain.cfg.world)
            riparianNoise = ForestCanopyMask.riparianField(n: n, world: terrain.cfg.world)
            clumpWorld = terrain.cfg.world
        }
        let (target, distance) = ForestCanopyMask.target(
            terrain, surfaces: terrainSurfaceBytes(terrain), colors: terrainColorBytes(terrain),
            bandCore: ribbons.bandVisibleCoverage, waterBytes: visibleWater ?? [],
            wetMeadow: visibleWetMeadow, barSand: barMaterial(terrain).sand,
            clump: clumpField, riparianNoise: riparianNoise, protect: protectMaskBytes(terrain))
        if terrain.years < forestMemoryYear { forestMemory = [] }
        let mask = ForestCanopyMask.regrow(&forestMemory, toward: target,
                                           dtYears: terrain.years - forestMemoryYear,
                                           tau: CanopyRender.regrowYears,
                                           wet: WetNow(bandCoverage: ribbons.bandCoverage,
                                                       waterBytes: visibleWater ?? [],
                                                       bandThreshold: CanopyRender.retreatInstantBandCoverage),
                                           retreatTau: CanopyRender.retreatYears,
                                           fast: distance.map { Int($0) <= Int(CanopyRender.riparianWidthHi) + 1 },
                                           fastTau: CanopyRender.riparianRegrowYears)
        forestMemoryYear = terrain.years
        forestMaskCache = mask
        return mask
    }

    func flowDetailBytes(_ terrain: Terrain) -> [UInt8] {
        waterField.flowDetailField(terrain)
    }

    public func captureDebugReference(_ terrain: Terrain) { diagnostics.capture(terrain) }

    public func debugTerrainStats(_ terrain: Terrain) -> [Float] { diagnostics.stats(terrain) }

    public func heightDifferenceBytes(_ terrain: Terrain, scale: Double) -> [UInt8] {
        diagnostics.differenceBytes(terrain, scale: scale)
    }

    func riversMaxDelta(_ terrain: Terrain) -> Double { ribbons.maxDelta(terrain) }

    func markRiversBuilt(_ terrain: Terrain) { ribbons.markBuilt(terrain) }

    func buildRiverRibbons(_ terrain: Terrain, hscale: Double, lift: Double) {
        ribbons.build(terrain, hscale: hscale, lift: lift)
        dropMasks()
    }

    var riverRibbonMesh: RibbonMesh { ribbons.mesh }
    var ribbonGhostCount: Int { ribbons.ghostCount }
    var ribbonGrowthStats: (young: Int, exempt: Int) { ribbons.growthStats }
    var ribbonMatureCoverage: [Double] { ribbons.matureCoverageForDiagnostics }

    var renderGrid: Int {
        get { ribbons.renderGrid }
        set { ribbons.renderGrid = newValue }
    }
}

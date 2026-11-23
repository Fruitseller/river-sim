import Foundation
import SimCore

public final class WorldSession<Packed> {
    private var storedWorld: Terrain
    private let storedRender: RenderState
    private let job: BackgroundJob<Packed>

    public convenience init(config: SimConfig, seed: UInt32, settleYears: Double = 0) {
        self.init(config: config, seed: seed, settleYears: settleYears,
                  render: RenderState())
    }

    init(config: SimConfig, seed: UInt32, settleYears: Double = 0,
         render: RenderState) {
        storedWorld = Terrain(config: config, seed: seed, settleYears: settleYears)
        storedRender = render
        job = BackgroundJob(label: "river-sim.step")
    }

    deinit {
        job.wait()
    }

    private var world: Terrain {
        job.wait()
        return storedWorld
    }

    private var render: RenderState {
        job.wait()
        return storedRender
    }

    private var storedLastChange: TerrainChange?
    var lastChange: TerrainChange? {
        job.wait()
        return storedLastChange
    }

    private func change(_ kind: TerrainChange) {
        Self.invalidate(world, render, kind)
        storedLastChange = kind
    }

    private static func invalidate(_ terrain: Terrain, _ render: RenderState,
                                   _ kind: TerrainChange) {
        render.invalidate(terrain, kind)
    }

    public func generate(seed: UInt32, settleYears: Double = 0) {
        world.generate(seed: seed, settleYears: settleYears)
        change(.replaced)
    }

    public func step(years: Double) {
        world.step(dtYears: years)
        change(.advanced)
    }

    public func sculpt(gx: Double, gz: Double, radiusWorld: Double, dir: Double) {
        world.sculpt(gx: gx, gz: gz, radiusWorld: radiusWorld, dir: dir)
        change(.edited)
    }

    public func brush(_ tool: BrushTool, gx: Double, gz: Double, radiusWorld: Double,
                      strength: Double, target: Double) {
        tool.apply(to: world, gx: gx, gz: gz, radiusWorld: radiusWorld,
                   strength: strength, target: target)
        change(.edited)
    }

    public func recomputeFlow() {
        world.recomputeFlowAfterEdit()
        change(.edited)
    }

    public func load(from path: String) throws {
        let loaded = try WorldSnapshot.read(from: path)
        job.wait()
        storedWorld = loaded
        change(.replaced)
    }

    public func save(to path: String) throws -> Int {
        try WorldSnapshot.write(world, to: path)
    }

    @discardableResult
    public func beginStep(years: Double, trigger: FrameTrigger, now: Double,
                          pack: @escaping (WorldFrame) -> Packed) -> Bool {
        guard !job.isPending else { return false }
        let terrain = storedWorld, render = storedRender
        storedLastChange = .advanced
        return job.start {
            terrain.step(dtYears: years)
            Self.invalidate(terrain, render, .advanced)
            return pack(Self.frame(terrain, render, trigger, now: now))
        }
    }

    public var stepInFlight: Bool { job.isPending }

    public var stepReady: Bool { job.isReady }

    public func finishStep() -> Packed? { job.take() }

    public var stepWaitedSeconds: Double { job.waitedSeconds }
    var stepWaits: Int { job.waits }
    var stepWillBlock: (() -> Void)? {
        get { job.willBlock }
        set { job.willBlock = newValue }
    }

    public func renderFrame(_ trigger: FrameTrigger, now: Double) -> WorldFrame {
        Self.frame(world, render, trigger, now: now)
    }

    private static func frame(_ terrain: Terrain, _ render: RenderState,
                              _ trigger: FrameTrigger, now: Double) -> WorldFrame {
        let frame = render.frame(terrain, trigger, now: now)
        return WorldFrame(frame: frame, trigger: trigger, heights: terrain.h,
                          year: terrain.years, waterLevel: terrain.waterLevel,
                          bands: terrain.heightBands, ribbons: render.riverRibbonMesh)
    }

    public var config: SimConfig { world.cfg }
    public var year: Double { world.years }
    public var heights: [Double] { world.h }
    public var waterLevel: [Double] { world.waterLevel }
    public var heightBands: HeightBands { world.heightBands }
    public var flowArea: [Double] { world.area }
    public var receivers: [Int32] { world.receiver }
    func fingerprint() -> UInt64 { world.fingerprint() }
    public var pickaxeMaxRadiusWorld: Double { Terrain.pickaxeMaxCells * world.cfg.cellSize }

    public func captureDebugReference() { render.captureDebugReference(world) }
    public func debugTerrainStats() -> [Float] { render.debugTerrainStats(world) }
    public func heightDifferenceBytes(scale: Double) -> [UInt8] {
        render.heightDifferenceBytes(world, scale: scale)
    }

    public var deferWaterTail: Bool {
        get { render.deferWaterTail }
        set { render.deferWaterTail = newValue }
    }

    public var renderGrid: Int {
        get { render.renderGrid }
        set { render.renderGrid = newValue }
    }

    var riverRibbonMesh: RibbonMesh { render.riverRibbonMesh }
}

public struct WorldFrame {
    public let frame: RenderFrame
    public let trigger: FrameTrigger
    public let heights: [Double]
    public let year: Double
    public let waterLevel: [Double]
    public let bands: HeightBands
    public let ribbons: RibbonMesh
}

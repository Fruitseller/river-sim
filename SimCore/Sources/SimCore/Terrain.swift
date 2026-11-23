import Foundation

public enum BasinRole: UInt8, Sendable {
    case none = 0
    case dryBed = 1
    case water = 2

    public init(persisted byte: UInt8) {
        self = BasinRole(rawValue: byte) ?? .none
    }
}

public final class Terrain {
    public let cfg: SimConfig
    private let n: Int

    public private(set) var h: [Double]
    public private(set) var rock: [Double]
    public private(set) var sed: [Double]
    public private(set) var upliftBase: [Double]
    public private(set) var rain: [Double]
    public private(set) var rainWeight: [Double] = []
    public private(set) var runoffWeight: [Double] = []
    public var flowWeight: [Double] { runoffWeight.isEmpty ? rainWeight : runoffWeight }
    public private(set) var lithHardness: [Double] = []
    private(set) var lithErodeK: [Double] = []
    private var lithBed: [Double] = []
    private var lithProvince: [Double] = []
    public private(set) var temperature: [Double] = []
    public private(set) var snow: [Double] = []
    public private(set) var ice: [Double] = []
    public private(set) var underIce: [Bool] = []
    private var iceRate: [Double] = []
    private var iceSurf: [Double] = []
    private var iceEro: [Double] = []
    private var iceEroH: [Double] = []
    private var iceAvTarget: [Int32] = []
    private var iceAvFeed: [Double] = []
    private var iceAvPhi: [Double] = []
    public private(set) var veg: [Double]
    public private(set) var vegClass: [UInt8]
    private var riparian: [Double]
    private var vegScratch: [Double]
    private var vegScratchRow: [Double] = []
    private let vegTypeFactor: [Double]
    public private(set) var heightBands: HeightBands

    public private(set) var hf: [Double]
    public private(set) var waterLevel: [Double]
    private var lakeBalance: [Double]
    public private(set) var endorheicBasin: [BasinRole]
    public private(set) var saltCrust: [Double]
    public private(set) var endorheicInflow: [Double]
    private var playaBed: [Bool]
    private var basinSeen: [Bool]
    private var basinCells: [Int32]
    private var basinSlots: [Int32]
    private var orderPos: [Int32]
    public private(set) var receiver: [Int32]
    public private(set) var area: [Double]
    public private(set) var areaMFD: [Double]
    private var order: [Int32]
    private var floodParent: [Int32]

    private var heap: MinHeap
    private var visited: [Bool]
    private var scratch: [Double]
    private var areaPow: [Double] = []
    private var incisionGate: [Int8] = []
    private var incisionKErode: [Double] = []
    private var braidStatus: [Int8] = []
    private var carveStatus: [Bool] = []
    private var mfdRoutes: [MFDRoute] = []
    private var mfdRouteCounts: [Int8] = []
    private var mfdDispersed: [MFDDispersion] = []
    private var qs: [Double]
    private(set) var isChannel: [Bool]
    public private(set) var barAge: [Double]
    private var inBelt: [Bool]
    public private(set) var streamMap: [Double]
    private var streamRate: [Double]
    private var trackBuf: [Double]
    private var depositDampBuf: [Double] = []
    private var deltaMouthCells: [Int] = []
    private var pondSeen: [Bool]
    private var noise: SimplexNoise

    public private(set) var disturb: [Double]
    private var regenPending: [Double]
    private var disturbActive = false

    public private(set) var meander = MeanderState()

    public private(set) var years: Double = 0
    private var seed: UInt32
    private var flowStepCount: UInt32 = 0
    private var dropsEmitted: UInt64 = 0
    private var dropCarry: Double = 0
    private var beltCouplingCarry: Double = 0

    public convenience init(config: SimConfig = SimConfig(),
                            seed: UInt32 = RenderContract.defaultSeed,
                            settleYears: Double = 0) {
        self.init(allocating: config, seed: seed)
        generate(seed: seed, settleYears: settleYears)
    }

    init(allocating config: SimConfig, seed: UInt32) {
        self.cfg = config
        self.n = config.n
        self.seed = seed
        self.mfdMinA = config.braidMinCells * config.cellSize * config.cellSize
        self.mfdFlatCell = config.meanderFlatSlope * config.cellSize
        let c = config.count
        h = .init(repeating: 0, count: c)
        rock = .init(repeating: 0, count: c)
        sed = .init(repeating: 0, count: c)
        upliftBase = .init(repeating: 0, count: c)
        rain = .init(repeating: 0, count: c)
        veg = .init(repeating: 0, count: c)
        vegClass = .init(repeating: 0, count: c)
        disturb = .init(repeating: 0, count: c)
        regenPending = .init(repeating: 0, count: c)
        riparian = .init(repeating: 0, count: c)
        vegScratch = .init(repeating: 0, count: c)
        vegTypeFactor = [1, 1, config.vegTypeFactorForest, config.vegTypeFactorRiparian]
        heightBands = config.heightBandsOverride ?? .legacyAbsolute
        hf = .init(repeating: 0, count: c)
        waterLevel = .init(repeating: 0, count: c)
        lakeBalance = .init(repeating: 0, count: c)
        endorheicBasin = .init(repeating: .none, count: c)
        saltCrust = .init(repeating: 0, count: c)
        endorheicInflow = .init(repeating: 0, count: c)
        playaBed = .init(repeating: false, count: c)
        basinSeen = .init(repeating: false, count: c)
        basinCells = []
        basinSlots = []
        orderPos = .init(repeating: 0, count: c)
        receiver = .init(repeating: -1, count: c)
        area = .init(repeating: 0, count: c)
        areaMFD = .init(repeating: 0, count: c)
        order = .init(repeating: 0, count: c)
        floodParent = .init(repeating: -1, count: c)
        visited = .init(repeating: false, count: c)
        scratch = .init(repeating: 0, count: c)
        qs = .init(repeating: 0, count: c)
        isChannel = .init(repeating: false, count: c)
        barAge = .init(repeating: -1, count: c)
        inBelt = .init(repeating: false, count: c)
        streamMap = .init(repeating: 0, count: c)
        streamRate = .init(repeating: 0, count: c)
        trackBuf = .init(repeating: 0, count: c)
        pondSeen = .init(repeating: false, count: c)
        heap = MinHeap(capacity: c)
        noise = SimplexNoise(seed: seed)
    }

    @inline(__always) func idx(_ i: Int, _ j: Int) -> Int { j * n + i }

    @inline(__always) private func mark(_ name: @autoclosure () -> String?) {
        if SimProfile.enabled { SimProfile.mark(name()) }
    }

    private static let coreCount = ProcessInfo.processInfo.activeProcessorCount

    @inline(__always) private func parallel(_ count: Int, _ body: (Int, Int) -> Void) {
        let chunks = min(count, max(1, Terrain.coreCount * 4))
        if chunks <= 1 { body(0, count); return }
        nonisolated(unsafe) let unsafeBody = body
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            unsafeBody(count * c / chunks, count * (c + 1) / chunks)
        }
    }

    @inline(__always) private func fill<T>(_ array: inout [T], _ value: T) {
        array.withUnsafeMutableBufferPointer { b in
            guard let p = b.baseAddress else { return }
            p.update(repeating: value, count: b.count)
        }
    }

    @inline(__always) private func anyCell<T>(_ array: [T], _ predicate: (T) -> Bool) -> Bool {
        array.withUnsafeBufferPointer { b in
            guard let p = b.baseAddress else { return false }
            for k in 0..<b.count where predicate(p[k]) { return true }
            return false
        }
    }

    @inline(__always)
    public static func relaxFraction(dt: Double, tau: Double) -> Double {
        1 - exp(-dt / tau)
    }

    @inline(__always)
    public static func gridRound(_ c: Double) -> Int {
        c >= 0 ? (c < 0.5 ? 0 : Int(c + 0.5)) : (c > -0.5 ? 0 : Int(c - 0.5))
    }

    @inline(__always)
    public static func cellIndex(_ x: Double, _ z: Double, n: Int) -> Int {
        min(max(gridRound(z), 0), n - 1) * n + min(max(gridRound(x), 0), n - 1)
    }

    private func resetToAllocated(seed: UInt32) {
        self.seed = seed
        self.years = 0
        self.dropsEmitted = 0
        self.flowStepCount = 0
        self.dropCarry = 0
        self.beltCouplingCarry = cfg.meanderBeltCouplingYears
        self.disturbActive = false
        self.beltSubsteps = 0
        self.beltCouplingLog = nil
        self.noise = SimplexNoise(seed: seed)
        self.meander = MeanderState()
        self.heightBands = cfg.heightBandsOverride ?? .legacyAbsolute

        rainWeight = []
        runoffWeight = []
        lithHardness = []
        lithErodeK = []
        lithBed = []
        lithProvince = []
        temperature = []
        snow = []
        ice = []
        underIce = []
        iceRate = []
        iceSurf = []
        iceEro = []
        iceEroH = []
        iceAvTarget = []
        iceAvFeed = []
        iceAvPhi = []
        vegScratchRow = []
        areaPow = []
        depositDampBuf = []
        dropletGateBuf = []
        segOwner = []
        segPos = []
        deltaMouthCells.removeAll(keepingCapacity: true)
        basinCells.removeAll(keepingCapacity: true)
        basinSlots.removeAll(keepingCapacity: true)

        fill(&h, 0)
        fill(&rock, 0)
        fill(&sed, 0)
        fill(&upliftBase, 0)
        fill(&rain, 0)
        fill(&veg, 0)
        fill(&vegClass, 0)
        fill(&disturb, 0)
        fill(&regenPending, 0)
        fill(&riparian, 0)
        fill(&vegScratch, 0)
        fill(&hf, 0)
        fill(&waterLevel, 0)
        fill(&lakeBalance, 0)
        fill(&endorheicBasin, .none)
        fill(&saltCrust, 0)
        fill(&endorheicInflow, 0)
        fill(&playaBed, false)
        fill(&basinSeen, false)
        fill(&orderPos, 0)
        fill(&receiver, -1)
        fill(&area, 0)
        fill(&areaMFD, 0)
        fill(&order, 0)
        fill(&floodParent, -1)
        fill(&visited, false)
        fill(&scratch, 0)
        fill(&qs, 0)
        fill(&isChannel, false)
        fill(&barAge, -1)
        fill(&inBelt, false)
        fill(&streamMap, 0)
        fill(&streamRate, 0)
        fill(&trackBuf, 0)
        fill(&pondSeen, false)
        heap = MinHeap(capacity: cfg.count)
    }

    public func generate(seed: UInt32, settleYears: Double = 0) {
        resetToAllocated(seed: seed)

        let (box, boy) = cfg.rangeLandform ? generateRangeRelief(seed: seed)
                                           : generateLegacyRelief(seed: seed)
        if cfg.preErodeEnabled {
            ErosionFilter.apply(h: &h, n: n, sea: cfg.sea,
                                seedOffsetX: box, seedOffsetY: boy,
                                params: cfg.preErodeParams)
        }
        initLayers()
        buildLithologyField()
        updateLithology()
        for k in 0..<cfg.count {
            lakeBalance[k] = h[k]
            endorheicBasin[k] = .none
            saltCrust[k] = 0
            disturb[k] = 0
            barAge[k] = -1
            regenPending[k] = 0
        }
        disturbActive = false
        temperature = []; snow = []; ice = []
        underIce = []
        computeFlow()
        if cfg.breachEnabled { breachBasins() }
        spinUpStreamMap()
        if cfg.breachEnabled { breachBasins() }
        updateClimate(dt: 10000)
        updateVegetation(years: 10000)
        seedMeander()
        if settleYears > 0 {
            var remaining = settleYears
            while remaining > 0 {
                let dt = min(1000, remaining)
                step(dtYears: dt)
                remaining -= dt
            }
            years = 0
            for ci in meander.channels.indices { meander.channels[ci].born = [] }
        }
        waterLevel = hf
        for k in 0..<cfg.count where playaBed[k] { saltCrust[k] = 1 }
    }

    private func generateRangeRelief(seed: UInt32) -> (Double, Double) {
        var gr = Mulberry32(seed: seed ^ 0x1234_abcd)
        let box = gr.next() * 1000, boy = gr.next() * 1000
        let cx = Double(n - 1) / 2
        let ccx = cx + (gr.next() - 0.5) * 0.12 * Double(n)
        let ccy = cx + (gr.next() - 0.5) * 0.12 * Double(n)
        let aAng = gr.next() * .pi
        let aRatio = 0.55 + gr.next() * 1.05
        let fStart = 0.55 + gr.next() * 0.15
        let fWidth = 0.30 + gr.next() * 0.15
        let relief = cfg.baseRelief * (0.80 + gr.next() * 0.45)
        let roll = gr.next() * gr.next() * 0.7
        let mFreqK = 0.22 + gr.next() * 0.42
        _ = gr.next()
        let bfMul = 0.72 + gr.next() * 0.75
        let sharp = 1.0 + gr.next() * 0.9
        let archetype = Int(gr.next() * 3.0)
        let coastAng = gr.next() * 2 * .pi

        @inline(__always) func smooth(_ a: Double, _ b: Double, _ v: Double) -> Double {
            let t = min(max((v - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
        }

        let ca = cos(aAng), sa = sin(aAng)
        var axisDir = aRatio < 1 ? SIMD2(-sa, ca) : SIMD2(ca, sa)
        var axisCenter = SIMD2(ccx, ccy)
        let longSemi = fStart * cx
        if archetype == 1 {
            let cd = SIMD2(cos(coastAng), sin(coastAng))
            axisDir = SIMD2(-cd.y, cd.x)
            axisCenter = SIMD2(cx, cx) - 0.18 * Double(n) * cd
        }
        var lr = Mulberry32(seed: seed ^ 0x7a11_4e5d)
        let skeleton = RangeSkeleton(n: n, rng: &lr, center: axisCenter, axisDir: axisDir,
                                     halfLength: min(0.42 * Double(n), 0.75 * longSemi))
        let form = skeleton.evaluate(n: n)

        let uNoise = SimplexNoise(seed: seed ^ 0x5eed)
        var uRnd = Mulberry32(seed: seed ^ 0x5eed)
        let uox = uRnd.next() * 1000, uoy = uRnd.next() * 1000
        let uFreq = cfg.upliftFreq / Double(n)
        for j in 0..<n {
            for i in 0..<n {
                let ridge = uNoise.ridged01(Double(i) * uFreq + uox,
                                            Double(j) * uFreq + uoy, octaves: 5)
                upliftBase[idx(i, j)] = (ridge * 1.15 - 0.22) * form.mountain[idx(i, j)]
            }
        }

        let bf = cfg.baseFreq / Double(n)
        let plainBase = 0.20
        let valleyHeadRise = 0.10
        let borderMargin = 0.033 * Double(n)
        let borderRamp = 0.10 * Double(n)
        let borderWobble = 0.04 * Double(n)
        for j in 0..<n {
            for i in 0..<n {
                let k = idx(i, j)
                let x = Double(i) * bf * bfMul + box, y = Double(j) * bf * bfMul + boy
                let ridge = noise.ridged01(x, y, octaves: cfg.baseOctaves)
                let rollv = noise.fbm01(x, y, octaves: 6)
                let base = (1 - roll) * ridge + roll * rollv
                let massif = noise.fbm01(x * mFreqK, y * mFreqK, octaves: 3)
                let ridgeE = 0.38 + 0.62 * pow(base, sharp)
                let mountain = ridgeE * relief * (0.40 + 0.50 * massif)
                let hills = relief * 0.40 * base * (0.5 + 0.5 * massif)
                let plain = plainBase + 0.03 * (noise.fbm01(x * 0.5 + 70, y * 0.5 + 70, octaves: 3) - 0.5)
                let wm = form.mountain[k]
                let land = plain + valleyHeadRise * form.rise[k]
                    + form.hill[k] * (1 - wm) * hills + wm * mountain
                let dx = Double(i) - ccx, dy = Double(j) - ccy
                let rx = dx * ca + dy * sa
                let ry = (-dx * sa + dy * ca) * aRatio
                let d = (rx * rx + ry * ry).squareRoot() / cx / min(1, aRatio)
                var falloff = 1 - smooth(fStart, fStart + fWidth, d)
                if archetype == 1 {
                    let proj = (Double(i) - cx) * cos(coastAng) + (Double(j) - cx) * sin(coastAng)
                    let wob = (noise.fbm01(x * 0.6 + 30, y * 0.6 + 30, octaves: 3) - 0.5) * 0.5
                    let g = proj / Double(n) + wob
                    falloff = min(falloff, 1 - smooth(0.0, 0.26, g))
                } else if archetype == 2 {
                    let isl = noise.fbm01(x * 0.7 + 50, y * 0.7 + 50, octaves: 4)
                    falloff *= smooth(0.34, 0.52, isl)
                }
                let bd = Double(min(min(i, j), min(n - 1 - i, n - 1 - j)))
                let bw = bd + borderWobble * (noise.fbm01(x * 0.8 + 90, y * 0.8 + 90, octaves: 3) - 0.5)
                falloff = min(falloff, smooth(borderMargin, borderMargin + borderRamp, bw))
                h[k] = land * falloff
            }
        }
        return (box, boy)
    }

    private func generateLegacyRelief(seed: UInt32) -> (Double, Double) {
        let uNoise = SimplexNoise(seed: seed ^ 0x5eed)
        var uRnd = Mulberry32(seed: seed ^ 0x5eed)
        let uox = uRnd.next() * 1000, uoy = uRnd.next() * 1000
        let uFreq = cfg.upliftFreq / Double(n)
        for j in 0..<n {
            for i in 0..<n {
                let ridge = uNoise.ridged01(Double(i) * uFreq + uox,
                                            Double(j) * uFreq + uoy, octaves: 5)
                upliftBase[idx(i, j)] = ridge * 1.15 - 0.22
            }
        }

        var gr = Mulberry32(seed: seed ^ 0x1234_abcd)
        let box = gr.next() * 1000, boy = gr.next() * 1000
        let cx = Double(n - 1) / 2
        let ccx = cx + (gr.next() - 0.5) * 0.34 * Double(n)
        let ccy = cx + (gr.next() - 0.5) * 0.34 * Double(n)
        let aAng = gr.next() * .pi
        let aRatio = 0.55 + gr.next() * 1.05
        let fStart = 0.58 + gr.next() * 0.30
        let fWidth = 0.18 + gr.next() * 0.26
        let relief = cfg.baseRelief * (0.80 + gr.next() * 0.45)
        let roll = gr.next() * gr.next() * 0.7
        let mFreqK = 0.22 + gr.next() * 0.42
        let mBias = 0.38 + gr.next() * 0.26
        let bfMul = 0.72 + gr.next() * 0.75
        let sharp = 1.0 + gr.next() * 0.9
        let archetype = Int(gr.next() * 3.0)
        let coastAng = gr.next() * 2 * .pi

        @inline(__always) func smooth(_ a: Double, _ b: Double, _ v: Double) -> Double {
            let t = min(max((v - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
        }

        let bf = cfg.baseFreq / Double(n)
        let ca = cos(aAng), sa = sin(aAng)
        for j in 0..<n {
            for i in 0..<n {
                let x = Double(i) * bf * bfMul + box, y = Double(j) * bf * bfMul + boy
                let ridge = noise.ridged01(x, y, octaves: cfg.baseOctaves)
                let rollv = noise.fbm01(x, y, octaves: 6)
                let base = (1 - roll) * ridge + roll * rollv
                let massif = noise.fbm01(x * mFreqK, y * mFreqK, octaves: 3)
                let m = mBias + (1 - mBias) * massif
                let dx = Double(i) - ccx, dy = Double(j) - ccy
                let rx = dx * ca + dy * sa
                let ry = (-dx * sa + dy * ca) * aRatio
                let d = (rx * rx + ry * ry).squareRoot() / cx
                var falloff = 1 - smooth(fStart, fStart + fWidth, d)
                if archetype == 1 {
                    let proj = (Double(i) - cx) * cos(coastAng) + (Double(j) - cx) * sin(coastAng)
                    let wob = (noise.fbm01(x * 0.6 + 30, y * 0.6 + 30, octaves: 3) - 0.5) * 0.5
                    let g = proj / Double(n) + wob
                    falloff = min(falloff, 1 - smooth(0.0, 0.26, g))
                } else if archetype == 2 {
                    let isl = noise.fbm01(x * 0.7 + 50, y * 0.7 + 50, octaves: 4)
                    falloff *= smooth(0.34, 0.52, isl)
                }
                let ridgeE = 0.38 + 0.62 * pow(base, sharp)
                h[idx(i, j)] = ridgeE * relief * m * falloff
            }
        }
        return (box, boy)
    }

    public func snapWaterLevel() { waterLevel = hf }

    private func spinUpStreamMap() {
        fill(&streamRate, 0)
        fill(&streamMap, 0)
        guard cfg.hydraulicEnabled else { return }
        let density = Double(n * n) / (640.0 * 640.0)
        for round in 0..<4 {
            fill(&trackBuf, 0)
            let drops = max(200, Int(2000 * density))
            let dtEq = Double(drops) / max(1e-9, cfg.hydraulicPerYear * density)
            Hydraulic.erode(h: &h, rock: &rock, sed: &sed, n: n, count: drops,
                            seed: seed &+ UInt32(0x9e37 + round), floor: cfg.floor,
                            p: cfg.hydraulic,
                            seaLevel: cfg.hydraulicSkipWaterSpawns ? cfg.sea : nil,
                            hf: hf, receiver: receiver,
                            stream: streamMap,
                            flowWeight: flowWeight,
                            erodibility: lithErodeK,
                            track: &trackBuf)
            for k in 0..<cfg.count {
                streamRate[k] = 0.5 * streamRate[k] + 0.5 * (trackBuf[k] / dtEq)
            }
            deriveStreamMap()
        }
        computeFlow()
    }

    private func breachBasins() {
        floodAndRoute(dt: 0, applyBalance: false)
        for _ in 0..<cfg.breachMaxRounds {
            let s = lakeStats()
            let land = Double(landCellCount())
            if s.fraction < cfg.breachTargetLakeFrac && Double(s.largest) < 0.025 * land { break }
            outletIncision(dt: cfg.breachDT, minAreaCells: 100)
            floodAndRoute(dt: 0, applyBalance: false)
        }
        computeFlow()
    }

    @inline(__always) private func powFast(_ s: Double, _ p: Double) -> Double {
        if p == 4.0 { let s2 = s * s; return s2 * s2 }
        if p == 2.0 { return s * s }
        return pow(s, p)
    }

    private func deriveStreamMap() {
        let r0 = cfg.streamRefRate
        for k in 0..<cfg.count {
            streamMap[k] = streamRate[k] / (streamRate[k] + r0)
        }
    }

    public func endorheicStats() -> (basins: Int, water: Int, dryBed: Int) {
        var water = 0, dryBed = 0
        for k in 0..<cfg.count {
            if endorheicBasin[k] == .water { water += 1 }
            else if endorheicBasin[k] == .dryBed { dryBed += 1 }
        }
        guard water + dryBed > 0 else { return (0, 0, 0) }
        var seen = [Bool](repeating: false, count: cfg.count)
        var stack = [Int]()
        var basins = 0
        for start in 0..<cfg.count where endorheicBasin[start] != .none && !seen[start] {
            basins += 1
            stack.removeAll(keepingCapacity: true); stack.append(start); seen[start] = true
            while let k = stack.popLast() {
                let i = k % n, j = k / n
                for dj in -1...1 {
                    for di in -1...1 {
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                        let nb = nj * n + ni
                        if endorheicBasin[nb] != .none && !seen[nb] { seen[nb] = true; stack.append(nb) }
                    }
                }
            }
        }
        return (basins, water, dryBed)
    }

    public func lakeStats(depth: Double = 0.01) -> (fraction: Double, largest: Int) {
        var wet = 0, land = 0
        var isLake = [Bool](repeating: false, count: cfg.count)
        for k in 0..<cfg.count where hf[k] > cfg.sea {
            land += 1
            if hf[k] - h[k] > depth { wet += 1; isLake[k] = true }
        }
        var seen = [Bool](repeating: false, count: cfg.count)
        var largest = 0
        var stack = [Int]()
        for start in 0..<cfg.count where isLake[start] && !seen[start] {
            stack.removeAll(keepingCapacity: true); stack.append(start); seen[start] = true
            var size = 0
            while let k = stack.popLast() {
                size += 1
                let i = k % n, j = k / n
                if i > 0 && isLake[k-1] && !seen[k-1] { seen[k-1] = true; stack.append(k-1) }
                if i < n-1 && isLake[k+1] && !seen[k+1] { seen[k+1] = true; stack.append(k+1) }
                if j > 0 && isLake[k-n] && !seen[k-n] { seen[k-n] = true; stack.append(k-n) }
                if j < n-1 && isLake[k+n] && !seen[k+n] { seen[k+n] = true; stack.append(k+n) }
            }
            largest = max(largest, size)
        }
        return (land == 0 ? 0 : Double(wet) / Double(land), largest)
    }

    private func buildLithologyField() {
        guard cfg.lithologyEnabled else {
            lithBed = []; lithProvince = []; lithHardness = []; lithErodeK = []
            return
        }
        let c = cfg.count
        if lithBed.count != c {
            lithBed = .init(repeating: 0, count: c)
            lithProvince = .init(repeating: 0, count: c)
            lithHardness = .init(repeating: 0, count: c)
            lithErodeK = .init(repeating: 1, count: c)
        }
        let lNoise = SimplexNoise(seed: seed ^ 0x1170)
        var lr = Mulberry32(seed: seed ^ 0x1170)
        let lox = lr.next() * 1000, loy = lr.next() * 1000
        let dipAng = lr.next() * 2 * .pi
        let dip = cfg.lithDip * (0.4 + 1.2 * lr.next())
        let dx = cos(dipAng) * dip / Double(n - 1)
        let dy = sin(dipAng) * dip / Double(n - 1)
        let warpFreq = 2.2 / Double(n)
        let provFreq = 1.6 / Double(n)
        for j in 0..<n {
            for i in 0..<n {
                let k = idx(i, j)
                let x = Double(i), y = Double(j)
                let warp = lNoise.fbm01(x * warpFreq + lox, y * warpFreq + loy, octaves: 3) * 2 - 1
                lithBed[k] = x * dx + y * dy + warp * cfg.lithWarp
                let prov = lNoise.fbm01(x * provFreq + lox + 500, y * provFreq + loy + 500,
                                        octaves: 3) * 2 - 1
                lithProvince[k] = min(1, max(-1, prov * 1.8))
            }
        }
    }

    private func updateLithology() {
        guard cfg.lithologyEnabled, lithBed.count == cfg.count else { return }
        let thick = max(1e-9, cfg.lithLayerThickness)
        let mix = min(1, max(0, cfg.lithProvinceMix))
        let bias = cfg.lithHardBias
        let contrast = cfg.lithContrast
        let cnt = cfg.count
        h.withUnsafeBufferPointer { hb in
        lithBed.withUnsafeBufferPointer { bb in
        lithProvince.withUnsafeBufferPointer { pb in
        lithHardness.withUnsafeMutableBufferPointer { hdb in
        lithErodeK.withUnsafeMutableBufferPointer { kb in
            let ph = hb.baseAddress!, pbed = bb.baseAddress!, pprov = pb.baseAddress!
            let phard = hdb.baseAddress!, pk = kb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi {
                    let s = (ph[k] - pbed[k]) / thick
                    let frac = s - s.rounded(.down)
                    let tri = abs(2 * frac - 1)
                    let sm = tri * tri * (3 - 2 * tri)
                    let wave = 2 * sm - 1
                    var hard = (1 - mix) * wave + mix * pprov[k] + bias
                    hard = min(1, max(-1, hard))
                    phard[k] = hard
                    pk[k] = max(0.05, 1 - contrast * hard)
                }
            }
        }}}}}
    }

    private func initLayers() {
        let sedInit = 0.02
        for k in 0..<cfg.count {
            sed[k] = min(sedInit, max(h[k] - cfg.floor, 0))
            rock[k] = h[k] - sed[k]
        }
    }

    public func computeRain() {
        let nn = n, sea = cfg.sea
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeMutableBufferPointer { rb in
        let ph = hb.baseAddress!, prain = rb.baseAddress!
        parallel(nn) { jLo, jHi in
        for j in jLo..<jHi {
            var m = 1.0
            let k0 = j * nn
            var hs = ph[k0] <= sea ? sea : ph[k0]
            for i in 0..<nn {
                let k = k0 + i
                if ph[k] <= sea {
                    m = min(1, m + 0.015)
                    prain[k] = m
                    hs = sea
                    continue
                }
                prain[k] = m
                let hsNew = hs + 0.25 * (ph[k] - hs)
                let uph = max(0, hsNew - hs)
                hs = hsNew
                m = max(0.18, m - m * (0.0012 + uph * 1.5))
            }
        }
        }
        }}
        updateRainWeight()
        updateRunoffWeight()
    }

    private func updateRainWeight() {
        guard cfg.rainWeightedFlow else {
            if !rainWeight.isEmpty { rainWeight = [] }
            return
        }
        let cnt = cfg.count, sea = cfg.sea
        if rainWeight.count != cnt { rainWeight = .init(repeating: 1, count: cnt) }
        var sum = 0.0, land = 0
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeBufferPointer { rb in
            let ph = hb.baseAddress!, prain = rb.baseAddress!
            for k in 0..<cnt where ph[k] > sea { sum += prain[k]; land += 1 }
        }}
        let mean = land == 0 ? 0 : sum / Double(land)
        guard mean > 1e-9 else {
            rainWeight.withUnsafeMutableBufferPointer { $0.update(repeating: 1) }
            return
        }
        let inv = 1 / mean
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeBufferPointer { rb in
        rainWeight.withUnsafeMutableBufferPointer { wb in
            let ph = hb.baseAddress!, prain = rb.baseAddress!, pw = wb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi { pw[k] = ph[k] > sea ? prain[k] * inv : 1.0 }
            }
        }}}
    }

    private func updateRunoffWeight() {
        let cnt = cfg.count
        guard cfg.meltRunoffEnabled, cfg.climateEnabled,
              rainWeight.count == cnt, snow.count == cnt, temperature.count == cnt else {
            if !runoffWeight.isEmpty { runoffWeight = [] }
            return
        }
        if runoffWeight.count != cnt { runoffWeight = .init(repeating: 1, count: cnt) }
        let sea = cfg.sea
        let tFreeze = cfg.snowFreezeTemp
        let phaseSpan = max(1e-9, cfg.snowRainTemp - tFreeze)
        let tRain = cfg.snowRainTemp
        let withhold = min(1, max(0, cfg.meltRunoffWithholdSolid))
        let meltToRain = cfg.snowMeltPerKYear / max(1e-12, cfg.snowAccumPerYear)
        let cap = max(0, cfg.meltRunoffCapPerRain)
        var rawSum = 0.0, rainSum = 0.0, land = 0
        var anyMelt = false
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeBufferPointer { rnb in
        temperature.withUnsafeBufferPointer { tb in
        snow.withUnsafeBufferPointer { sb in
        runoffWeight.withUnsafeMutableBufferPointer { wb in
            let ph = hb.baseAddress!, prain = rnb.baseAddress!
            let pt = tb.baseAddress!, ps = sb.baseAddress!, pw = wb.baseAddress!
            for k in 0..<cnt {
                guard ph[k] > sea else { pw[k] = 1.0; continue }
                let t = pt[k]
                var raw = prain[k]
                if withhold > 0 && t < tRain {
                    let fSnow = min(1, max(0, (tRain - t) / phaseSpan))
                    raw -= withhold * prain[k] * fSnow
                    if raw < 0 { raw = 0 }
                }
                if t > 0 && ps[k] > 0 {
                    raw += min(meltToRain * t * ps[k], cap * prain[k])
                }
                if raw != prain[k] { anyMelt = true }
                pw[k] = raw
                rawSum += raw
                rainSum += prain[k]
                land += 1
            }
        }}}}}
        let mean = land == 0 ? 0 : (cfg.meltRunoffNormalized ? rawSum : rainSum) / Double(land)
        guard anyMelt, mean > 1e-9 else {
            runoffWeight = []
            return
        }
        let inv = 1 / mean
        let ceiling = 1 + cap
        h.withUnsafeBufferPointer { hb in
        rainWeight.withUnsafeBufferPointer { rwb in
        runoffWeight.withUnsafeMutableBufferPointer { wb in
            let ph = hb.baseAddress!, prw = rwb.baseAddress!, pw = wb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi where ph[k] > sea {
                    pw[k] = min(pw[k] * inv, ceiling * prw[k])
                }
            }
        }}}
    }

    public func updateClimate(dt: Double) {
        guard cfg.climateEnabled else {
            if !temperature.isEmpty { temperature = [] }
            if !snow.isEmpty { snow = [] }
            if !ice.isEmpty { ice = [] }
            return
        }
        let cnt = cfg.count
        if temperature.count != cnt { temperature = .init(repeating: 0, count: cnt) }
        if snow.count != cnt { snow = .init(repeating: 0, count: cnt) }
        if ice.count != cnt { ice = .init(repeating: 0, count: cnt) }
        let sea = cfg.sea
        let t0 = cfg.climateSeaLevelTemp, gamma = cfg.climateLapseRate
        let tFreeze = cfg.snowFreezeTemp
        let phaseSpan = max(1e-9, cfg.snowRainTemp - tFreeze)
        let tRain = cfg.snowRainTemp
        let accum = cfg.snowAccumPerYear
        let base = 1 / max(1e-9, cfg.snowTurnoverYears)
        let melt = cfg.snowMeltPerKYear
        let holdSnow = (dt == 0)
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeBufferPointer { rnb in
        temperature.withUnsafeMutableBufferPointer { tb in
        snow.withUnsafeMutableBufferPointer { sb in
            let ph = hb.baseAddress!, prain = rnb.baseAddress!
            let pt = tb.baseAddress!, ps = sb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi {
                    let t = t0 - gamma * max(0, ph[k] - sea)
                    pt[k] = t
                    if holdSnow { continue }
                    let fSnow = min(1, max(0, (tRain - t) / phaseSpan))
                    let a = accum * prain[k] * fSnow
                    if a == 0 && ps[k] == 0 { continue }
                    let mu = base + melt * max(0, t)
                    let target = a / mu
                    ps[k] = target + (ps[k] - target) * exp(-mu * dt)
                }
            }
        }}}}
    }

    @inline(__always) public static func snowCoverage(swe: Double, ref: Double) -> Double {
        swe / (swe + ref)
    }

    @inline(__always) public func snowCover(_ k: Int) -> Double {
        guard snow.count == cfg.count else { return heightBands.snowAmount(h[k]) }
        return Terrain.snowCoverage(swe: snow[k], ref: cfg.snowCoverRef)
    }

    private func snowAreaFractions() -> (ramp: Double, full: Double)? {
        guard cfg.climateEnabled, snow.count == cfg.count else { return nil }
        let sea = cfg.sea, ref = cfg.snowCoverRef
        let cStart = cfg.snowBandCoverStart, cFull = cfg.snowBandCoverFull
        let cnt = cfg.count
        var land = 0, ramp = 0, full = 0
        h.withUnsafeBufferPointer { hb in
        snow.withUnsafeBufferPointer { sb in
            let ph = hb.baseAddress!, psnow = sb.baseAddress!
            for k in 0..<cnt where ph[k] > sea {
                land += 1
                let c = Terrain.snowCoverage(swe: psnow[k], ref: ref)
                if c > cStart { ramp += 1 }
                if c >= cFull { full += 1 }
            }
        }}
        guard land > 0 else { return nil }
        return (Double(ramp) / Double(land), Double(full) / Double(land))
    }

    public func updateIce(dt: Double) {
        let cnt = cfg.count
        guard cfg.iceEnabled, cfg.climateEnabled, dt > 0,
              ice.count == cnt, snow.count == cnt, temperature.count == cnt else {
            if !underIce.isEmpty { underIce = [] }
            return
        }
        let firnT = cfg.iceFirnTemp
        var active = anyCell(ice) { $0 > 0 }
        if !active {
            active = temperature.withUnsafeBufferPointer { tb in
            snow.withUnsafeBufferPointer { sb in
                let pt = tb.baseAddress!, ps = sb.baseAddress!
                for k in 0..<cnt where pt[k] < firnT && ps[k] > 0 { return true }
                return false
            }}
        }
        guard active else {
            if !underIce.isEmpty { underIce = [] }
            return
        }
        if iceRate.count != cnt { iceRate = .init(repeating: 0, count: cnt) }
        if iceSurf.count != cnt { iceSurf = .init(repeating: 0, count: cnt) }
        if iceEro.count != cnt { iceEro = .init(repeating: 0, count: cnt) }
        if iceEroH.count != cnt { iceEroH = .init(repeating: 0, count: cnt) }
        let refN = 639.0, m1 = Double(n - 1)
        let kYear = cfg.iceFlowK * (m1 * m1) / (refN * refN) / 100.0
        var domain = iceTransportDomain()
        guard domain.iLo <= domain.iHi else { rebuildIceMask(); return }
        let avalanche = iceAvalancheMap(domain: &domain)
        let totalK = kYear * dt * domain.scale
        let nSub = max(1, Int((totalK / max(1e-9, cfg.iceFlowSubCap)).rounded(.up)))
        let subK = kYear * dt / Double(nSub)
        let subDt = dt / Double(nSub)
        let swath = max(0, cfg.iceErodeSwathRadius)
        let halo = max(1, swath)
        let nn = n
        var curLo = domain.rowLo, curHi = domain.rowHi
        for _ in 0..<nSub {
            let p2 = Terrain.dilateRows(curLo, curHi, by: 1, in: nn)
            curLo = p2.lo; curHi = p2.hi
            let p1 = Terrain.dilateRows(p2.lo, p2.hi, by: halo, in: nn)
            iceFlowSubStep(kappa: subK, dt: subDt, p1Lo: p1.lo, p1Hi: p1.hi, p2Lo: p2.lo, p2Hi: p2.hi,
                           avalanche: avalanche)
        }
        if let avalanche { clearAvalancheFeed(avalanche) }
        rebuildIceMask()
    }

    private static func dilateRows(_ lo: [Int], _ hi: [Int], by r: Int, in nn: Int) -> (lo: [Int], hi: [Int]) {
        var outLo = [Int](repeating: nn, count: nn), outHi = [Int](repeating: -1, count: nn)
        for j in 0..<nn {
            var l = nn, h = -1
            for q in max(0, j - r)...min(nn - 1, j + r) where hi[q] >= lo[q] {
                if lo[q] < l { l = lo[q] }
                if hi[q] > h { h = hi[q] }
            }
            if h >= 0 { outLo[j] = max(0, l - r); outHi[j] = min(nn - 1, h + r) }
        }
        return (outLo, outHi)
    }

    private struct IceAvalanche {
        var src: [Int], dst: [Int], phi: [Double]
    }
    private func clearAvalancheFeed(_ av: IceAvalanche) {
        iceAvFeed.withUnsafeMutableBufferPointer { fb in
            let pf = fb.baseAddress!
            for s in 0..<av.src.count { pf[av.src[s]] = 0; pf[av.dst[s]] = 0 }
        }
    }

    private func iceAvalancheMap(domain: inout IceDomain) -> IceAvalanche? {
        let hiS = cfg.iceAvalancheSlopeHi
        guard hiS > 0, cfg.cellSize > 0, n >= 8 else { return nil }
        let nn = n, cnt = cfg.count
        let sea = cfg.sea, t0 = cfg.climateSeaLevelTemp, gamma = cfg.climateLapseRate
        let firnT = cfg.iceFirnTemp
        let toMacro = cfg.cellSize / (2 * RenderContract.heightScale)
        let loM = max(0, cfg.iceAvalancheSlopeLo) * toMacro
        let spanM = max(1e-12, hiS * toMacro - loM)
        let maxRun = max(1, cfg.iceAvalancheMaxRun)
        if iceAvTarget.count != cnt { iceAvTarget = .init(repeating: -1, count: cnt) }
        if iceAvFeed.count != cnt { iceAvFeed = .init(repeating: 0, count: cnt) }
        if iceAvPhi.count != cnt { iceAvPhi = .init(repeating: 0, count: cnt) }
        let rowLo = max(2, domain.jLo), rowHi = min(nn - 3, domain.jHi)
        let colLo = max(2, domain.iLo), colHi = min(nn - 3, domain.iHi)
        guard rowLo <= rowHi, colLo <= colHi else { return nil }
        var rowCount = [Int](repeating: 0, count: nn)
        let reachC = max(0, cfg.iceAvalancheReach)
        let slopeAround = { (ph: UnsafePointer<Double>, i: Int, j: Int) -> Double in
            var sl = Terrain.macroSlope(ph, j * nn + i, nn)
            if reachC > 0 {
                for dj in -reachC...reachC { for di in -reachC...reachC {
                    let ii = i + di, jj = j + dj
                    if ii < 2 || ii > nn - 3 || jj < 2 || jj > nn - 3 { continue }
                    sl = max(sl, Terrain.macroSlope(ph, jj * nn + ii, nn))
                } }
            }
            return sl
        }
        h.withUnsafeBufferPointer { hb in
        snow.withUnsafeBufferPointer { sb in
        iceAvTarget.withUnsafeMutableBufferPointer { tb in
        iceAvPhi.withUnsafeMutableBufferPointer { fb in
        rowCount.withUnsafeMutableBufferPointer { cb in
            let ph = hb.baseAddress!, psnow = sb.baseAddress!
            let pt = tb.baseAddress!, pc = cb.baseAddress!, pf = fb.baseAddress!
            parallel(rowHi - rowLo + 1) { lo, hi in
                for j in (rowLo + lo)..<(rowLo + hi) {
                    var count = 0
                    for i in colLo...colHi {
                        let k = j * nn + i
                        pt[k] = -1
                        guard psnow[k] > 0, ph[k] > sea,
                              t0 - gamma * (ph[k] - sea) < firnT else { continue }
                        let sl = slopeAround(ph, i, j)
                        guard sl > loM else { continue }
                        var x = (sl - loM) / spanM
                        x = min(1, max(0, x))
                        let f = x * x * (3 - 2 * x)
                        guard f > 0 else { continue }
                        pf[k] = f
                        var c = k, ci = i, cj = j
                        var run = 0
                        while run < maxRun {
                            var best = -1, bi = 0, bj = 0, bd = 0.0
                            for dj in -1...1 { for di in -1...1 where di != 0 || dj != 0 {
                                let ii = ci + di, jj = cj + dj
                                if ii < 2 || ii > nn - 3 || jj < 2 || jj > nn - 3 { continue }
                                let q = jj * nn + ii
                                let drop = (ph[c] - ph[q]) / (di != 0 && dj != 0 ? 1.4142135623730951 : 1)
                                if drop > bd { bd = drop; best = q; bi = ii; bj = jj }
                            } }
                            if best < 0 || ph[best] <= sea { break }
                            c = best; ci = bi; cj = bj; run += 1
                            if Terrain.macroSlope(ph, c, nn) <= loM { break }
                        }
                        if c != k { pt[k] = Int32(c); count += 1 }
                    }
                    pc[j] = count
                }
            }
        }}}}}
        var src: [Int] = [], dst: [Int] = [], phi: [Double] = []
        iceAvTarget.withUnsafeBufferPointer { tb in
        iceAvPhi.withUnsafeBufferPointer { fb in
            let pt = tb.baseAddress!, pf = fb.baseAddress!
            for j in rowLo...rowHi where rowCount[j] > 0 {
                for i in colLo...colHi {
                    let k = j * nn + i
                    let c = Int(pt[k])
                    guard c >= 0 else { continue }
                    let ci = c % nn, cj = c / nn
                    src.append(k); dst.append(c); phi.append(pf[k])
                    domain.iLo = min(domain.iLo, ci); domain.iHi = max(domain.iHi, ci)
                    domain.jLo = min(domain.jLo, cj); domain.jHi = max(domain.jHi, cj)
                    domain.rowLo[cj] = min(domain.rowLo[cj], ci); domain.rowHi[cj] = max(domain.rowHi[cj], ci)
                }
            }
        }}
        return src.isEmpty ? nil : IceAvalanche(src: src, dst: dst, phi: phi)
    }

    private struct IceDomain {
        var scale: Double, iLo: Int, iHi: Int, jLo: Int, jHi: Int
        var rowLo: [Int], rowHi: [Int]
    }

    private func iceTransportDomain() -> IceDomain {
        let nn = n
        let sea = cfg.sea, t0 = cfg.climateSeaLevelTemp, gamma = cfg.climateLapseRate
        let firnT = cfg.iceFirnTemp
        var rowScale = [Double](repeating: 0, count: nn)
        var rowILo = [Int](repeating: nn, count: nn)
        var rowIHi = [Int](repeating: -1, count: nn)
        h.withUnsafeBufferPointer { hb in
        ice.withUnsafeBufferPointer { ib in
        snow.withUnsafeBufferPointer { sb in
        rowScale.withUnsafeMutableBufferPointer { rsb in
        rowILo.withUnsafeMutableBufferPointer { rlb in
        rowIHi.withUnsafeMutableBufferPointer { rhb in
            let ph = hb.baseAddress!, pice = ib.baseAddress!, psnow = sb.baseAddress!
            let prs = rsb.baseAddress!, prl = rlb.baseAddress!, prh = rhb.baseAddress!
            parallel(nn) { jLo, jHi in
                for j in jLo..<jHi {
                    let row = j * nn
                    var scale = 0.0, iLo = nn, iHi = -1
                    for i in 0..<nn {
                        let k = row + i
                        let ik = pice[k]
                        if ik > 0 || (psnow[k] > 0 && t0 - gamma * max(0, ph[k] - sea) < firnT) {
                            iLo = min(iLo, i); iHi = max(iHi, i)
                        }
                        if ik <= 0 { continue }
                        if 2 * ik > scale { scale = 2 * ik }
                        let sk = ph[k] + ik
                        let sl = i > 0      ? ph[k - 1]  + pice[k - 1]  : sk
                        let sr = i < nn - 1 ? ph[k + 1]  + pice[k + 1]  : sk
                        let sd = j > 0      ? ph[k - nn] + pice[k - nn] : sk
                        let su = j < nn - 1 ? ph[k + nn] + pice[k + nn] : sk
                        var w = 0.0
                        if sk > sl { w += sk - sl }
                        if sk > sr { w += sk - sr }
                        if sk > sd { w += sk - sd }
                        if sk > su { w += sk - su }
                        if w > scale { scale = w }
                    }
                    prs[j] = scale; prl[j] = iLo; prh[j] = iHi
                }
            }
        }}}}}}
        var scale = 0.0
        var iLo = nn, iHi = -1, jLo = nn, jHi = -1
        for j in 0..<nn {
            if rowScale[j] > scale { scale = rowScale[j] }
            guard rowIHi[j] >= 0 else { continue }
            iLo = min(iLo, rowILo[j]); iHi = max(iHi, rowIHi[j])
            jLo = min(jLo, j); jHi = max(jHi, j)
        }
        return IceDomain(scale: scale, iLo: iLo, iHi: iHi, jLo: jLo, jHi: jHi, rowLo: rowILo, rowHi: rowIHi)
    }

    private func applyAvalancheFeed(_ av: IceAvalanche, firn: Double) {
        let sea = cfg.sea, t0 = cfg.climateSeaLevelTemp, gamma = cfg.climateLapseRate
        let firnT = cfg.iceFirnTemp, coldSpan = max(1e-9, cfg.iceFirnColdSpan)
        h.withUnsafeBufferPointer { hb in
        snow.withUnsafeBufferPointer { sb in
        iceAvFeed.withUnsafeMutableBufferPointer { fb in
            let ph = hb.baseAddress!, psnow = sb.baseAddress!, pf = fb.baseAddress!
            let m = av.src.count
            for s in 0..<m { pf[av.src[s]] = 0; pf[av.dst[s]] = 0 }
            for s in 0..<m {
                let k = av.src[s]
                let t = t0 - gamma * max(0, ph[k] - sea)
                let fCold = min(1, max(0, (firnT - t) / coldSpan))
                let a = firn * psnow[k] * fCold
                if a <= 0 { continue }
                let moved = av.phi[s] * a
                pf[k] -= moved
                pf[av.dst[s]] += moved
            }
        }}}
    }

    private func iceFlowSubStep(kappa: Double, dt: Double,
                                p1Lo: [Int], p1Hi: [Int], p2Lo: [Int], p2Hi: [Int],
                                avalanche: IceAvalanche?) {
        let nn = n, cnt = cfg.count
        let sea = cfg.sea, cs = cfg.cellSize
        let moveFrac = max(0, cfg.iceFlowMoveFraction)
        let thr = max(0, cfg.iceMinThickness)
        let coldSpan = max(1e-9, cfg.iceFirnColdSpan)
        let t0 = cfg.climateSeaLevelTemp, gamma = cfg.climateLapseRate
        let firnT = cfg.iceFirnTemp
        let firn = cfg.iceFirnPerSnowYear
        let baseMu = 1 / max(1e-9, cfg.iceTurnoverYears)
        let eBase = exp(-baseMu * dt)
        let meltC = max(0, cfg.iceMeltPerKYear)
        let moraine = max(0, cfg.iceMoraineK)
        let kEro = max(0, cfg.iceErodeK), mEro = cfg.iceErodeFluxExp
        let mEroIsHalf = mEro == 0.5
        let swath = max(0, cfg.iceErodeSwathRadius)
        let swathSide = 2 * swath + 1
        let swathNorm = 1.0 / Double(swathSide * swathSide)
        var freezeJLo = nn, freezeJHi = -1, jLo = nn, jHi = -1
        for j in 0..<nn {
            if p1Hi[j] >= p1Lo[j] { freezeJLo = min(freezeJLo, j); freezeJHi = max(freezeJHi, j) }
            if p2Hi[j] >= p2Lo[j] { jLo = min(jLo, j); jHi = max(jHi, j) }
        }
        guard jHi >= jLo else { return }
        let lithOn = lithErodeK.count == cnt
        let lithArr = lithOn ? lithErodeK : [1.0]
        if let av = avalanche { applyAvalancheFeed(av, firn: firn) }
        let feedOn = avalanche != nil
        let feedArr = feedOn ? iceAvFeed : [0.0]
        h.withUnsafeMutableBufferPointer { hb in
        rock.withUnsafeMutableBufferPointer { rkb in
        sed.withUnsafeMutableBufferPointer { sb in
        ice.withUnsafeMutableBufferPointer { ib in
        snow.withUnsafeBufferPointer { snb in
        lithArr.withUnsafeBufferPointer { ldb in
        feedArr.withUnsafeBufferPointer { fdb in
        iceRate.withUnsafeMutableBufferPointer { rtb in
        iceSurf.withUnsafeMutableBufferPointer { sfb in
        iceEro.withUnsafeMutableBufferPointer { erb in
        iceEroH.withUnsafeMutableBufferPointer { ehb in
            let ph = hb.baseAddress!, prock = rkb.baseAddress!, psed = sb.baseAddress!
            let pice = ib.baseAddress!, psnow = snb.baseAddress!
            let plith = ldb.baseAddress!, pfeed = fdb.baseAddress!
            let prate = rtb.baseAddress!, psurf = sfb.baseAddress!, pero = erb.baseAddress!
            let peroH = ehb.baseAddress!
            parallel(freezeJHi - freezeJLo + 1) { rowLo, rowHi in
            for j in (freezeJLo + rowLo)..<(freezeJLo + rowHi) {
                guard p1Hi[j] >= p1Lo[j] else { continue }
                for i in p1Lo[j]...p1Hi[j] {
                    let k = j * nn + i
                    let sk = ph[k] + pice[k]
                    psurf[k] = sk
                    let ik = pice[k]
                    if ik <= thr { prate[k] = 0; pero[k] = 0; continue }
                    let sl = i > 0      ? ph[k - 1]  + pice[k - 1]  : sk
                    let sr = i < nn - 1 ? ph[k + 1]  + pice[k + 1]  : sk
                    let sd = j > 0      ? ph[k - nn] + pice[k - nn] : sk
                    let su = j < nn - 1 ? ph[k + nn] + pice[k + nn] : sk
                    var w = 0.0
                    if sk > sl { w += sk - sl }
                    if sk > sr { w += sk - sr }
                    if sk > sd { w += sk - sd }
                    if sk > su { w += sk - su }
                    if w <= 0 { prate[k] = 0; pero[k] = 0; continue }
                    var out = kappa * ik * w
                    let cap = moveFrac * ik
                    if out > cap { out = cap }
                    prate[k] = out / w
                    if kEro > 0 && cs > 0 && ph[k] > sea {
                        let slope = w / cs
                        pero[k] = kEro * (mEroIsHalf ? (ik * slope).squareRoot() : pow(ik * slope, mEro)) * slope
                    } else {
                        pero[k] = 0
                    }
                }
                if swath > 0 && kEro > 0 {
                    let base = j * nn
                    for i in max(0, p1Lo[j] - swath)...min(nn - 1, p1Hi[j] + swath) { peroH[base + i] = 0 }
                    for i in p1Lo[j]...p1Hi[j] {
                        let e = pero[base + i]
                        if e != 0 {
                            for ii in max(0, i - swath)...min(nn - 1, i + swath) { peroH[base + ii] += e }
                        }
                    }
                }
            }
            }
            parallel(jHi - jLo + 1) { rowLo, rowHi in
            for j in (jLo + rowLo)..<(jLo + rowHi) {
                guard p2Hi[j] >= p2Lo[j] else { continue }
                for i in p2Lo[j]...p2Hi[j] {
                    let k = j * nn + i
                    if pice[k] == 0 && psnow[k] == 0 && (!feedOn || pfeed[k] == 0)
                        && (i == 0 || prate[k - 1] == 0) && (i == nn - 1 || prate[k + 1] == 0)
                        && (j == 0 || prate[k - nn] == 0) && (j == nn - 1 || prate[k + nn] == 0) {
                        continue
                    }
                    let sk = psurf[k]
                    var inflow = 0.0, w = 0.0
                    if i > 0      { let d = psurf[k - 1]  - sk
                                    if d > 0 { inflow += prate[k - 1]  * d } else { w -= d } }
                    if i < nn - 1 { let d = psurf[k + 1]  - sk
                                    if d > 0 { inflow += prate[k + 1]  * d } else { w -= d } }
                    if j > 0      { let d = psurf[k - nn] - sk
                                    if d > 0 { inflow += prate[k - nn] * d } else { w -= d } }
                    if j < nn - 1 { let d = psurf[k + nn] - sk
                                    if d > 0 { inflow += prate[k + nn] * d } else { w -= d } }
                    let i0 = pice[k]
                    let t = t0 - gamma * max(0, ph[k] - sea)
                    let fCold = min(1, max(0, (firnT - t) / coldSpan))
                    var a = firn * psnow[k] * fCold
                    if feedOn { a += pfeed[k]; if a < 0 { a = 0 } }
                    if i0 == 0 && inflow == 0 && a == 0 { continue }
                    var iceNow = i0 + inflow - prate[k] * w
                    if iceNow < 0 { iceNow = 0 }
                    if kEro > 0 && i0 > thr && w > 0 && ph[k] > sea {
                        var rate = pero[k]
                        if swath > 0 {
                            var sum = 0.0
                            for dj in -swath...swath {
                                let jj = j + dj
                                if jj < 0 || jj >= nn { continue }
                                sum += peroH[jj * nn + i]
                            }
                            rate = sum * swathNorm
                        }
                        var d = rate * dt
                        let capD = 0.25 * w
                        if d > capD { d = capD }
                        let f = lithOn ? plith[k] : 1.0
                        if f != 1.0 {
                            let s = psed[k]
                            if d > s { d = s + (d - s) * f }
                        }
                        if d > 0 {
                            let take = min(d, psed[k])
                            psed[k] -= take
                            prock[k] -= (d - take)
                            ph[k] -= d
                        }
                    }
                    let meltRate = meltC * max(0, t)
                    let mu = baseMu + meltRate
                    let target = a / mu
                    let e = meltRate == 0 ? eBase : exp(-mu * dt)
                    pice[k] = target + (iceNow - target) * e
                    if moraine > 0 && meltRate > 0 && ph[k] > sea {
                        var ablated = mu * target * dt + (iceNow - target) * (1 - e)
                        if ablated < 0 { ablated = 0 }
                        let dep = moraine * ablated * (meltRate / mu)
                        if dep > 0 { psed[k] += dep; ph[k] += dep }
                    }
                    if ph[k] <= sea { pice[k] = 0 }
                }
            }
            }
        }}}}}}}}}}}
    }

    private func rebuildIceMask() {
        let cnt = cfg.count, thr = cfg.iceMinThickness
        guard anyCell(ice, { $0 > thr }) else {
            if !underIce.isEmpty { underIce = [] }
            return
        }
        if underIce.count != cnt { underIce = .init(repeating: false, count: cnt) }
        underIce.withUnsafeMutableBufferPointer { ub in
        ice.withUnsafeBufferPointer { ib in
            let pu = ub.baseAddress!, pi = ib.baseAddress!
            for k in 0..<cnt { pu[k] = pi[k] > thr }
        }}
    }

    @inline(__always) public static func iceCoverage(thickness: Double, ref: Double) -> Double {
        thickness / (thickness + ref)
    }

    @inline(__always) public func iceCover(_ k: Int) -> Double {
        guard ice.count == cfg.count else { return 0 }
        return Terrain.iceCoverage(thickness: ice[k], ref: cfg.iceCoverRef)
    }

    public func updateHeightBands() {
        heightBands = cfg.heightBandsOverride
            ?? HeightBands.fromLandHeights(h, cfg: cfg, snowFractions: snowAreaFractions())
    }

    @inline(__always)
    public static func macroSlope(_ p: UnsafePointer<Double>, _ k: Int, _ n: Int) -> Double {
        (abs(p[k + 2] - p[k - 2]) + abs(p[k + 2 * n] - p[k - 2 * n])) * 0.125
    }

    @inline(__always)
    public static func macroSlope(_ a: [Double], _ k: Int, _ n: Int) -> Double {
        a.withUnsafeBufferPointer { macroSlope($0.baseAddress!, k, n) }
    }

    @inline(__always)
    public static func vegetationSuitability(height: Double, slope: Double, rain: Double,
                                             bands: HeightBands) -> Double {
        let slopeOk = max(0, 1 - slope * 40)
        let wet = min(1, rain * 1.3)
        return slopeOk * wet * bands.vegetationAltitudeFactor(height)
    }

    public func updateVegetation(years: Double) {
        updateHeightBands()
        let bands = heightBands
        let f = Terrain.relaxFraction(dt: years, tau: cfg.vegTimeConstant)
        let fKill = Terrain.relaxFraction(dt: years, tau: cfg.vegFloodKillYears)
        let killDepth = cfg.vegFloodKillDepth
        let dispersal = cfg.vegDispersalStrength
        let dr = max(0, Int(cfg.vegDispersalRadius.rounded()))
        let nn = n, sea = cfg.sea
        if dispersal > 0 && dr > 0 {
            if vegScratchRow.count != cfg.count {
                vegScratchRow = .init(repeating: 0, count: cfg.count)
            }
            veg.withUnsafeBufferPointer { vb in
            vegScratchRow.withUnsafeMutableBufferPointer { rb in
                let pveg = vb.baseAddress!, prow = rb.baseAddress!
                let iLo = min(dr, nn)
                let iHi = max(iLo, nn - dr)
                parallel(nn) { jLo, jHi in
                    for j in jLo..<jHi {
                        let row = j * nn
                        let psrc = pveg + row, pdst = prow + row
                        for i in 0..<iLo {
                            var m = 0.0
                            for di in max(0, i - dr)...min(nn - 1, i + dr) {
                                m = max(m, psrc[di])
                            }
                            pdst[i] = m
                        }
                        if dr == 2 {
                            for i in iLo..<iHi {
                                pdst[i] = max(psrc[i - 2], max(psrc[i - 1], max(psrc[i], max(psrc[i + 1], psrc[i + 2]))))
                            }
                        } else {
                            for i in iLo..<iHi {
                                var m = psrc[i - dr]
                                for di in (i - dr + 1)...(i + dr) {
                                    m = max(m, psrc[di])
                                }
                                pdst[i] = m
                            }
                        }
                        for i in iHi..<nn {
                            var m = 0.0
                            for di in max(0, i - dr)...min(nn - 1, i + dr) {
                                m = max(m, psrc[di])
                            }
                            pdst[i] = m
                        }
                    }
                }
            }}
            vegScratchRow.withUnsafeBufferPointer { rb in
            vegScratch.withUnsafeMutableBufferPointer { sb in
                let prow = rb.baseAddress!, psc = sb.baseAddress!
                parallel(nn) { jLo, jHi in
                    for j in jLo..<jHi {
                        let jStart = max(0, j - dr)
                        let jEnd = min(nn - 1, j + dr)
                        let dst = psc + j * nn
                        let src0 = prow + jStart * nn
                        for i in 0..<nn { dst[i] = src0[i] }
                        for rj in (jStart + 1)...jEnd {
                            let src = prow + rj * nn
                            for i in 0..<nn {
                                dst[i] = max(dst[i], src[i])
                            }
                        }
                    }
                }
            }}
        }
        let disturbSuppress = cfg.disturbanceEnabled ? cfg.disturbanceVegSuppress : 0
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeBufferPointer { hfb in
        rain.withUnsafeBufferPointer { rnb in
        vegScratch.withUnsafeBufferPointer { scb in
        saltCrust.withUnsafeBufferPointer { slb in
        disturb.withUnsafeBufferPointer { dsb in
        veg.withUnsafeMutableBufferPointer { vb in
            let ph = hb.baseAddress!, phf = hfb.baseAddress!
            let prain = rnb.baseAddress!, pseed = scb.baseAddress!
            let psalt = slb.baseAddress!, pdist = dsb.baseAddress!
            let pveg = vb.baseAddress!
            parallel(nn - 4) { lo, hi in
            for j in (lo + 2)..<(hi + 2) {
                for i in 2..<(nn - 2) {
                    let k = j * nn + i
                    if phf[k] - ph[k] > killDepth {
                        pveg[k] -= pveg[k] * fKill
                        continue
                    }
                    var target = 0.0
                    let v = ph[k]
                    if v > sea + 0.005 && v < bands.vegNone && phf[k] - ph[k] <= 0.015 {
                        let slope = Terrain.macroSlope(ph, k, nn)
                        target = Terrain.vegetationSuitability(height: v, slope: slope,
                                                               rain: prain[k], bands: bands)
                        if dispersal > 0 && target > 0.05 {
                            target = max(target, pseed[k] * dispersal)
                        }
                        target *= 1 - psalt[k]
                        if disturbSuppress > 0 && pdist[k] > 0 {
                            target *= max(0, 1 - disturbSuppress * pdist[k])
                        }
                    }
                    pveg[k] += (target - pveg[k]) * f
                }
            }
            }
        }}}}}}}
        updateVegClass()
    }

    @inline(__always) func vegDamp(_ k: Int) -> Double {
        max(0, 1 - 0.6 * vegTypeFactor[Int(vegClass[k])] * veg[k])
    }

    private func updateVegClass() {
        let nn = n, sea = cfg.sea, cnt = cfg.count
        let cellArea = cfg.cellSize * cfg.cellSize
        let minA = cfg.braidMinCells * cellArea
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeBufferPointer { hfb in
        area.withUnsafeBufferPointer { ab in
        riparian.withUnsafeMutableBufferPointer { rb in
            let ph = hb.baseAddress!, phf = hfb.baseAddress!
            let pa = ab.baseAddress!, prip = rb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi {
                    let water = phf[k] > sea
                        && (pa[k] >= minA || phf[k] - ph[k] > 0.02)
                    prip[k] = water ? 1.0 : 0.0
                }
            }
        }}}}
        for _ in 0..<3 {
            dilateDamped(from: riparian, to: &vegScratch)
            swap(&riparian, &vegScratch)
        }
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeBufferPointer { hfb in
        veg.withUnsafeBufferPointer { vb in
        riparian.withUnsafeBufferPointer { rb in
        vegClass.withUnsafeMutableBufferPointer { cb in
            let ph = hb.baseAddress!, phf = hfb.baseAddress!
            let pveg = vb.baseAddress!, prip = rb.baseAddress!
            let pcls = cb.baseAddress!
            parallel(nn - 4) { lo, hi in
            for j in (lo + 2)..<(hi + 2) {
                for i in 2..<(nn - 2) {
                    let k = j * nn + i
                    var cls: UInt8 = 0
                    let v = pveg[k]
                    if ph[k] > sea + 0.005 && v >= 0.12 {
                        if prip[k] >= 1 {
                            cls = 1
                        } else if prip[k] >= 0.4 && v >= 0.25 && phf[k] - ph[k] <= 0.02 && Terrain.macroSlope(ph, k, nn) * 40 < 0.6 {
                            cls = 3
                        } else if v > 0.45 {
                            cls = 2
                        } else {
                            cls = 1
                        }
                    }
                    pcls[k] = cls
                }
            }
            }
        }}}}}
    }

    private func dilateDamped(from src: [Double], to dst: inout [Double]) {
        let nn = n
        src.withUnsafeBufferPointer { sb in
        dst.withUnsafeMutableBufferPointer { db in
            let ps = sb.baseAddress!, pd = db.baseAddress!
            parallel(nn) { jLo, jHi in
                for j in jLo..<jHi {
                    let row = j * nn
                    if j > 0 && j < nn - 1 {
                        let kLeft = row
                        let mLeft = max(ps[kLeft - nn], max(ps[kLeft - nn + 1],
                                    max(ps[kLeft + 1],
                                    max(ps[kLeft + nn], ps[kLeft + nn + 1]))))
                        pd[kLeft] = max(ps[kLeft], 0.65 * mLeft)

                        for i in 1..<(nn - 1) {
                            let k = row + i
                            let m = max(ps[k - nn - 1], max(ps[k - nn], max(ps[k - nn + 1],
                                    max(ps[k - 1],                      max(ps[k + 1],
                                    max(ps[k + nn - 1], max(ps[k + nn], ps[k + nn + 1])))))))
                            pd[k] = max(ps[k], 0.65 * m)
                        }

                        let kRight = row + nn - 1
                        let mRight = max(ps[kRight - nn - 1], max(ps[kRight - nn],
                                     max(ps[kRight - 1],
                                     max(ps[kRight + nn - 1], ps[kRight + nn]))))
                        pd[kRight] = max(ps[kRight], 0.65 * mRight)
                    } else {
                        for i in 0..<nn {
                            let k = row + i
                            var m = 0.0
                            if i > 0 && j > 0 { m = max(m, ps[k - nn - 1]) }
                            if j > 0 { m = max(m, ps[k - nn]) }
                            if i < nn - 1 && j > 0 { m = max(m, ps[k - nn + 1]) }
                            if i > 0 { m = max(m, ps[k - 1]) }
                            if i < nn - 1 { m = max(m, ps[k + 1]) }
                            if i > 0 && j < nn - 1 { m = max(m, ps[k + nn - 1]) }
                            if j < nn - 1 { m = max(m, ps[k + nn]) }
                            if i < nn - 1 && j < nn - 1 { m = max(m, ps[k + nn + 1]) }
                            pd[k] = max(ps[k], 0.65 * m)
                        }
                    }
                }
            }
        }}
    }

    public func computeFlow(includeMFD: Bool = true, dtYears: Double = 0) {
        mark("computeRain")
        computeRain()
        floodAndRoute(dt: dtYears)
        if includeMFD { mark("computeMFDArea"); computeMFDArea() }
    }

    private func floodAndRoute(dt: Double, applyBalance: Bool = true) {
        mark("priorityFlood")
        priorityFlood()
        mark("clearEndorheicBasins")
        clearEndorheicBasins()
        mark("computeReceiversAndArea")
        computeReceiversAndArea()
        guard applyBalance else { return }
        mark("capEndorheicBasins")
        if capEndorheicBasins(dt: dt) {
            mark("computeReceiversAndArea")
            computeReceiversAndArea()
        }
    }

    private func clearEndorheicBasins() {
        let cnt = cfg.count
        let any = endorheicBasin.withUnsafeBufferPointer { eb -> Bool in
            let p = eb.baseAddress!
            for k in 0..<cnt where p[k] != .none { return true }
            return false
        }
        guard any else { return }
        endorheicBasin.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: .none, count: cnt) }
        playaBed.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        endorheicInflow.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
    }

    private func priorityFlood() {
        heap.removeAll()
        let cnt = cfg.count, nn = n
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeMutableBufferPointer { hfb in
        visited.withUnsafeMutableBufferPointer { vb in
        floodParent.withUnsafeMutableBufferPointer { pb in
        order.withUnsafeMutableBufferPointer { ob in
        heap.withRaw { heap in
            let ph = hb.baseAddress!, phf = hfb.baseAddress!
            let pv = vb.baseAddress!, ppar = pb.baseAddress!, pord = ob.baseAddress!
            pv.update(repeating: false, count: cnt)
            @inline(__always) func seed(_ b: Int, _ col: Int32) {
                if pv[b] { return }
                pv[b] = true
                phf[b] = ph[b]
                ppar[b] = -1
                heap.push(key: ph[b], cell: Int32(b), col: col)
            }
            for i in 0..<nn {
                seed(i, Int32(i))
                seed((nn - 1) * nn + i, Int32(i))
                seed(i * nn, 0)
                seed(i * nn + nn - 1, Int32(nn - 1))
            }
            let lastRow = cnt - nn
            var oi = 0
            while heap.size > 0 {
                let e = heap.pop()
                let c = Int(e.cell), col = Int(e.col)
                pord[oi] = e.cell; oi += 1
                let hc = e.key
                @inline(__always) func visit(_ nb: Int, _ ncol: Int32) {
                    if pv[nb] { return }
                    pv[nb] = true
                    let v = max(ph[nb], hc)
                    phf[nb] = v
                    ppar[nb] = e.cell
                    heap.push(key: v, cell: Int32(nb), col: ncol)
                }
                if col > 0 && col < nn - 1 && c >= nn && c < lastRow {
                    let cm = e.col
                    visit(c - nn - 1, cm - 1); visit(c - nn, cm); visit(c - nn + 1, cm + 1)
                    visit(c - 1, cm - 1);          visit(c + 1, cm + 1)
                    visit(c + nn - 1, cm - 1); visit(c + nn, cm); visit(c + nn + 1, cm + 1)
                } else {
                    let cj = c / nn
                    for dj in -1...1 {
                        for di in -1...1 {
                            if di == 0 && dj == 0 { continue }
                            let ni = col + di, nj = cj + dj
                            if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                            visit(nj * nn + ni, Int32(ni))
                        }
                    }
                }
            }
        }}}}}}
    }

    private func seedFlowAccumulator(_ pa: UnsafeMutablePointer<Double>, cellArea: Double) {
        let cnt = cfg.count
        let weight = flowWeight
        guard weight.count == cnt else {
            pa.update(repeating: cellArea, count: cnt)
            return
        }
        weight.withUnsafeBufferPointer { rb in
            let pw = rb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi { pa[k] = cellArea * pw[k] }
            }
        }
    }

    private func computeReceiversAndArea() {
        let cellArea = cfg.cellSize * cfg.cellSize
        let cnt = cfg.count, nn = n, sea = cfg.sea
        let sqrt2 = 2.0.squareRoot()
        let weight = flowWeight
        let hasWeight = weight.count == cnt
        hf.withUnsafeBufferPointer { hfb in
        receiver.withUnsafeMutableBufferPointer { rb in
        area.withUnsafeMutableBufferPointer { ab in
        floodParent.withUnsafeBufferPointer { pb in
        order.withUnsafeBufferPointer { ob in
        endorheicBasin.withUnsafeBufferPointer { eb in
        (hasWeight ? weight : []).withUnsafeBufferPointer { wb in
            let phf = hfb.baseAddress!, prec = rb.baseAddress!, pa = ab.baseAddress!
            let ppar = pb.baseAddress!, pord = ob.baseAddress!, pend = eb.baseAddress!
            let pw = hasWeight ? wb.baseAddress! : nil
            parallel(nn) { jLo, jHi in
            for j in jLo..<jHi {
                let row = j * nn
                let innerRow = j > 0 && j < nn - 1
                for i in 0..<nn {
                    let k = row + i
                    pa[k] = pw != nil ? cellArea * pw![k] : cellArea
                    let hk = phf[k]
                    if hk <= sea {
                        prec[k] = -1
                        continue
                    }
                    var best: Int32 = -1
                    var bestSlope = 0.0
                    @inline(__always) func considerOrth(_ nb: Int) {
                        let d = hk - phf[nb]
                        if d > bestSlope { bestSlope = d; best = Int32(nb) }
                    }
                    @inline(__always) func considerDiag(_ nb: Int) {
                        let d = hk - phf[nb]
                        if d <= 0 { return }
                        let s = d / sqrt2
                        if s > bestSlope { bestSlope = s; best = Int32(nb) }
                    }
                    if innerRow && i > 0 && i < nn - 1 {
                        considerDiag(k - nn - 1); considerOrth(k - nn); considerDiag(k - nn + 1)
                        considerOrth(k - 1);               considerOrth(k + 1)
                        considerDiag(k + nn - 1); considerOrth(k + nn); considerDiag(k + nn + 1)
                    } else {
                        for dj in -1...1 {
                            for di in -1...1 {
                                if di == 0 && dj == 0 { continue }
                                let ni = i + di, nj = j + dj
                                if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                                let nb = nj * nn + ni
                                if di != 0 && dj != 0 {
                                    considerDiag(nb)
                                } else {
                                    considerOrth(nb)
                                }
                            }
                        }
                    }
                    if pend[k] != .none {
                        if pend[k] == .water || best < 0 { best = -1 }
                    } else if best < 0 {
                        best = ppar[k]
                    }
                    prec[k] = best
                }
            }
            }
            var oi = cnt - 1
            while oi >= 0 {
                let k = Int(pord[oi]); oi -= 1
                let r = prec[k]
                if r >= 0 { pa[Int(r)] += pa[k] }
            }
        }}}}}}}
    }

    private func capEndorheicBasins(dt: Double) -> Bool {
        guard cfg.endorheicEvaporation, cfg.endorheicEvapRatio > 0 else {
            if endorheicBasin.contains(where: { $0 != .none }) {
                for k in 0..<cfg.count { endorheicBasin[k] = .none }
            }
            return false
        }
        let cnt = cfg.count, nn = n, sea = cfg.sea
        let cellArea = cfg.cellSize * cfg.cellSize
        let kappa = cfg.endorheicEvapRatio
        let aridA = cfg.endorheicAridity
        let weighted = rainWeight.count == cnt
        let minBasin = cfg.endorheicMinBasinCells
        let saltMinDepth = cfg.endorheicSaltMinDepth
        let lam = (dt > 0 && cfg.endorheicResponseYears > 0)
            ? Terrain.relaxFraction(dt: dt, tau: cfg.endorheicResponseYears) : 1.0
        var cells = basinCells; basinCells = []
        var slots = basinSlots; basinSlots = []
        defer { basinCells = cells; basinSlots = slots }
        let rw = weighted ? rainWeight : [1.0]
        var capped = false
        var orderPosBuilt = false
        hf.withUnsafeMutableBufferPointer { hfb in
        h.withUnsafeBufferPointer { hb in
        area.withUnsafeBufferPointer { ab in
        rw.withUnsafeBufferPointer { rwb in
        basinSeen.withUnsafeMutableBufferPointer { bsb in
        endorheicBasin.withUnsafeMutableBufferPointer { ebb in
        playaBed.withUnsafeMutableBufferPointer { pbb in
        endorheicInflow.withUnsafeMutableBufferPointer { eib in
        lakeBalance.withUnsafeMutableBufferPointer { lbb in
            let phf = hfb.baseAddress!, ph = hb.baseAddress!, pa = ab.baseAddress!
            let prw = rwb.baseAddress!, pseen = bsb.baseAddress!
            let pend = ebb.baseAddress!, pplaya = pbb.baseAddress!
            let pinflow = eib.baseAddress!, plake = lbb.baseAddress!
            @inline(__always) func demand(_ k: Int) -> Double {
                guard weighted, aridA != 0 else { return cellArea * kappa }
                let a = min(4.0, max(0.25, 1 + aridA * (1 - prw[k])))
                return cellArea * kappa * a
            }
            pseen.update(repeating: false, count: cnt)
            pend.update(repeating: .none, count: cnt)
            pplaya.update(repeating: false, count: cnt)
            pinflow.update(repeating: 0, count: cnt)
            for s in 0..<cnt where !pseen[s] && phf[s] > sea && phf[s] > ph[s] {
                let sill = phf[s]
                cells.removeAll(keepingCapacity: true)
                cells.append(Int32(s))
                pseen[s] = true
                var inflow = 0.0, full = 0.0
                var qi = 0
                while qi < cells.count {
                    let k = Int(cells[qi]); qi += 1
                    inflow = max(inflow, pa[k])
                    full += demand(k)
                    let j = k / nn, i = k - j * nn
                    for dj in -1...1 {
                        for di in -1...1 {
                            if di == 0 && dj == 0 { continue }
                            let ni = i + di, nj = j + dj
                            if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                            let nb = nj * nn + ni
                            if pseen[nb] || phf[nb] != sill || phf[nb] <= ph[nb] { continue }
                            pseen[nb] = true
                            cells.append(Int32(nb))
                        }
                    }
                }
                if full <= inflow || cells.count < minBasin {
                    for kk in cells { plake[Int(kk)] = sill }
                    continue
                }
                cells.sort { (ph[Int($0)], $0) < (ph[Int($1)], $1) }
                var spent = 0.0, wet = 0
                for kk in cells {
                    let d = demand(Int(kk))
                    if spent + d > inflow { break }
                    spent += d; wet += 1
                }
                let target = wet >= cells.count ? sill : ph[Int(cells[wet])]
                let anchor = Int(cells[0])
                var prev = plake[anchor]
                if !prev.isFinite { prev = sill }
                prev = min(max(prev, ph[anchor]), sill)
                let level = prev + (target - prev) * lam
                for kk in cells {
                    let k = Int(kk)
                    plake[k] = level
                    pinflow[k] = inflow
                    if level > ph[k] {
                        phf[k] = level
                        pend[k] = .water
                    } else {
                        phf[k] = ph[k]
                        pend[k] = .dryBed
                        pplaya[k] = sill - ph[k] > saltMinDepth
                    }
                }
                capped = true
                order.withUnsafeMutableBufferPointer { ob in
                orderPos.withUnsafeMutableBufferPointer { opb in
                    let pord = ob.baseAddress!, ppos = opb.baseAddress!
                    if !orderPosBuilt {
                        parallel(cnt) { lo, hi in
                            for t in lo..<hi { ppos[Int(pord[t])] = Int32(t) }
                        }
                        orderPosBuilt = true
                    }
                    slots.removeAll(keepingCapacity: true)
                    for kk in cells { slots.append(ppos[Int(kk)]) }
                    slots.sort()
                    for t in slots.indices {
                        let slot = Int(slots[t]), c = cells[t]
                        pord[slot] = c
                        ppos[Int(c)] = Int32(slot)
                    }
                }}
            }
        }}}}}}}}}
        return capped
    }

    private func updateSaltCrust(dt: Double) {
        guard cfg.endorheicSaltYears > 0 else { return }
        let lam = Terrain.relaxFraction(dt: dt, tau: cfg.endorheicSaltYears)
        saltCrust.withUnsafeMutableBufferPointer { sb in
        playaBed.withUnsafeBufferPointer { pb in
            let ps = sb.baseAddress!, pp = pb.baseAddress!
            parallel(cfg.count) { lo, hi in
                for k in lo..<hi {
                    let target: Double = pp[k] ? 1 : 0
                    ps[k] += (target - ps[k]) * lam
                }
            }
        }}
    }

    @inline(__always) func mfdLocalExponent(_ k: Int, sMax: Double) -> Double {
        mfdLocalExponent(a: areaMFD[k], sMax: sMax, pond: hf[k] - h[k])
    }
    @inline(__always) func mfdLocalExponent(a: Double, sMax: Double, pond: Double) -> Double {
        (a >= mfdMinA && mfdCanDisperse(sMax: sMax, pond: pond))
            ? cfg.braidDispersion : cfg.mfdExponent
    }
    @inline(__always) private func mfdCanDisperse(sMax: Double, pond: Double) -> Bool {
        sMax < mfdFlatCell && pond < 0.005
    }
    private let mfdMinA: Double
    private let mfdFlatCell: Double

    private struct MFDRoute {
        var neighbors = SIMD8<Int32>(repeating: 0)
        var weights = SIMD8<Double>(repeating: 0)
    }

    private struct MFDDispersion {
        var weights = SIMD8<Double>(repeating: 0)
    }

    private func computeMFDArea() {
        let cellArea = cfg.cellSize * cfg.cellSize
        let cnt = cfg.count, nn = n, sea = cfg.sea
        let sqrt2 = 2.0.squareRoot()
        let exponent = cfg.mfdExponent, dispersion = cfg.braidDispersion
        if mfdRoutes.count != cnt { mfdRoutes = .init(repeating: MFDRoute(), count: cnt) }
        if mfdRouteCounts.count != cnt { mfdRouteCounts = .init(repeating: 0, count: cnt) }
        if mfdDispersed.count != cnt { mfdDispersed = .init(repeating: MFDDispersion(), count: cnt) }
        hf.withUnsafeBufferPointer { hfb in
        h.withUnsafeBufferPointer { hb in
        areaMFD.withUnsafeMutableBufferPointer { ab in
        floodParent.withUnsafeBufferPointer { pb in
        order.withUnsafeBufferPointer { ob in
        endorheicBasin.withUnsafeBufferPointer { eb in
        let capacity = cnt
        mfdRoutes.withUnsafeMutableBufferPointer { routes in
        mfdRouteCounts.withUnsafeMutableBufferPointer { rcb in
        mfdDispersed.withUnsafeMutableBufferPointer { dsp in
            let phf = hfb.baseAddress!, ph = hb.baseAddress!, pa = ab.baseAddress!
            let ppar = pb.baseAddress!, pord = ob.baseAddress!, pend = eb.baseAddress!
            let pr = routes.baseAddress!, prc = rcb.baseAddress!, pdsp = dsp.baseAddress!
            seedFlowAccumulator(pa, cellArea: cellArea)
            let fastMod = UInt64.max / UInt64(nn) &+ 1
            let lastRow = cnt - nn
            var end = cnt
            while end > 0 {
                let length = min(capacity, end)
                let blockEnd = end
                parallel(length) { lo, hi in
                withUnsafeTemporaryAllocation(of: Int32.self, capacity: 8) { nbBuf in
                withUnsafeTemporaryAllocation(of: Double.self, capacity: 8) { slopeBuf in
                withUnsafeTemporaryAllocation(of: Double.self, capacity: 8) { weightBuf in
                let pNeighbors = nbBuf.baseAddress!
                let pSlopes = slopeBuf.baseAddress!
                let pWeights = weightBuf.baseAddress!
                for j in 0..<8 { pNeighbors[j] = 0; pSlopes[j] = 0; pWeights[j] = 0 }
                for t in lo..<hi {
                    let k = Int(pord[blockEnd - 1 - t])
                    let hk = phf[k]
                    if hk <= sea || pend[k] == .water {
                        prc[t] = -1
                        continue
                    }
                    var c = 0
                    var sMax = 0.0
                    @inline(__always) func considerOrth(_ nb: Int) {
                        let d = hk - phf[nb]
                        if d > 0 { pNeighbors[c] = Int32(nb); pSlopes[c] = d; sMax = max(sMax, d); c += 1 }
                    }
                    @inline(__always) func considerDiag(_ nb: Int) {
                        let d = hk - phf[nb]
                        if d <= 0 { return }
                        let s = d / sqrt2
                        if s > 0 { pNeighbors[c] = Int32(nb); pSlopes[c] = s; sMax = max(sMax, s); c += 1 }
                    }
                    let i = Int((fastMod &* UInt64(k)).multipliedFullWidth(by: UInt64(nn)).high)
                    if i > 0 && i < nn - 1 && k >= nn && k < lastRow {
                        considerDiag(k - nn - 1); considerOrth(k - nn); considerDiag(k - nn + 1)
                        considerOrth(k - 1);                            considerOrth(k + 1)
                        considerDiag(k + nn - 1); considerOrth(k + nn); considerDiag(k + nn + 1)
                    } else {
                        let j = k / nn
                        for dj in -1...1 {
                            for di in -1...1 {
                                if di == 0 && dj == 0 { continue }
                                let ni = i + di, nj = j + dj
                                if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                                if di != 0 && dj != 0 {
                                    considerDiag(nj * nn + ni)
                                } else {
                                    considerOrth(nj * nn + ni)
                                }
                            }
                        }
                    }
                    if c == 0 {
                        prc[t] = 0
                        continue
                    }
                    var sum = 0.0
                    for j in 0..<c {
                        let w = powFast(pSlopes[j], exponent)
                        pWeights[j] = w
                        sum += w
                    }
                    if sum <= 0 {
                        prc[t] = 0
                        continue
                    }
                    for j in 0..<c {
                        pWeights[j] /= sum
                    }
                    pr[t] = MFDRoute(
                        neighbors: UnsafeRawPointer(pNeighbors).loadUnaligned(fromByteOffset: 0, as: SIMD8<Int32>.self),
                        weights: UnsafeRawPointer(pWeights).loadUnaligned(fromByteOffset: 0, as: SIMD8<Double>.self))
                    if mfdCanDisperse(sMax: sMax, pond: hk - ph[k]) {
                        var dSum = 0.0
                        for j in 0..<c {
                            let w = powFast(pSlopes[j], dispersion)
                            pWeights[j] = w
                            dSum += w
                        }
                        if dSum > 0 {
                            for j in 0..<c {
                                pWeights[j] /= dSum
                            }
                            pdsp[t] = MFDDispersion(
                                weights: UnsafeRawPointer(pWeights).loadUnaligned(fromByteOffset: 0, as: SIMD8<Double>.self))
                            prc[t] = Int8(c + 10)
                        } else {
                            prc[t] = Int8(c)
                        }
                    } else {
                        prc[t] = Int8(c)
                    }
                }
                }}}
                }
                for t in 0..<length {
                    let c8 = prc[t]
                    if c8 < 0 { continue }
                    let k = Int(pord[blockEnd - 1 - t])
                    let a = pa[k]
                    let canD = c8 >= 10
                    let c = canD ? Int(c8) - 10 : Int(c8)
                    if c == 0 {
                        if pend[k] != .none { continue }
                        let fp = ppar[k]
                        if fp >= 0 { pa[Int(fp)] += a }
                        continue
                    }
                    let disperse = a >= mfdMinA && canD
                    withUnsafePointer(to: &pr[t]) { routePtr in
                        let pNb = UnsafeRawPointer(routePtr).assumingMemoryBound(to: Int32.self)
                        let pW: UnsafePointer<Double>
                        if disperse {
                            pW = UnsafeRawPointer(pdsp + t).assumingMemoryBound(to: Double.self)
                        } else {
                            pW = UnsafeRawPointer(routePtr).advanced(by: MemoryLayout<SIMD8<Int32>>.size).assumingMemoryBound(to: Double.self)
                        }
                        for j in 0..<c {
                            pa[Int(pNb[j])] += a * pW[j]
                        }
                    }
                }
                end -= length
            }
        }}}}}}}}}
    }

    private func braidPass(dt: Double) {
        let cellArea = cfg.cellSize * cfg.cellSize
        guard cellArea > 0, cellArea.isFinite else { return }
        let minA = cfg.braidMinCells * cellArea
        let mB = cfg.braidExponent
        let kb = cfg.braidCapacity * dt
        let sqrt2 = 2.0.squareRoot()
        let sea = cfg.sea, nn = n, cnt = cfg.count
        let barHeight = cfg.braidBarHeight, deltaCeiling = cfg.braidDeltaCeiling
        fill(&qs, 0)
        if braidStatus.count != cnt { braidStatus = .init(repeating: 0, count: cnt) }
        hf.withUnsafeBufferPointer { hfb in
        areaMFD.withUnsafeBufferPointer { amb in
        h.withUnsafeBufferPointer { hb in
        braidStatus.withUnsafeMutableBufferPointer { stb in
            let phf = hfb.baseAddress!, pamf = amb.baseAddress!, ph0 = hb.baseAddress!
            let pst = stb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi {
                    if phf[k] <= sea {
                        pst[k] = 0
                        continue
                    }
                    let active = pamf[k] >= minA && ph0[k] > sea
                              && phf[k] - ph0[k] < 0.015
                    pst[k] = active ? 2 : 1
                }
            }
        }}}}
        order.withUnsafeBufferPointer { ob in
        qs.withUnsafeMutableBufferPointer { qb in
        areaMFD.withUnsafeBufferPointer { amb in
        hf.withUnsafeBufferPointer { hfb in
        floodParent.withUnsafeBufferPointer { fpb in
        braidStatus.withUnsafeBufferPointer { stb in
        withUnsafeTemporaryAllocation(of: Int.self, capacity: 8) { nbK in
        withUnsafeTemporaryAllocation(of: Double.self, capacity: 8) { nbW in
        withUnsafeTemporaryAllocation(of: Double.self, capacity: 8) { nbS in
        withUnsafeTemporaryAllocation(of: Double.self, capacity: 8) { nbQc in
        let pord = ob.baseAddress!, pqs = qb.baseAddress!, pamf = amb.baseAddress!
        let phf = hfb.baseAddress!, pfp = fpb.baseAddress!
        let pst = stb.baseAddress!
        withBed { bed in
        var oi = cfg.count - 1
        while oi >= 0 {
            let k = Int(pord[oi]); oi -= 1
            let st = pst[k]
            if st == 0 { continue }
            let qin = pqs[k]
            if st == 1 {
                if qin > 0 {
                    let ceil = max(0, phf[k] + deltaCeiling - bed.h[k])
                    depositCell(k, min(qin, ceil), bed)
                }
                continue
            }
            let j = k / nn, i = k - j * nn
            var cnt = 0
            var sMax = 0.0
            @inline(__always) func consider(_ nb: Int, _ dist: Double) {
                let d = phf[k] - phf[nb]
                if d <= 0 { return }
                let s = d / dist
                if s > 0 {
                    nbK[cnt] = nb; nbS[cnt] = s; sMax = max(sMax, s)
                    cnt += 1
                }
            }
            if i > 0 && i < nn - 1 && j > 0 && j < nn - 1 {
                consider(k - nn - 1, sqrt2); consider(k - nn, 1.0); consider(k - nn + 1, sqrt2)
                consider(k - 1, 1.0);                               consider(k + 1, 1.0)
                consider(k + nn - 1, sqrt2); consider(k + nn, 1.0); consider(k + nn + 1, sqrt2)
            } else {
                for dj in -1...1 {
                    for di in -1...1 {
                        if di == 0 && dj == 0 { continue }
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                        let nb = nj * nn + ni
                        consider(nb, (di != 0 && dj != 0) ? sqrt2 : 1.0)
                    }
                }
            }
            let p = mfdLocalExponent(a: pamf[k], sMax: sMax, pond: phf[k] - bed.h[k])
            var wsum = 0.0
            for t in 0..<cnt { nbW[t] = powFast(nbS[t], p); wsum += nbW[t] }
            if cnt == 0 || wsum <= 0 {
                let dep = min(qin, max(0, phf[k] - bed.h[k]))
                depositCell(k, dep, bed)
                let fp = pfp[k]
                if fp >= 0 { pqs[Int(fp)] += qin - dep }
                continue
            }
            let q = pamf[k] / cellArea
            var qcTot = 0.0
            for t in 0..<cnt {
                nbQc[t] = kb * q * nbS[t] * pow(nbW[t] / wsum, mB)
                qcTot += nbQc[t]
            }
            var qout = qin
            if qin > qcTot {
                let dep = min(qin - qcTot, max(0, phf[k] + barHeight - bed.h[k]))
                depositCell(k, dep, bed)
                qout -= dep
            } else {
                var lowest = bed.h[k]
                for t in 0..<cnt { lowest = min(lowest, bed.h[nbK[t]]) }
                let want = (qcTot - qin) * vegDamp(k)
                let er = erodeCell(k, min(want, max(0, bed.h[k] - lowest) * 0.5), bed)
                qout += er
            }
            if qout > 0 && qcTot > 1e-30 {
                for t in 0..<cnt { pqs[nbK[t]] += qout * (nbQc[t] / qcTot) }
            }
        }
        }}}}}}}}}}}
    }

    private func transportLimited(dt: Double) {
        let cs = cfg.cellSize
        guard cs > 0, cs.isFinite else { return }
        let sqrt2 = 2.0.squareRoot()
        let kt = cfg.transportCap
        let m = cfg.mExp
        fill(&qs, 0)
        var oi = cfg.count - 1
        while oi >= 0 {
            let k = Int(order[oi]); oi -= 1
            let r = receiver[k]
            let qin = qs[k]
            if r < 0 {
                let room = max(0, cfg.sea - h[k])
                depositCell(k, min(qin, room))
                continue
            }
            let ri = Int(r)
            let ki = k % n, kj = k / n
            let rii = ri % n, rjj = ri / n
            let dist = (ki != rii && kj != rjj) ? cs * sqrt2 : cs
            let a = area[k]
            let s = max(0, (hf[k] - hf[ri]) / dist)
            let qc = kt * pow(a, m) * s
            if qin > qc {
                var dep = qin - qc
                let room = max(0, (hf[k] - h[k])) + 0.02
                dep = min(dep, room)
                qs[ri] += qin - depositCell(k, dep)
            } else {
                let damp = isChannel[k] ? cfg.channelErodeDamp : 1.0
                let kBed = lithErodeK.count == cfg.count ? cfg.kRock * lithErodeK[k] : cfg.kRock
                let kErode = (sed[k] > cfg.sedCoverThresh ? cfg.kSed : kBed) * vegDamp(k)
                let want = min(qc - qin, kErode * pow(a, m) * s * dt) * damp
                let removable = max(0, h[k] - h[ri]) * 0.5
                let er = erodeCell(k, min(want, removable))
                qs[ri] += qin + er
            }
        }
    }

    private func outletIncision(dt: Double, minAreaCells: Double = 0) {
        let cs = cfg.cellSize
        guard cs > 0, cs.isFinite else { return }
        let sqrt2 = 2.0.squareRoot()
        let minA = minAreaCells * cs * cs
        let m = cfg.mExp
        let cnt = cfg.count, nn = n, sea = cfg.sea, kOut = cfg.outletErode
        let lithOn = lithErodeK.count == cnt
        let lithArr = lithOn ? lithErodeK : [1.0]
        if areaPow.count != cnt { areaPow = .init(repeating: 0, count: cnt) }
        if incisionGate.count != cnt { incisionGate = .init(repeating: 0, count: cnt) }
        if incisionKErode.count != cnt { incisionKErode = .init(repeating: 0, count: cnt) }
        areaPow.withUnsafeMutableBufferPointer { apb in
        incisionGate.withUnsafeMutableBufferPointer { gb in
        incisionKErode.withUnsafeMutableBufferPointer { kb in
        area.withUnsafeBufferPointer { ab in
        h.withUnsafeBufferPointer { hb in
        lithArr.withUnsafeBufferPointer { lkb in
        veg.withUnsafeBufferPointer { vb in
        vegClass.withUnsafeBufferPointer { vcb in
        vegTypeFactor.withUnsafeBufferPointer { tfb in
        receiver.withUnsafeBufferPointer { rb in
        endorheicBasin.withUnsafeBufferPointer { eb in
            let pap = apb.baseAddress!, pa = ab.baseAddress!, ph0 = hb.baseAddress!
            let pgate = gb.baseAddress!, pker = kb.baseAddress!
            let pveg = vb.baseAddress!, pcls = vcb.baseAddress!, ptf = tfb.baseAddress!
            let prec0 = rb.baseAddress!, pend = eb.baseAddress!
            let plith = lkb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi {
                    var g: Int8 = 1
                    if ph0[k] <= sea { g = 0 }
                    else if minA > 0 && pa[k] < minA { g = 0 }
                    else if pend[k] == .water { g = 0 }
                    else if prec0[k] < 0 {
                        g = pend[k] != .none ? 0 : 2
                    }
                    pgate[k] = g
                    guard g != 0 else { continue }
                    pap[k] = pow(pa[k], m)
                    pker[k] = kOut * max(0, 1 - 0.6 * ptf[Int(pcls[k])] * pveg[k])
                                  * (lithOn ? plith[k] : 1.0)
                }
            }
        }}}}}}}}}}}
        withBed { bed in
        areaPow.withUnsafeBufferPointer { apb in
        incisionGate.withUnsafeBufferPointer { gb in
        incisionKErode.withUnsafeBufferPointer { kb in
        order.withUnsafeBufferPointer { ob in
        receiver.withUnsafeBufferPointer { rb in
            let ph = bed.h, pap = apb.baseAddress!
            let pgate = gb.baseAddress!, pker = kb.baseAddress!
            let pord = ob.baseAddress!, prec = rb.baseAddress!
        for oi in 0..<cnt {
            let k = Int(pord[oi])
            let g = pgate[k]
            if g == 0 { continue }
            let hr: Double
            let dist: Double
            if g == 2 {
                hr = sea
                dist = cs
            } else {
                let ri = Int(prec[k])
                if ph[k] <= ph[ri] { continue }
                hr = ph[ri]
                let dIdx = k > ri ? k - ri : ri - k
                dist = (dIdx == nn - 1 || dIdx == nn + 1) ? cs * sqrt2 : cs
            }
            let f = pker[k] * dt * pap[k] / dist
            let hNew = (ph[k] + f * hr) / (1 + f)
            erodeCellTo(k, hNew, bed)
        }
        }}}}}}
    }

    private func channelCarve(dt: Double) {
        let cs = cfg.cellSize
        let cellArea = cs * cs
        let minA = cfg.channelFlowMinCells * cellArea
        let fullA = cfg.channelFlowFullCells * cellArea
        let targetDepth = cfg.channelTargetDepth
        let maximumCellSize = 0.25
        let depthMultiplier = 1.5
        let relaxationYears = 3000.0
        let bankDepthFraction = 0.45
        let bankRelaxationFraction = 0.45
        guard cs <= maximumCellSize, targetDepth > 0, minA > 0, fullA > minA else { return }
        let nn = n, cnt = cfg.count, sea = cfg.sea
        let capF = Terrain.relaxFraction(dt: dt, tau: relaxationYears)
        let lakeMarginDepth = 0.026
        
        let beltOn = cfg.meanderEnabled && cfg.meanderBelt
        let beltMinA = cfg.meanderBeltMinCells * cellArea, beltFlat = cfg.meanderFlatSlope
        if carveStatus.count != cnt { carveStatus = .init(repeating: false, count: cnt) }
        area.withUnsafeBufferPointer { ab in
        inBelt.withUnsafeBufferPointer { beltb in
        carveStatus.withUnsafeMutableBufferPointer { stb in
            let pa0 = ab.baseAddress!, pbelt0 = beltb.baseAddress!
            let pst = stb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi {
                    pst[k] = pa0[k] >= minA && !(beltOn && pbelt0[k])
                }
            }
        }}}
        hf.withUnsafeBufferPointer { hfb in
        receiver.withUnsafeBufferPointer { recb in
        area.withUnsafeBufferPointer { ab in
        order.withUnsafeBufferPointer { ob in
        inBelt.withUnsafeBufferPointer { beltb in
        carveStatus.withUnsafeBufferPointer { stb in
        withBed { bed in
            let ph = bed.h, prec = recb.baseAddress!, pa = ab.baseAddress!, pord = ob.baseAddress!
            let phf = hfb.baseAddress!, pbelt = beltb.baseAddress!
            let pst = stb.baseAddress!
            for oi in 0..<cnt {
                let k = Int(pord[oi])
                if !pst[k] { continue }
                if ph[k] <= sea { continue }
                if phf[k] - ph[k] > lakeMarginDepth { continue }
                if beltOn && pbelt[k] { continue }
                let a = pa[k]
                if a < minA { continue }
                if beltOn && a >= beltMinA {
                    let ki0 = k % nn, kj0 = k / nn
                    if ki0 >= 2, kj0 >= 2, ki0 <= nn - 3, kj0 <= nn - 3,
                       Terrain.macroSlope(ph, k, nn) / cs < beltFlat { continue }
                }
                let r = Int(prec[k])
                if r < 0 || r == k { continue }
                if ph[r] <= sea { continue }
                
                let rj = r / nn, ri = r % nn
                let kj = k / nn, ki = k % nn
                
                var touchesLake = false
                for dj in -1...1 {
                    for di in -1...1 {
                        let ni = ki + di, nj = kj + dj
                        if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                        if phf[nj * nn + ni] - ph[nj * nn + ni] > lakeMarginDepth { touchesLake = true; break }
                    }
                    if touchesLake { break }
                }
                if touchesLake { continue }
                let qi = -(rj - kj)
                let qj = ri - ki
                
                var acc = 0.0, m = 0
                for s in [-3, -2, 2, 3] {
                    let xi = ki + qi * s, xj = kj + qj * s
                    if xi < 0 || xi >= nn || xj < 0 || xj >= nn { continue }
                    acc += ph[xj * nn + xi]; m += 1
                }
                guard m >= 2 else { continue }
                let flankH = acc / Double(m)
                
                let x = min(1.0, (a - minA) / (fullA - minA))
                let s = x * x * (3.0 - 2.0 * x)
                let dEq = targetDepth * depthMultiplier * s
                
                let targetH = flankH - dEq
                let minAllowed = ph[r] + 1e-4
                let finalTarget = max(targetH, minAllowed)
                
                if ph[k] > finalTarget {
                    let delta = (ph[k] - finalTarget) * capF
                    _ = erodeCell(k, delta, bed)
                }
                
                let bankTarget = max(flankH - bankDepthFraction * dEq, finalTarget)
                for side in [-1, 1] {
                    let bi = ki + qi * side, bj = kj + qj * side
                    if bi < 0 || bi >= nn || bj < 0 || bj >= nn { continue }
                    let bk = bj * nn + bi
                    if phf[bk] - ph[bk] > 0.005 { continue }
                    var bTouchesLake = false
                    for dj in -1...1 {
                        for di in -1...1 {
                            let bni = bi + di, bnj = bj + dj
                            if bni < 0 || bni >= nn || bnj < 0 || bnj >= nn { continue }
                            if phf[bnj * nn + bni] - ph[bnj * nn + bni] > 0.005 { bTouchesLake = true; break }
                        }
                        if bTouchesLake { break }
                    }
                    if bTouchesLake { continue }
                    if ph[bk] > bankTarget && ph[bk] > sea {
                        let bDelta = (ph[bk] - bankTarget) * capF * bankRelaxationFraction
                        _ = erodeCell(bk, bDelta, bed)
                    }
                }
            }
        }}}}}}}
    }

    private func fillLakes(dt: Double) {
        let rate = Terrain.relaxFraction(dt: dt, tau: 3000.0)
        for k in 0..<cfg.count where hf[k] > cfg.sea {
            let deficit = hf[k] - h[k]
            if deficit > 0.001 {
                let add = deficit * rate
                h[k] += add
                sed[k] += add
            }
        }
    }

    private func fillShallowPonds(dt: Double) {
        let rate = Terrain.relaxFraction(dt: dt, tau: cfg.puddleFillYears)
        let sea = cfg.sea, nn = n, cnt = cfg.count
        let deepThresh = cfg.puddleFillDepth, coreCells = cfg.puddleLakeCoreCells
        fill(&pondSeen, false)
        var comp: [Int32] = []
        var stack: [Int32] = []
        let flowLimit = cfg.puddleFillSkipsFlowCells && area.count == cnt
            ? cfg.channelFlowMinCells * cfg.cellSize * cfg.cellSize
            : .infinity
        let iceGate = underIce.count == cnt
        let iceArr = iceGate ? underIce : [false]
        hf.withUnsafeBufferPointer { hfb in
        h.withUnsafeMutableBufferPointer { hb in
        sed.withUnsafeMutableBufferPointer { sb in
        pondSeen.withUnsafeMutableBufferPointer { psb in
        endorheicBasin.withUnsafeBufferPointer { ebb in
        isChannel.withUnsafeBufferPointer { icb in
        regenPending.withUnsafeBufferPointer { rpb in
        area.withUnsafeBufferPointer { arb in
        iceArr.withUnsafeBufferPointer { iab in
        let phf = hfb.baseAddress!, ph = hb.baseAddress!, psed = sb.baseAddress!
        let punder = iab.baseAddress!
        let pseen = psb.baseAddress!, pend = ebb.baseAddress!
        let pchan = icb.baseAddress!, pregen = rpb.baseAddress!
        let parea = arb.baseAddress!
        @inline(__always) func push(_ k: Int, _ stack: inout [Int32]) {
            if !pseen[k] && phf[k] > sea && phf[k] - ph[k] > 0.001
                && pend[k] != .water {
                pseen[k] = true
                stack.append(Int32(k))
            }
        }
        for s in 0..<cnt where !pseen[s] && phf[s] > sea && phf[s] - ph[s] > 0.001
                                     && pend[s] != .water {
            comp.removeAll(keepingCapacity: true)
            stack.removeAll(keepingCapacity: true)
            stack.append(Int32(s)); pseen[s] = true
            var deepCells = 0
            while let kk = stack.popLast() {
                let k = Int(kk)
                comp.append(kk)
                if phf[k] - ph[k] > deepThresh { deepCells += 1 }
                let i = k % nn, j = k / nn
                if i > 0 { push(k - 1, &stack) }
                if i < nn - 1 { push(k + 1, &stack) }
                if j > 0 { push(k - nn, &stack) }
                if j < nn - 1 { push(k + nn, &stack) }
            }
            if deepCells >= coreCells { continue }
            for kk in comp {
                let k = Int(kk)
                if pchan[k] { continue }
                if parea[k] > flowLimit { continue }
                if iceGate && punder[k] { continue }
                if disturbActive && pregen[k] != 0 { continue }
                let deficit = phf[k] - ph[k]
                if deficit > 0.001 && deficit <= deepThresh {
                    let add = deficit * rate
                    ph[k] += add
                    psed[k] += add
                }
            }
        }
        }}}}}}}}}
    }

    private func floodplainAggradation(dt: Double) {
        let cellArea = cfg.cellSize * cfg.cellSize
        guard cellArea > 0, cellArea.isFinite else { return }
        let minA = cfg.floodplainMinArea
        let rate = Terrain.relaxFraction(dt: dt, tau: cfg.floodplainFillYears)
        if rate <= 0 { return }
        for k in 0..<cfg.count {
            if hf[k] <= cfg.sea || h[k] <= cfg.sea { continue }
            if h[k] > cfg.floodplainMaxElev { continue }
            let cu = area[k] / cellArea
            if cu < minA { continue }
            let mag = log(cu / minA + 1)
            let level = h[k] + cfg.floodplainDepth + cfg.floodplainDepthK * mag
            let w = min(9, max(1, Int((cfg.floodplainWidthK * mag).rounded())))
            let i = k % n, j = k / n
            let jLo = max(0, j - w), jHi = min(n - 1, j + w)
            let iLo = max(0, i - w), iHi = min(n - 1, i + w)
            for nj in jLo...jHi {
                for ni in iLo...iHi {
                    let nb = nj * n + ni
                    if nb == k { continue }
                    if area[nb] / cellArea >= minA { continue }
                    if h[nb] <= cfg.sea { continue }
                    if h[nb] >= level { continue }
                    let add = (level - h[nb]) * rate
                    depositCell(nb, add)
                }
            }
        }
    }

    private func diffusionPass(kappa: Double = 0.0025) {
        if kappa <= 0 { return }
        for j in 0..<n {
            for i in 0..<n {
                let k = idx(i, j)
                let hl = i > 0 ? h[k - 1] : h[k]
                let hr = i < n - 1 ? h[k + 1] : h[k]
                let hd = j > 0 ? h[k - n] : h[k]
                let hu = j < n - 1 ? h[k + n] : h[k]
                scratch[k] = kappa * (hl + hr + hd + hu - 4 * h[k])
            }
        }
        for k in 0..<cfg.count {
            let dh = scratch[k]
            if dh == 0 { continue }
            if dh >= 0 {
                sed[k] += dh
            } else {
                let ds = min(-dh, sed[k])
                sed[k] -= ds
                rock[k] -= (-dh - ds)
            }
            h[k] += dh
        }
    }

    private func hillslopeDiffusion(base: Double) {
        if base <= 0 { return }
        let nn = n, cnt = cfg.count
        let lithDC = lithHardness.count == cnt ? cfg.lithDiffusionContrast : 0
        let lithArr = lithDC != 0 ? lithHardness : [0.0]
        let chDamp = cfg.channelDiffusionDamp
        let chOn = chDamp < 1 && area.count == cnt
        let chCellArea = cfg.cellSize * cfg.cellSize
        let chLo = cfg.channelFlowMinCells * chCellArea
        let chHi = max(chLo + 1e-12, cfg.channelFlowFullCells * chCellArea)
        let chArr = chOn ? area : [0.0]
        h.withUnsafeMutableBufferPointer { hb in
        sed.withUnsafeMutableBufferPointer { sb in
        rock.withUnsafeMutableBufferPointer { rkb in
        veg.withUnsafeBufferPointer { vb in
        lithArr.withUnsafeBufferPointer { ldb in
        chArr.withUnsafeBufferPointer { cab in
        scratch.withUnsafeMutableBufferPointer { scb in
            let ph = hb.baseAddress!, psed = sb.baseAddress!, prock = rkb.baseAddress!
            let pveg = vb.baseAddress!, psc = scb.baseAddress!
            let phard = ldb.baseAddress!, parea = cab.baseAddress!
            parallel(nn) { jLo, jHi in
            for j in jLo..<jHi {
                let row = j * nn
                let innerRow = j > 0 && j < nn - 1
                for i in 0..<nn {
                    let k = row + i
                    let hl: Double, hr: Double, hd: Double, hu: Double
                    if innerRow && i > 0 && i < nn - 1 {
                        hl = ph[k - 1]; hr = ph[k + 1]
                        hd = ph[k - nn]; hu = ph[k + nn]
                    } else {
                        hl = i > 0 ? ph[k - 1] : ph[k]
                        hr = i < nn - 1 ? ph[k + 1] : ph[k]
                        hd = j > 0 ? ph[k - nn] : ph[k]
                        hu = j < nn - 1 ? ph[k + nn] : ph[k]
                    }
                    let lap = hl + hr + hd + hu - 4 * ph[k]
                    if lap == 0 {
                        psc[k] = 0
                        continue
                    }
                    var localK = base
                    if ph[k] > 0.42 {
                        let gx = (hr - hl) * 0.5, gy = (hu - hd) * 0.5
                        let slope = (gx * gx + gy * gy).squareRoot()
                        let steep = min(1, slope * 26)
                        let high = min(1, (ph[k] - 0.42) / 0.35)
                        let soil = min(1, psed[k] / 0.02 + pveg[k])
                        let bare = steep * high * max(0, 1 - soil)
                        localK = base * (1 - 0.92 * bare)
                    }
                    if lithDC != 0 { localK *= max(0.05, 1 - lithDC * phard[k]) }
                    if chOn && parea[k] > chLo {
                        let x = min(1, (parea[k] - chLo) / (chHi - chLo))
                        let s = x * x * (3 - 2 * x)
                        localK *= 1 - (1 - chDamp) * s
                    }
                    psc[k] = localK * lap
                }
            }
            }
            parallel(cnt) { lo, hi in
            for k in lo..<hi {
                let dh = psc[k]
                if dh == 0 { continue }
                if dh >= 0 {
                    psed[k] += dh
                } else {
                    let ds = min(-dh, psed[k])
                    psed[k] -= ds
                    prock[k] -= (-dh - ds)
                }
                ph[k] += dh
            }
            }
        }}}}}}}
    }

    private func wavePass(relax: Double) {
        if relax <= 0 { return }
        let nn = n, sea = cfg.sea, band = cfg.waveBand, talus = cfg.waveTalus
        h.withUnsafeMutableBufferPointer { hb in
        sed.withUnsafeMutableBufferPointer { sb in
        rock.withUnsafeMutableBufferPointer { rb in
        let ph = hb.baseAddress!, psed = sb.baseAddress!, prock = rb.baseAddress!
        for j in 1..<(nn - 1) {
            for i in 1..<(nn - 1) {
                let k = j * nn + i
                if abs(ph[k] - sea) > band { continue }
                var best = -1
                var bestDrop = talus
                for nb in [k - 1, k + 1, k - nn, k + nn] {
                    let d = ph[k] - ph[nb]
                    if d > bestDrop { bestDrop = d; best = nb }
                }
                if best >= 0 {
                    let move = (bestDrop - talus) * 0.5 * relax
                    let ms = min(move, psed[k])
                    let mr = (move - ms) * 0.5
                    psed[k] -= ms
                    prock[k] -= mr
                    ph[k] -= ms + mr
                    psed[best] += ms + mr
                    ph[best] += ms + mr
                }
            }
        }
        }}}
    }

    private func waveSchedule(dt: Double) -> (count: Int, relax: Double) {
        let total = cfg.waveRelax * dt / 100
        let count = max(1, Int((dt / 100).rounded(.up)))
        return (count, total / Double(count))
    }

    private func deltaHeightSum(collectMouths: Bool = false) -> (sum: Double, land: Int) {
        let cnt = cfg.count, sea = cfg.sea, blocks = 64
        let depth = cfg.hydraulic.poolDepth
        let minA = cfg.deltaMinCells * cfg.cellSize * cfg.cellSize
        var sums = [Double](repeating: 0, count: blocks), lands = [Int](repeating: 0, count: blocks)
        var found = [[Int]](repeating: [], count: collectMouths ? blocks : 0)
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeBufferPointer { fb in
        area.withUnsafeBufferPointer { ab in
        receiver.withUnsafeBufferPointer { rb in
        sums.withUnsafeMutableBufferPointer { sb in
        lands.withUnsafeMutableBufferPointer { lb in
        found.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let ph = hb.baseAddress!, ps = sb.baseAddress!, pl = lb.baseAddress!
            nonisolated(unsafe) let phf = fb.baseAddress!, pa = ab.baseAddress!, prb = rb.baseAddress!
            nonisolated(unsafe) let pout = out.baseAddress
            DispatchQueue.concurrentPerform(iterations: blocks) { c in
                var a0 = 0.0, a1 = 0.0, a2 = 0.0, a3 = 0.0, land = 0
                let lo = cnt * c / blocks, hi = cnt * (c + 1) / blocks
                var k = lo
                while k + 4 <= hi {
                    a0 += ph[k]; a1 += ph[k + 1]; a2 += ph[k + 2]; a3 += ph[k + 3]
                    land += (ph[k] > sea ? 1 : 0) + (ph[k + 1] > sea ? 1 : 0)
                        + (ph[k + 2] > sea ? 1 : 0) + (ph[k + 3] > sea ? 1 : 0)
                    k += 4
                }
                while k < hi { a0 += ph[k]; land += ph[k] > sea ? 1 : 0; k += 1 }
                ps[c] = (a0 + a1) + (a2 + a3); pl[c] = land
                guard collectMouths, let pout else { return }
                var local: [Int] = []
                for m in lo..<hi where pa[m] >= minA {
                    guard phf[m] > sea, phf[m] - ph[m] <= depth else { continue }
                    let r = Int(prb[m])
                    if r >= 0 && phf[r] <= sea { local.append(m) }
                }
                pout[c] = local
            }
        }}}}}}}
        if collectMouths {
            deltaMouthCells.removeAll(keepingCapacity: true)
            for list in found { deltaMouthCells.append(contentsOf: list) }
        }
        return (sums.reduce(0, +), lands.reduce(0, +))
    }

    private struct DeltaJet {
        var ox: Double, oz: Double, ux: Double, uz: Double
        var w: Double
        var cx: Double, cz: Double, r: Double, elong: Double
        var p2: Double, p3: Double
        var lx: Double, lz: Double
        var share: Double
        var left = -1, right = -1
    }

    @inline(__always) private static func deltaNoise(_ block: Int, _ jet: Int, _ salt: Int) -> Double {
        var v = UInt64(truncatingIfNeeded: block) &* 0x9E37_79B9_7F4A_7C15
        v ^= UInt64(truncatingIfNeeded: jet &+ 1) &* 0xC2B2_AE3D_27D4_EB4F
        v ^= UInt64(truncatingIfNeeded: salt &+ 7) &* 0x1656_67B1_9E37_79F9
        v ^= v >> 33; v = v &* 0xFF51_AFD7_ED55_8CCD
        v ^= v >> 33; v = v &* 0xC4CE_B9FE_1A85_EC53
        v ^= v >> 33
        return Double(v >> 11) / 9_007_199_254_740_992.0
    }

    private func deltaDeposit(yieldPerCell: Double) {
        let nn = n, sea = cfg.sea
        let cs = cfg.cellSize
        guard cs > 0, cs.isFinite, yieldPerCell > 0, yieldPerCell.isFinite else { return }
        let cellArea = cs * cs
        let mouths = deltaMouthCells.map { k -> (land: Int, load: Double) in
            (k, area[k] / cellArea * yieldPerCell * cfg.deltaTrapFraction)
        }
        guard !mouths.isEmpty else { return }
        fill(&visited, false)
        fill(&pondSeen, false)
        let topset = cfg.deltaTopset
        let barDist = cfg.deltaBarDistanceWidths, barRad = cfg.deltaBarRadiusWidths
        let elong = max(1, cfg.deltaBarElongation)
        let half = cfg.deltaBifurcationAngle / 2, jitter = cfg.deltaJitter
        let wMin = cfg.deltaMinHalfWidth
        let generations = max(0, cfg.deltaGenerations)
        var jets: [DeltaJet] = []
        var corridor: [Int32] = []
        var touched: [Int32] = []
        var levee: [(k: Int32, t: Double, ceil: Double)] = []
        hf.withUnsafeBufferPointer { hfb in
        receiver.withUnsafeBufferPointer { rb in
        area.withUnsafeBufferPointer { ab in
        visited.withUnsafeMutableBufferPointer { vb in
        pondSeen.withUnsafeMutableBufferPointer { nb in
        withBed { bed in
            let phf = hfb.baseAddress!, prec = rb.baseAddress!, pa = ab.baseAddress!
            let pv = vb.baseAddress!, pno = nb.baseAddress!
            func markCorridor(_ ax: Double, _ az: Double, _ bx: Double, _ bz: Double, _ w: Double) {
                let dx = bx - ax, dz = bz - az
                let len2 = max(1e-12, dx * dx + dz * dz)
                let pad = w + 1
                let i0 = max(1, Int((min(ax, bx) - pad).rounded(.down)))
                let i1 = min(nn - 2, Int((max(ax, bx) + pad).rounded(.up)))
                let j0 = max(1, Int((min(az, bz) - pad).rounded(.down)))
                let j1 = min(nn - 2, Int((max(az, bz) + pad).rounded(.up)))
                if i0 > i1 || j0 > j1 { return }
                for j in j0...j1 {
                    for i in i0...i1 {
                        let px = Double(i) - ax, pz = Double(j) - az
                        let t = min(1, max(0, (px * dx + pz * dz) / len2))
                        let ex = px - t * dx, ez = pz - t * dz
                        if ex * ex + ez * ez <= w * w {
                            let k = j * nn + i
                            if !pno[k] { pno[k] = true; corridor.append(Int32(k)) }
                        }
                    }
                }
            }
            func leveeCells(_ ax: Double, _ az: Double, _ bx: Double, _ bz: Double,
                            _ w: Double, _ t0: Double) {
                let dx = bx - ax, dz = bz - az
                let len2 = dx * dx + dz * dz
                if len2 < 1e-12 { return }
                let len = len2.squareRoot()
                let pad = 2 * w + 1
                let i0 = max(1, Int((min(ax, bx) - pad).rounded(.down)))
                let i1 = min(nn - 2, Int((max(ax, bx) + pad).rounded(.up)))
                let j0 = max(1, Int((min(az, bz) - pad).rounded(.down)))
                let j1 = min(nn - 2, Int((max(az, bz) + pad).rounded(.up)))
                if i0 > i1 || j0 > j1 { return }
                for j in j0...j1 {
                    for i in i0...i1 {
                        let px = Double(i) - ax, pz = Double(j) - az
                        let along = (px * dx + pz * dz) / len2
                        if along < 0 || along > 1 { continue }
                        let ex = px - along * dx, ez = pz - along * dz
                        let e = (ex * ex + ez * ez).squareRoot()
                        if e <= w || e > 2 * w { continue }
                        levee.append((k: Int32(j * nn + i), t: t0 + along * len,
                                      ceil: sea + topset * (1 - (e - w) / w)))
                    }
                }
            }
            for mouth in mouths {
                let k0 = mouth.land
                let mi = k0 % nn, mj = k0 / nn
                guard mi >= 2, mi < nn - 2, mj >= 2, mj < nn - 2 else { continue }
                var up = k0
                for _ in 0..<8 {
                    var best = -1, bestA = 0.0
                    let ui = up % nn, uj = up / nn
                    for dj in -1...1 { for di in -1...1 where di != 0 || dj != 0 {
                        let ii = ui + di, jj = uj + dj
                        if ii < 0 || ii >= nn || jj < 0 || jj >= nn { continue }
                        let c = jj * nn + ii
                        if Int(prec[c]) == up && pa[c] > bestA { bestA = pa[c]; best = c }
                    } }
                    if best < 0 { break }
                    up = best
                }
                let r0 = Int(prec[k0])
                var rx = Double(r0 % nn - up % nn), rz = Double(r0 / nn - up / nn)
                let rl = (rx * rx + rz * rz).squareRoot()
                guard rl > 1e-9 else { continue }
                rx /= rl; rz /= rl
                var sx = 0.0, sz = 0.0
                let win = 8, low = sea + 2 * topset
                for dj in -win...win { for di in -win...win {
                    let ii = mi + di, jj = mj + dj
                    if ii < 0 || ii >= nn || jj < 0 || jj >= nn { continue }
                    let c = jj * nn + ii
                    if phf[c] <= sea || bed.h[c] <= low { sx += Double(di); sz += Double(dj) }
                } }
                let sl = (sx * sx + sz * sz).squareRoot()
                if sl > 1e-9 { sx /= sl; sz /= sl } else { sx = rx; sz = rz }
                var ux = rx + sx, uz = rz + sz
                let ul = (ux * ux + uz * uz).squareRoot()
                if ul > 1e-9 { ux /= ul; uz /= ul } else { ux = sx; uz = sz }
                let block = (mj >> 3) * nn + (mi >> 3)
                func noise(_ jet: Int, _ salt: Int) -> Double {
                    2 * Terrain.deltaNoise(block, jet, salt) - 1
                }
                jets.removeAll(keepingCapacity: true)
                let w0 = WaterRender.ribbonHalfWidthCells(dischargeCells: pa[k0] / cellArea,
                                                          referenceCells: cfg.renderMinCells)
                func makeJet(_ index: Int, _ ox: Double, _ oz: Double, _ dx: Double, _ dz: Double,
                             _ w: Double, share: Double, from lx: Double, _ lz: Double) -> DeltaJet {
                    let b = 2 * w
                    let dist = barDist * b * (1 + jitter * noise(index, 10))
                    let r = barRad * b * (1 + 0.5 * jitter * noise(index, 11))
                    let tau = 2 * Double.pi
                    return DeltaJet(ox: ox, oz: oz, ux: dx, uz: dz, w: w,
                                    cx: ox + dist * dx, cz: oz + dist * dz, r: r, elong: elong,
                                    p2: tau * Terrain.deltaNoise(block, index, 12),
                                    p3: tau * Terrain.deltaNoise(block, index, 13),
                                    lx: lx, lz: lz, share: share)
                }
                jets.append(makeJet(0, Double(mi), Double(mj), ux, uz, w0, share: 1,
                                    from: Double(mi), Double(mj)))
                var genStart = 0
                for _ in 0..<generations {
                    let genEnd = jets.count
                    for p in genStart..<genEnd {
                        let pj = jets[p]
                        if pj.w * 0.5.squareRoot() < wMin * (1 - 1e-9) { continue }
                        let f = 0.5 + 0.5 * jitter * noise(p, 1)
                        for side in [-1.0, 1.0] {
                            let s = side < 0 ? f : 1 - f
                            let wd = max(wMin, pj.w * s.squareRoot())
                            let ang = half * 2 * (1 - s) * (1 + 0.5 * jitter * noise(p, side < 0 ? 2 : 3))
                            let ca = cos(ang), sa = sin(ang) * side
                            let px = -pj.uz * side, pz = pj.ux * side
                            let fx = pj.cx + (pj.r + wd) * px, fz = pj.cz + (pj.r + wd) * pz
                            let dx = pj.ux * ca - pj.uz * sa
                            let dz = pj.uz * ca + pj.ux * sa
                            let child = makeJet(jets.count, fx, fz, dx, dz, wd, share: pj.share * s,
                                                from: pj.cx - (pj.r + pj.w) * pj.ux,
                                                pj.cz - (pj.r + pj.w) * pj.uz)
                            let ci = Int(child.cx.rounded()), cj = Int(child.cz.rounded())
                            if ci < 2 || ci > nn - 3 || cj < 2 || cj > nn - 3 { continue }
                            let cc = cj * nn + ci
                            if phf[cc] > sea && bed.h[cc] > sea + 2 * topset { continue }
                            jets.append(child)
                            if side < 0 { jets[p].left = jets.count - 1 } else { jets[p].right = jets.count - 1 }
                        }
                    }
                    genStart = genEnd
                }
                for j in jets {
                    let sx = j.cx - (j.r + j.w) * j.ux, sz = j.cz - (j.r + j.w) * j.uz
                    markCorridor(j.lx, j.lz, j.ox, j.oz, j.w)
                    markCorridor(j.ox, j.oz, sx, sz, j.w)
                }
                var load = mouth.load
                var reachTree = 0.0
                for j in jets {
                    let dx = j.cx - Double(mi), dz = j.cz - Double(mj)
                    reachTree = max(reachTree, (dx * dx + dz * dz).squareRoot() + 2 * j.r * j.elong)
                }
                let rt = Int(reachTree.rounded(.up)), marsh = sea + 0.3 * topset
                for jj in max(1, mj - rt)...min(nn - 2, mj + rt) where load > 0 {
                    for ii in max(1, mi - rt)...min(nn - 2, mi + rt) where load > 0 {
                        let c = jj * nn + ii
                        guard phf[c] > sea, bed.h[c] < sea else { continue }
                        let dx = Double(ii - mi), dz = Double(jj - mj)
                        if dx * dx + dz * dz > reachTree * reachTree { continue }
                        load -= depositCell(c, min(marsh - bed.h[c], load), bed)
                    }
                }
                var pending: [(jet: Int, load: Double)] = [(0, load)]
                var head = 0
                while head < pending.count {
                    let (ji, load) = pending[head]; head += 1
                    let j = jets[ji]
                    var remaining = load
                    let sx = j.cx - (j.r + j.w) * j.ux, sz = j.cz - (j.r + j.w) * j.uz
                    levee.removeAll(keepingCapacity: true)
                    leveeCells(j.lx, j.lz, j.ox, j.oz, j.w, 0)
                    let lead = ((j.ox - j.lx) * (j.ox - j.lx) + (j.oz - j.lz) * (j.oz - j.lz)).squareRoot()
                    leveeCells(j.ox, j.oz, sx, sz, j.w, lead)
                    levee.sort { $0.t < $1.t || ($0.t == $1.t && $0.k < $1.k) }
                    for c in levee where remaining > 0 {
                        let k = Int(c.k)
                        if (pno[k] && phf[k] <= sea) || bed.h[k] >= c.ceil { continue }
                        let room = c.ceil - bed.h[k]
                        if room > 0 { remaining -= depositCell(k, min(room, remaining), bed) }
                    }
                    if remaining <= 0 { break }
                    let wobble = 0.5 * jitter
                    let c2 = cos(j.p2), s2 = sin(j.p2), c3 = cos(j.p3), s3 = sin(j.p3)
                    func barKey(_ x: Int, _ z: Int) -> Double {
                        let ex = Double(x) - j.cx, ez = Double(z) - j.cz
                        let along = ex * j.ux + ez * j.uz, across = -ex * j.uz + ez * j.ux
                        let a = along > 0 ? along / j.elong : along
                        let d2 = a * a + across * across
                        if d2 < 1e-12 { return 0 }
                        let rl = (along * along + across * across).squareRoot()
                        let co = along / rl, si = across / rl
                        let sin2 = 2 * si * co, cos2 = co * co - si * si
                        let sin3 = si * (3 - 4 * si * si), cos3 = co * (4 * co * co - 3)
                        let rr = 1 + wobble * (0.6 * (sin2 * c2 + cos2 * s2) + 0.4 * (sin3 * c3 + cos3 * s3))
                        return d2 / (rr * rr)
                    }
                    let toe2 = 4 * j.r * j.r
                    let ci = Int(j.cx.rounded()), cj = Int(j.cz.rounded())
                    guard ci >= 1, ci < nn - 1, cj >= 1, cj < nn - 1 else { continue }
                    touched.removeAll(keepingCapacity: true)
                    heap.removeAll()
                    heap.withRaw { ref in
                        let c0 = cj * nn + ci
                        pv[c0] = true; touched.append(Int32(c0))
                        ref.push(key: barKey(ci, cj), cell: Int32(c0), col: 0)
                        while ref.size > 0 && remaining > 0 {
                            let e = ref.pop()
                            let c = Int(e.cell)
                            if !pno[c] || phf[c] > sea {
                                let room = sea + topset * (1 - e.key.squareRoot() / j.r) - bed.h[c]
                                if room > 0 {
                                    let add = min(room, remaining)
                                    remaining -= depositCell(c, add, bed)
                                    if add < room { break }
                                }
                            }
                            let i = c % nn, jj = c / nn
                            for dj in -1...1 {
                                for di in -1...1 where di != 0 || dj != 0 {
                                    let ni = i + di, nj = jj + dj
                                    if ni < 1 || ni >= nn - 1 || nj < 1 || nj >= nn - 1 { continue }
                                    let nbk = nj * nn + ni
                                    if pv[nbk] || bed.h[nbk] >= sea + topset { continue }
                                    let d2 = barKey(ni, nj)
                                    if d2 > toe2 { continue }
                                    pv[nbk] = true; touched.append(Int32(nbk))
                                    ref.push(key: d2, cell: Int32(nbk), col: 0)
                                }
                            }
                        }
                    }
                    for c in touched { pv[Int(c)] = false }
                    if remaining > 0 {
                        let kids = [j.left, j.right].filter { $0 >= 0 }
                        let total = kids.reduce(0.0) { $0 + jets[$1].share }
                        if total > 0 {
                            for c in kids { pending.append((c, remaining * jets[c].share / total)) }
                        }
                    }
                }
                for c in corridor { pno[Int(c)] = false }
                corridor.removeAll(keepingCapacity: true)
            }
        }}}}}}
        heap.removeAll()
    }

    private func applyUplift(dt: Double, gatedAmount us: Double = 0) {
        let uf = cfg.upliftPer100y * dt / 100
        if uf == 0 && us <= 0 { return }
        let sea = cfg.sea, floor = cfg.floor
        let isoHigh = cfg.isoHighClamp, isoLow = cfg.isoLowRange
        h.withUnsafeMutableBufferPointer { hb in
        rock.withUnsafeMutableBufferPointer { rb in
        upliftBase.withUnsafeBufferPointer { ub in
            let ph = hb.baseAddress!, prock = rb.baseAddress!, pu = ub.baseAddress!
            parallel(cfg.count) { lo, hi in
                for k in lo..<hi {
                    let gated = (us > 0 && ph[k] > sea) ? max(0, pu[k]) * us : 0
                    let du0 = pu[k] * uf + gated
                    var du: Double
                    if du0 > 0 {
                        du = du0 * max(0, 1 - ph[k] / isoHigh)
                    } else {
                        du = du0 * min(1, (ph[k] - floor) / isoLow)
                    }
                    if ph[k] + du < floor { du = floor - ph[k] }
                    prock[k] += du
                    ph[k] += du
                }
            }
        }}}
    }

    public func recomputeFlowAfterEdit() {
        computeFlow()
        snapWaterLevel()
        updateClimate(dt: 0)
        updateHeightBands()
    }

    public func sculpt(gx: Double, gz: Double, radiusWorld: Double, dir: Double,
                       strength: Double = 1.0) {
        guard dir.isFinite && strength.isFinite,
              abs(dir) < 1e9, abs(strength) < 1e9,
              dir != 0, strength != 0 else { return }
        forEachBrushCell(gx: gx, gz: gz, radiusWorld: radiusWorld) { k, w in
            if applyDelta(k, dir * 0.006 * strength * w, asRock: true) {
                upliftBase[k] = min(2.0, max(-2.0, upliftBase[k] + dir * 0.006 * strength * w * 1.5))
            }
        }
    }

    public func smooth(gx: Double, gz: Double, radiusWorld: Double, strength: Double = 1.0) {
        guard strength.isFinite, abs(strength) < 1e9 else { return }
        let pull = min(1.0, max(0.0, 0.30 * strength))
        guard pull > 0 else { return }
        guard radiusWorld.isFinite, radiusWorld > 0,
              radiusWorld <= Double(n) * cfg.cellSize else { return }
        let snap = h
        forEachBrushCell(gx: gx, gz: gz, radiusWorld: radiusWorld) { k, w in
            let i = k % n, j = k / n
            var s = 0.0, c = 0.0
            for dj in max(0, j - 1)...min(n - 1, j + 1) {
                for di in max(0, i - 1)...min(n - 1, i + 1) {
                    s += snap[dj * n + di]; c += 1
                }
            }
            applyDelta(k, (s / c - snap[k]) * pull * w, asRock: false)
        }
    }

    public func flatten(gx: Double, gz: Double, radiusWorld: Double,
                        targetHeight: Double, strength: Double = 1.0) {
        guard targetHeight.isFinite && strength.isFinite,
              abs(targetHeight) < 1e9, abs(strength) < 1e9 else { return }
        let pull = min(1.0, max(0.0, 0.18 * strength))
        guard pull > 0 else { return }
        let target = min(1.4, max(cfg.floor, targetHeight))
        forEachBrushCell(gx: gx, gz: gz, radiusWorld: radiusWorld) { k, w in
            applyDelta(k, (target - h[k]) * pull * w, asRock: false)
        }
    }

    public func roughen(gx: Double, gz: Double, radiusWorld: Double, strength: Double = 1.0) {
        guard strength.isFinite, abs(strength) < 1e9, strength != 0 else { return }
        forEachBrushCell(gx: gx, gz: gz, radiusWorld: radiusWorld) { k, w in
            let i = k % n, j = k / n
            let nz = noise.fbm01(Double(i) * 0.11, Double(j) * 0.11, octaves: 4) * 2 - 1
            applyDelta(k, nz * 0.005 * strength * w, asRock: true)
        }
    }

    public func pickaxe(gx: Double, gz: Double, radiusWorld: Double, strength: Double = 1.0) {
        guard radiusWorld.isFinite && strength.isFinite,
              abs(strength) < 1e9, strength > 0,
              radiusWorld <= Double(n) * cfg.cellSize else { return }
        let radius = min(radiusWorld, Terrain.pickaxeMaxCells * cfg.cellSize)
        forEachBrushCell(gx: gx, gz: gz, radiusWorld: radius) { k, w in
            let spike = w * w
            applyDelta(k, -0.02 * strength * spike, asRock: true)
        }
    }

    public static let pickaxeMaxCells = 3.0

    private func forEachBrushCell(gx: Double, gz: Double, radiusWorld: Double,
                                  _ body: (Int, Double) -> Void) {
        guard gx.isFinite && gz.isFinite && radiusWorld.isFinite,
              abs(gx) < 1e9, abs(gz) < 1e9, cfg.cellSize > 0 else { return }
        let rCells = radiusWorld / cfg.cellSize
        if rCells <= 0 || rCells > Double(n) { return }
        let r = Int(rCells.rounded(.up))
        let cx = Int(gx.rounded()), cz = Int(gz.rounded())
        let jLo = max(0, cz - r), jHi = min(n - 1, cz + r)
        let iLo = max(0, cx - r), iHi = min(n - 1, cx + r)
        if jLo > jHi || iLo > iHi { return }
        for j in jLo...jHi {
            for i in iLo...iHi {
                let d = (Double(i) - gx).magnitudeHypot(Double(j) - gz) / rCells
                if d > 1 { continue }
                body(idx(i, j), (1 - d * d) * (1 - d * d))
            }
        }
    }

    @discardableResult
    private func applyDelta(_ k: Int, _ dhRaw: Double, asRock: Bool) -> Bool {
        guard dhRaw.isFinite, abs(dhRaw) < 1e9, dhRaw != 0 else { return false }
        let dh = min(1.4, max(cfg.floor, h[k] + dhRaw)) - h[k]
        let moved: Double
        if dh >= 0 {
            moved = asRock ? raiseRockCell(k, dh) : depositCell(k, dh)
        } else {
            moved = erodeCell(k, -dh)
        }
        let open = moved > 0 || dh == 0
        if open {
            registerDisturbance(k, dh, settles: !asRock)
        }
        return open
    }

    @inline(__always) private func registerDisturbance(_ k: Int, _ dh: Double, settles: Bool) {
        guard cfg.disturbanceEnabled, cfg.disturbanceFullChange > 0, dh != 0 else { return }
        let raw = min(1, abs(dh) / cfg.disturbanceFullChange)
        let old = disturb[k]
        let effInc = min(1, old + raw) - old
        disturb[k] = old + effInc
        disturbActive = true
        if settles { regenPending[k] -= dh * cfg.disturbanceSettle }
        if effInc > 0 && cfg.disturbanceReliefAmp > 0 {
            let i = k % n, j = k / n
            let f = cfg.disturbanceReliefFreq
            let u = noise.fbm01(Double(i) * f + 137, Double(j) * f + 91, octaves: 5) * 2 - 1
            regenPending[k] += effInc * cfg.disturbanceReliefAmp * u
        }
        let keep = disturb[k] >= 1 ? 0 : (1 - disturb[k]) / (1 - old)
        veg[k] *= keep
        streamRate[k] *= keep
        streamMap[k] *= keep
    }

    private func regenerateDisturbed(dt: Double) {
        guard cfg.disturbanceEnabled, disturbActive, dt > 0 else { return }
        let tau = max(1e-9, cfg.disturbanceRecoveryYears)
        let f = Terrain.relaxFraction(dt: dt, tau: tau)
        var maxLeft = 0.0
        for k in 0..<cfg.count {
            let d = disturb[k]
            if d <= 0 { continue }
            let spend = regenPending[k] * f
            if spend != 0 {
                applyRegenDelta(k, spend)
                regenPending[k] -= spend
            }
            let left = d - d * f
            disturb[k] = left
            maxLeft = max(maxLeft, left)
        }
        if cfg.disturbanceMeanderDrop > 0 { dropDisturbedMeanderState() }
        if maxLeft < 0.01 {
            for k in 0..<cfg.count {
                if regenPending[k] != 0 { applyRegenDelta(k, regenPending[k]) }
                disturb[k] = 0
                regenPending[k] = 0
            }
            disturbActive = false
        }
    }

    @inline(__always) private func applyRegenDelta(_ k: Int, _ dhRaw: Double) {
        let dh = max(h[k] + dhRaw, cfg.floor) - h[k]
        if dh >= 0 {
            raiseRockCell(k, dh)
        } else {
            _ = erodeCell(k, -dh)
        }
    }

    private func dropDisturbedMeanderState() {
        let thr = cfg.disturbanceMeanderDrop
        func disturbed(_ nd: MeanderNode) -> Bool {
            let i = min(max(Int(nd.x.rounded()), 0), n - 1)
            let j = min(max(Int(nd.z.rounded()), 0), n - 1)
            return disturb[j * n + i] >= thr
        }
        let oldCount = meander.channels.count
        meander.channels.removeAll { $0.nodes.contains(where: disturbed) }
        if meander.channels.count != oldCount {
            beltCouplingCarry = max(beltCouplingCarry, cfg.meanderBeltCouplingYears)
        }
        var keptOxbows: [[MeanderNode]] = []
        var keptAges: [Double] = []
        for (oi, ox) in meander.oxbows.enumerated() where !ox.contains(where: disturbed) {
            keptOxbows.append(ox)
            keptAges.append(oi < meander.oxbowAge.count ? meander.oxbowAge[oi] : 0)
        }
        meander.oxbows = keptOxbows
        meander.oxbowAge = keptAges
    }

    private func seedMeander() {
        meander.channels = MeanderState.traceChannels(config: cfg, h: h, hf: hf,
                                                       area: area, receiver: receiver)
        meander.oxbows.removeAll()
        meander.oxbowAge.removeAll()
    }

    @inline(__always) static func bilinear(_ p: UnsafePointer<Double>, _ n: Int,
                                           _ gx: Double, _ gz: Double) -> Double {
        let xi = min(max(Int(gx), 0), n - 2), yi = min(max(Int(gz), 0), n - 2)
        let fx = min(max(gx - Double(xi), 0), 1), fy = min(max(gz - Double(yi), 0), 1)
        let k = yi * n + xi
        return p[k] * (1 - fx) * (1 - fy) + p[k + 1] * fx * (1 - fy)
             + p[k + n] * (1 - fx) * fy + p[k + n + 1] * fx * fy
    }

    @inline(__always) static func riparianVeg(_ pveg: UnsafePointer<Double>,
                                              _ pcls: UnsafePointer<UInt8>,
                                              _ n: Int, _ r: Int,
                                              _ gx: Double, _ gz: Double) -> Double {
        let ci = min(max(Int(gx.rounded()), 0), n - 1)
        let cj = min(max(Int(gz.rounded()), 0), n - 1)
        var s = 0.0
        var cnt = 0
        for dj in max(0, cj - r)...min(n - 1, cj + r) {
            let row = dj * n
            for di in max(0, ci - r)...min(n - 1, ci + r) {
                let k = row + di
                cnt += 1
                if pcls[k] == 3 { s += pveg[k] }
            }
        }
        return cnt == 0 ? 0 : s / Double(cnt)
    }

    private var bankRadius: Int { max(1, Int(cfg.meanderBankWidth.rounded())) }

    func riparianVegAt(_ gx: Double, _ gz: Double) -> Double {
        veg.withUnsafeBufferPointer { vb in
        vegClass.withUnsafeBufferPointer { cb in
            Terrain.riparianVeg(vb.baseAddress!, cb.baseAddress!, n, bankRadius, gx, gz)
        }}
    }

    @inline(__always) private func bilinearH(_ gx: Double, _ gz: Double) -> Double {
        h.withUnsafeBufferPointer { Terrain.bilinear($0.baseAddress!, n, gx, gz) }
    }

    private func migrateMeander(dt: Double) {
        if meander.channels.isEmpty { seedMeander(); return }
        let cellArea = cfg.cellSize * cfg.cellSize
        guard cellArea > 0, cellArea.isFinite else { return }
        let nn = n, bankR = bankRadius
        h.withUnsafeBufferPointer { hb in
        area.withUnsafeBufferPointer { ab in
        veg.withUnsafeBufferPointer { vb in
        vegClass.withUnsafeBufferPointer { cb in
            let ph = hb.baseAddress!, pa = ab.baseAddress!
            let pveg = vb.baseAddress!, pcls = cb.baseAddress!
            meander.channels.withUnsafeMutableBufferPointer { chs in
                for ci in chs.indices {
                    chs[ci].refreshDischarge { gx, gz in
                        max(0, Terrain.bilinear(pa, nn, gx, gz) / cellArea)
                    }
                }
            }
            meander.migrate(dt: dt, config: cfg,
                            heightAt: { Terrain.bilinear(ph, nn, $0.x, $0.z) },
                            riparianAt: {
                                Terrain.riparianVeg(pveg, pcls, nn, bankR, $0.x, $0.z)
                            })
        }}}}
        let maxc = Double(n - 1)
        meander.channels.withUnsafeMutableBufferPointer { chs in
            for ci in chs.indices { chs[ci].clampToWorld(maxCoord: maxc) }
        }
        meander.channels.removeAll { $0.nodes.count < 3 }
        if meander.channels.isEmpty { seedMeander() }
    }

    @inline(__always) private func stepCapFraction(_ dt: Double) -> Double {
        max(0.5, 1 - exp(-dt * 0.6931471805599453 / 500))
    }

    func stepCapFractionForTests(_ dt: Double) -> Double { stepCapFraction(dt) }

    func transportLimitedForTests(dt: Double) { transportLimited(dt: dt) }

    func deltaDepositForTests(yieldPerCell: Double) {
        _ = deltaHeightSum(collectMouths: true)
        deltaDeposit(yieldPerCell: yieldPerCell)
    }

    func setBedForTests(h nh: [Double], sed ns: [Double], rock nr: [Double], underIce nu: [Bool]) {
        precondition(nh.count == cfg.count && ns.count == cfg.count && nr.count == cfg.count,
                     "Bett-Felder passen nicht zur Config")
        precondition(nu.isEmpty || nu.count == cfg.count, "Eismaske weder leer noch vollständig")
        precondition(zip(nh, zip(nr, ns)).allSatisfy {
            $0.isNaN || abs($0 - ($1.0 + $1.1)) < 1e-12
        }, "h ≠ rock + sed im Testaufbau")
        h = nh; sed = ns; rock = nr; underIce = nu
    }

    @discardableResult
    func erodeCellViaPropertyForTests(_ k: Int, _ amount: Double) -> Double { erodeCell(k, amount) }

    @discardableResult
    func erodeCellViaBedForTests(_ k: Int, _ amount: Double) -> Double {
        withBed { erodeCell(k, amount, $0) }
    }

    @discardableResult
    func depositCellViaPropertyForTests(_ k: Int, _ amount: Double) -> Double { depositCell(k, amount) }

    @discardableResult
    func depositCellViaBedForTests(_ k: Int, _ amount: Double) -> Double {
        withBed { depositCell(k, amount, $0) }
    }

    @discardableResult
    func erodeCellToViaBedForTests(_ k: Int, _ target: Double) -> Double {
        withBed { erodeCellTo(k, target, $0) }
    }

    @discardableResult
    func raiseRockCellViaBedForTests(_ k: Int, _ amount: Double) -> Double {
        withBed { raiseRockCell(k, amount, $0) }
    }

    func setReceiverForTests(at index: Int, to value: Int32) {
        receiver[index] = value
    }

    struct Bed {
        let h: UnsafeMutablePointer<Double>
        let sed: UnsafeMutablePointer<Double>
        let rock: UnsafeMutablePointer<Double>
        let locked: UnsafePointer<Bool>?

        @discardableResult
        @inline(__always) func erode(_ k: Int, _ amount: Double) -> Double {
            let a = max(0, amount)
            if a <= 0 { return 0 }
            if let locked, locked[k] { return 0 }
            let ds = min(a, sed[k]); sed[k] -= ds
            rock[k] -= (a - ds)
            h[k] -= a
            return a
        }

        @discardableResult
        @inline(__always) func deposit(_ k: Int, _ amount: Double) -> Double {
            if amount <= 0 { return 0 }
            if let locked, locked[k] { return 0 }
            sed[k] += amount; h[k] += amount
            return amount
        }
    }

    @inline(__always) private func withBed<R>(_ body: (Bed) -> R) -> R {
        h.withUnsafeMutableBufferPointer { hb in
        sed.withUnsafeMutableBufferPointer { sb in
        rock.withUnsafeMutableBufferPointer { rb in
        underIce.withUnsafeBufferPointer { ib in
            body(Bed(h: hb.baseAddress!, sed: sb.baseAddress!, rock: rb.baseAddress!,
                     locked: ib.isEmpty ? nil : ib.baseAddress))
        }}}}
    }

    @inline(__always) private func erodeCell(_ k: Int, _ amount: Double, _ bed: Bed) -> Double {
        bed.erode(k, amount)
    }

    @discardableResult
    @inline(__always) private func depositCell(_ k: Int, _ amount: Double, _ bed: Bed) -> Double {
        bed.deposit(k, amount)
    }

    @discardableResult
    @inline(__always) private func erodeCellTo(_ k: Int, _ target: Double, _ bed: Bed) -> Double {
        let a = bed.h[k] - target
        guard a > 0 else { return 0 }
        let moved = bed.erode(k, a)
        if moved > 0 { bed.h[k] = target }
        return moved
    }

    @discardableResult
    @inline(__always) private func raiseRockCell(_ k: Int, _ amount: Double, _ bed: Bed) -> Double {
        if amount <= 0 { return 0 }
        if let locked = bed.locked, locked[k] { return 0 }
        bed.rock[k] += amount; bed.h[k] += amount
        return amount
    }

    @inline(__always) private func erodeCell(_ k: Int, _ amount: Double) -> Double {
        withBed { erodeCell(k, amount, $0) }
    }

    @discardableResult
    @inline(__always) private func depositCell(_ k: Int, _ amount: Double) -> Double {
        withBed { depositCell(k, amount, $0) }
    }

    @discardableResult
    @inline(__always) private func raiseRockCell(_ k: Int, _ amount: Double) -> Double {
        withBed { raiseRockCell(k, amount, $0) }
    }

    private func meanderStamp(dt: Double) {
        fill(&isChannel, false)
        let cs = cfg.cellSize
        guard cs > 0, cs.isFinite else { return }
        let m = cfg.mExp
        let cellArea = cs * cs
        let width = cfg.meanderBankWidth
        let capF = stepCapFraction(dt)
        let nn = n
        hf.withUnsafeBufferPointer { hfb in
        underIce.withUnsafeBufferPointer { uib in
        veg.withUnsafeMutableBufferPointer { vb in
        isChannel.withUnsafeMutableBufferPointer { icb in
        withBed { bed in
        let phf = hfb.baseAddress!, pveg = vb.baseAddress!, pchan = icb.baseAddress!
        let pice = uib.baseAddress
        let iceOn = uib.count == cfg.count
        for ch in meander.channels {
            let nodes = ch.nodes
            guard nodes.count >= 2 else { continue }
            for i in 0..<(nodes.count - 1) {
                let a = nodes[i], b = nodes[i + 1]
                let d = dist(a, b)
                let hb = Terrain.bilinear(bed.h, nn, b.x, b.z)
                let ha = Terrain.bilinear(bed.h, nn, a.x, a.z)
                let segSlope = d > 1e-6 ? max(0, ha - hb) / (d * cs) : 0
                let qA = 0.5 * (ch.discharge[i] + ch.discharge[i + 1]) * cellArea
                let carveRate = cfg.meanderCarve * pow(max(qA, 0), m) * segSlope * dt
                let steps = max(1, Int(d.rounded(.up)))
                for sIdx in 0...steps {
                    let t = Double(sIdx) / Double(steps)
                    let ci = min(max(Int((a.x + (b.x - a.x) * t).rounded()), 0), nn - 1)
                    let cj = min(max(Int((a.z + (b.z - a.z) * t).rounded()), 0), nn - 1)
                    let k = cj * nn + ci
                    if phf[k] - bed.h[k] > 0.02 { continue }
                    if iceOn && pice![k] { continue }
                    pchan[k] = true
                    pveg[k] = 0
                    let cap = max(0, bed.h[k] - hb) * capF
                    _ = erodeCell(k, min(carveRate, cap), bed)
                }
            }
            for i in 1..<(nodes.count - 1) {
                let a = nodes[i - 1], b = nodes[i], c = nodes[i + 1]
                let v1x = b.x - a.x, v1z = b.z - a.z
                let v2x = c.x - b.x, v2z = c.z - b.z
                let ds = 0.5 * ((v1x * v1x + v1z * v1z).squareRoot()
                              + (v2x * v2x + v2z * v2z).squareRoot())
                if ds < 1e-9 { continue }
                let cross = v1x * v2z - v1z * v2x
                let dot = v1x * v2x + v1z * v2z
                let curv = atan2(cross, dot) / ds
                let tx = c.x - a.x, tz = c.z - a.z
                let tl = (tx * tx + tz * tz).squareRoot()
                if tl < 1e-9 { continue }
                let sgn = curv > 0 ? -1.0 : 1.0
                let ox = sgn * (-tz / tl), oz = sgn * (tx / tl)
                let outI = min(max(Int((b.x + ox * width).rounded()), 0), nn - 1)
                let outJ = min(max(Int((b.z + oz * width).rounded()), 0), nn - 1)
                let inI = min(max(Int((b.x - ox * width).rounded()), 0), nn - 1)
                let inJ = min(max(Int((b.z - oz * width).rounded()), 0), nn - 1)
                let ko = outJ * nn + outI, ki = inJ * nn + inI
                if ko == ki { continue }
                let qA = ch.discharge[i] * cellArea
                let want = cfg.meanderBankErode * pow(max(qA, 0), m) * abs(curv) * dt
                let cap = max(0, bed.h[ko] - bed.h[ki]) * capF
                let moved = erodeCell(ko, min(want, cap), bed)
                depositCell(ki, moved, bed)
            }
        }
        }}}}}
        plugOxbows()
        fillOxbows(dt: dt)
    }

    private func fillOxbows(dt: Double, byAge: Bool = false) {
        let rate = Terrain.relaxFraction(dt: dt, tau: cfg.oxbowFillYears)
        let nn = n
        withBed { bed in
        let ph = bed.h
        for (oi, loop) in meander.oxbows.enumerated() {
            let rate = byAge && meander.oxbowAge[oi] < dt
                ? Terrain.relaxFraction(dt: meander.oxbowAge[oi], tau: cfg.oxbowFillYears) : rate
            for nd in loop {
                let ci = min(max(Int(nd.x.rounded()), 1), nn - 2)
                let cj = min(max(Int(nd.z.rounded()), 1), nn - 2)
                let k = cj * nn + ci
                var rim = ph[k]
                rim = max(rim, ph[k - 1]); rim = max(rim, ph[k + 1])
                rim = max(rim, ph[k - nn]); rim = max(rim, ph[k + nn])
                let add = (rim - ph[k]) * rate
                if add > 0 { depositCell(k, add, bed) }
            }
        }
        }
        meander.pruneOxbows(maxAge: cfg.oxbowMaxAge)
    }

    private func plugOxbows() {
        plugOxbows(indices: meander.oxbows.indices.filter { meander.oxbowAge[$0] == 0 })
    }

    private func plugOxbows(from: Int) {
        guard from < meander.oxbows.count else { return }
        plugOxbows(indices: Array(from..<meander.oxbows.count))
    }

    private func plugOxbows(indices: [Int]) {
        let nn = n
        withBed { bed in
        for oi in indices { plugOxbow(meander.oxbows[oi], bed: bed, nn: nn) }
        }
    }

    private func plugOxbow(_ loop: [MeanderNode], bed: Bed, nn: Int) {
        let ph = bed.h
        guard loop.count >= 4 else { return }
        for nd in [loop[1], loop[loop.count - 2]] {
            let ci = min(max(Int(nd.x.rounded()), 1), nn - 2)
            let cj = min(max(Int(nd.z.rounded()), 1), nn - 2)
            let k = cj * nn + ci
            var lip = ph[k]
            lip = max(lip, ph[k - 1]); lip = max(lip, ph[k + 1])
            lip = max(lip, ph[k - nn]); lip = max(lip, ph[k + nn])
            depositCell(k, max(0, lip - ph[k]), bed)
        }
    }

    private func refreshBeltDischarge(only: Int? = nil) {
        let nn = n, cellArea = cfg.cellSize * cfg.cellSize
        guard cellArea > 0, cellArea.isFinite else { return }
        area.withUnsafeBufferPointer { ab in
            let pa = ab.baseAddress!
            meander.channels.withUnsafeMutableBufferPointer { chs in
                for ci in chs.indices where only == nil || only == ci {
                    var run = 0.0
                    chs[ci].refreshDischarge { gx, gz in
                        let ci0 = min(max(Int(gx.rounded()), 0), nn - 1)
                        let cj0 = min(max(Int(gz.rounded()), 0), nn - 1)
                        var m = 0.0
                        for j in max(0, cj0 - 1)...min(nn - 1, cj0 + 1) {
                            for i in max(0, ci0 - 1)...min(nn - 1, ci0 + 1) { m = max(m, pa[j * nn + i]) }
                        }
                        run = max(run, m / cellArea)
                        return run
                    }
                }
            }
        }
    }

    private func meanderBeltStep(dt: Double) {
        if meander.channels.isEmpty { seedMeander() }
        fill(&isChannel, false)
        fill(&inBelt, false)
        if cfg.meanderBeltCoupling {
            if dropletGateBuf.count != cfg.count { dropletGateBuf = .init(repeating: false, count: cfg.count) }
            fill(&dropletGateBuf, false)
        }
        barAge.withUnsafeMutableBufferPointer { ab in
            let pa = ab.baseAddress!
            parallel(cfg.count) { lo, hi in
                for k in lo..<hi where pa[k] >= 0 { pa[k] += dt }
            }
        }
        for oi in meander.oxbowAge.indices { meander.oxbowAge[oi] += dt }
        let nn = n, maxc = Double(n - 1)
        let maxSub = 4096
        let coupled = cfg.meanderBeltCoupling
        let couplingDt = coupled ? beltCouplingStep(dt: dt) : 0
        if couplingDt > 0 {
            mark("belt.couple")
            let ox0 = meander.oxbows.count
            coupleBeltToDrainage(dt: couplingDt)
            plugOxbows(from: ox0)
        } else if !coupled {
            mark("belt.discharge")
            refreshBeltDischarge()
        }
        var maxSubUsed = 0
        let mobile = meander.channels.indices.filter { MeanderState.migrates(meander.channels[$0], cfg) }
        if coupled, let used = parallelBeltRuns(mobile, dt: dt) {
            maxSubUsed = used
        } else {
            for ci in mobile {
                mark("belt.migrate")
                let plan = h.withUnsafeBufferPointer { hb in
                    let ph = hb.baseAddress!
                    return meander.beltMigrationPlan(channel: ci, config: cfg,
                                                     heightAt: { Terrain.bilinear(ph, nn, $0.x, $0.z) })
                }
                let rate = plan.rate
                let nsub = max(1, min(maxSub, Int((rate * dt / (0.5 * cfg.meanderNodeSpacing)).rounded(.up))))
                maxSubUsed = max(maxSubUsed, nsub)
                let sub = dt / Double(nsub)
                var stampedGeometry: BeltGeometry?
                for si in 0..<nsub {
                    mark("belt.migrate")
                    let ageAtEnd = dt - Double(si + 1) * sub
                    let ox0 = meander.oxbows.count
                    h.withUnsafeBufferPointer { hb in
                        let ph = hb.baseAddress!
                        if si == 0 {
                            meander.applyBeltMigrationPlan(ci, plan: plan, dt: sub, time: years, config: cfg)
                        } else {
                            meander.migrateBeltChannel(ci, dt: sub, time: years + Double(si) * sub, config: cfg,
                                                       heightAt: { Terrain.bilinear(ph, nn, $0.x, $0.z) }, geometry: stampedGeometry)
                        }
                    }
                    for oi in ox0..<meander.oxbowAge.count { meander.oxbowAge[oi] = ageAtEnd }
                    meander.channels[ci].clampToWorld(maxCoord: maxc)
                    if !coupled {
                        mark("belt.discharge")
                        refreshBeltDischarge(only: ci)
                    }
                    mark("belt.stamp")
                    let stampDt = coupled && cfg.meanderBeltSymmetricStamp ? 0.5 * sub : sub
                    stampedGeometry = beltStamp(dt: stampDt, only: ci, ageAtEnd: ageAtEnd)
                    plugOxbows(from: ox0)
                }
            }
        }
        beltSubsteps = maxSubUsed
        mark("belt.attach")
        meander.attachTributaries(config: cfg)
        meander.channels.removeAll { $0.nodes.count < 3 }
        if !coupled { refreshBeltDischarge() }
        mark("belt.fixedStamp")
        beltStamp(dt: dt, only: nil, ageAtEnd: 0)
        mark("belt.fill")
        fillOxbows(dt: dt, byAge: true)
        if meander.channels.isEmpty { seedMeander() }
    }

    private final class BeltRun {
        let channel: Int
        let state = MeanderState()
        let footprint: MeanderState.BeltFootprint
        var substeps = 0

        init(channel: Int, line: RiverChannel, footprint: MeanderState.BeltFootprint) {
            self.channel = channel
            self.footprint = footprint
            state.channels = [line]
        }
    }

    final class BeltSchedule: @unchecked Sendable {
        private let condition = NSCondition()
        private var waiting: [Int]
        private let successors: [[Int]]
        private var ready: [Int]
        private var remaining: Int

        init(_ footprints: [MeanderState.BeltFootprint]) {
            var waiting = [Int](repeating: 0, count: footprints.count)
            var successors = [[Int]](repeating: [], count: footprints.count)
            for j in footprints.indices {
                for i in 0..<j where footprints[i].overlaps(footprints[j]) {
                    waiting[j] += 1
                    successors[i].append(j)
                }
            }
            self.waiting = waiting
            self.successors = successors
            self.ready = waiting.indices.filter { waiting[$0] == 0 }
            self.remaining = footprints.count
        }

        func take() -> Int? {
            condition.lock()
            defer { condition.unlock() }
            while ready.isEmpty && remaining > 0 { condition.wait() }
            return ready.popLast()
        }

        func finish(_ index: Int) {
            condition.lock()
            remaining -= 1
            for j in successors[index] {
                waiting[j] -= 1
                if waiting[j] == 0 { ready.append(j); condition.signal() }
            }
            if remaining == 0 { condition.broadcast() }
            condition.unlock()
        }
    }

    private func parallelBeltRuns(_ mobile: [Int], dt: Double) -> Int? {
        guard mobile.count > 1, cfg.cellSize > 0, cfg.cellSize.isFinite else { return nil }
        mark("belt.schedule")
        var runs: [BeltRun] = []
        for ci in mobile {
            guard let footprint = meander.beltFootprint(meander.channels[ci], dt: dt, config: cfg) else { return nil }
            runs.append(BeltRun(channel: ci, line: meander.channels[ci], footprint: footprint))
        }
        let schedule = BeltSchedule(runs.map(\.footprint))
        mark("belt.parallel")
        let nn = n, maxc = Double(n - 1), config = cfg, time = years
        hf.withUnsafeBufferPointer { hfb in
        veg.withUnsafeMutableBufferPointer { vb in
        isChannel.withUnsafeMutableBufferPointer { icb in
        inBelt.withUnsafeMutableBufferPointer { ibb in
        barAge.withUnsafeMutableBufferPointer { bab in
        dropletGateBuf.withUnsafeMutableBufferPointer { glb in
        withBed { bed in
            let buffers = BeltStampBuffers(bed: bed, hf: hfb.baseAddress!, veg: vb.baseAddress!,
                                           channel: icb.baseAddress!, belt: ibb.baseAddress!, age: bab.baseAddress!,
                                           lock: glb.count == config.count ? glb.baseAddress : nil)
            let heightAt: (MeanderNode) -> Double = { Terrain.bilinear(bed.h, nn, $0.x, $0.z) }
            let work: (Int) -> Void = { index in
                let run = runs[index], state = run.state
                let plan = state.beltMigrationPlan(channel: 0, config: config, heightAt: heightAt)
                let nsub = max(1, min(4096, Int((plan.rate * dt / (0.5 * config.meanderNodeSpacing)).rounded(.up))))
                precondition(nsub <= run.footprint.maxSubsteps)
                run.substeps = nsub
                let sub = dt / Double(nsub)
                var geometry: BeltGeometry?
                for si in 0..<nsub {
                    let ageAtEnd = dt - Double(si + 1) * sub
                    let ox0 = state.oxbows.count
                    if si == 0 {
                        state.applyBeltMigrationPlan(0, plan: plan, dt: sub, time: time, config: config,
                                                     noiseChannel: run.channel)
                    } else {
                        state.migrateBeltChannel(0, dt: sub, time: time + Double(si) * sub, config: config,
                                                  heightAt: heightAt, geometry: geometry, noiseChannel: run.channel)
                    }
                    for oi in ox0..<state.oxbowAge.count { state.oxbowAge[oi] = ageAtEnd }
                    state.channels[0].clampToWorld(maxCoord: maxc)
                    let stampDt = config.meanderBeltSymmetricStamp ? 0.5 * sub : sub
                    geometry = self.beltStampChannel(state.channels[0], dt: stampDt, part: 1, ageAtEnd: ageAtEnd,
                                                     lockHere: true, buffers: buffers)
                    for oi in ox0..<state.oxbows.count { self.plugOxbow(state.oxbows[oi], bed: bed, nn: nn) }
                }
            }
            nonisolated(unsafe) let unsafeWork = work
            DispatchQueue.concurrentPerform(iterations: min(Terrain.coreCount, runs.count)) { _ in
                while let index = schedule.take() {
                    unsafeWork(index)
                    schedule.finish(index)
                }
            }
        }}}}}}}
        for run in runs {
            meander.channels[run.channel] = run.state.channels[0]
            meander.appendBeltHistory(run.state)
        }
        return runs.map(\.substeps).max() ?? 0
    }

    private func beltDropletGate() -> [Bool] {
        guard cfg.meanderEnabled && cfg.meanderBelt else { return underIce }
        let c = cfg.count
        if dropletGateBuf.count != c { dropletGateBuf = .init(repeating: false, count: c) }
        let iceOn = underIce.count == c
        let mobileOnly = cfg.meanderBeltCoupling
        dropletGateBuf.withUnsafeMutableBufferPointer { gb in
        inBelt.withUnsafeBufferPointer { bb in
        underIce.withUnsafeBufferPointer { ib in
            let pg = gb.baseAddress!, pb = bb.baseAddress!, pi = ib.baseAddress
            parallel(c) { lo, hi in
                if mobileOnly {
                    for k in lo..<hi { pg[k] = pg[k] || (iceOn && pi![k]) }
                } else {
                    for k in lo..<hi { pg[k] = pb[k] || (iceOn && pi![k]) }
                }
            }
        }}}
        return dropletGateBuf
    }
    private var dropletGateBuf: [Bool] = []

    public private(set) var beltSubsteps = 1

    @discardableResult
    private func beltStamp(dt: Double, only: Int?, ageAtEnd: Double) -> BeltGeometry? {
        let cs = cfg.cellSize
        guard cs > 0, cs.isFinite else { return nil }
        return hf.withUnsafeBufferPointer { hfb in
        veg.withUnsafeMutableBufferPointer { vb in
        isChannel.withUnsafeMutableBufferPointer { icb in
        inBelt.withUnsafeMutableBufferPointer { ibb in
        barAge.withUnsafeMutableBufferPointer { bab in
        dropletGateBuf.withUnsafeMutableBufferPointer { glb in
        withBed { bed in
        let buffers = BeltStampBuffers(bed: bed, hf: hfb.baseAddress!, veg: vb.baseAddress!,
                                       channel: icb.baseAddress!, belt: ibb.baseAddress!, age: bab.baseAddress!,
                                       lock: glb.count == cfg.count ? glb.baseAddress : nil)
        var geometry: BeltGeometry?
        let split = cfg.meanderBeltCoupling
        let channelRange = only.map { $0..<($0 + 1) } ?? meander.channels.indices
        for ci in channelRange {
            let ch = meander.channels[ci]
            guard only != nil || split || !MeanderState.migrates(ch, cfg) else { continue }
            let part = !split ? 0 : (only != nil ? 1 : (MeanderState.migrates(ch, cfg) ? 2 : 0))
            geometry = beltStampChannel(ch, dt: dt, part: part, ageAtEnd: ageAtEnd,
                                        lockHere: split && only != nil, buffers: buffers)
        }
        return geometry
        }}}}}}}
    }

    private struct BeltStampBuffers {
        let bed: Bed
        let hf: UnsafePointer<Double>
        let veg: UnsafeMutablePointer<Double>
        let channel: UnsafeMutablePointer<Bool>
        let belt: UnsafeMutablePointer<Bool>
        let age: UnsafeMutablePointer<Double>
        let lock: UnsafeMutablePointer<Bool>?
    }

    private func beltStampChannel(_ ch: RiverChannel, dt: Double, part: Int, ageAtEnd: Double,
                                  lockHere: Bool, buffers: BeltStampBuffers) -> BeltGeometry? {
        let cs = cfg.cellSize, nn = n
        let rel = Terrain.relaxFraction(dt: dt, tau: max(1e-6, cfg.meanderBeltRelaxYears))
        let capF = stepCapFraction(dt)
        let m = cfg.mExp, cellArea = cs * cs
        let skew = cfg.meanderBeltPoolSkew, gain = cfg.meanderBeltPoolGain
        let barTop = cfg.meanderBarTopDepth, barW = cfg.meanderBarWidths
        let depthK = cfg.meanderBeltDepthPerWidth * cs
        let bed = buffers.bed, phf = buffers.hf, pveg = buffers.veg
        let pchan = buffers.channel, pbelt = buffers.belt, page = buffers.age, plock = buffers.lock
        let pice = bed.locked, iceOn = bed.locked != nil
        let split = cfg.meanderBeltCoupling
        @inline(__always) func cell(_ x: Double, _ z: Double) -> Int {
            Terrain.cellIndex(x, z, n: nn)
        }
        @inline(__always) func blocked(_ k: Int) -> Bool {
            phf[k] - bed.h[k] > 0.02 || (iceOn && pice![k])
        }
            let nodes = ch.nodes, c = nodes.count
            guard c >= 3 else { return nil }
            let g = MeanderState.beltGeometry(ch, config: cfg,
                                              heightAt: { Terrain.bilinear(bed.h, nn, $0.x, $0.z) })
            let firstMob = g.mob.firstIndex(where: { $0 > 0 })
            let lastMob = g.mob.lastIndex(where: { $0 > 0 })
            if part == 1 && firstMob == nil { return g }
            let needsLateral = part != 2 && firstMob != nil
            let bendCurv = needsLateral
                ? MeanderState.bendCurvature(g, config: cfg, activeRange: firstMob!...lastMob!)
                : []
            var floorH = needsLateral ? [Double](repeating: 0, count: c) : []
            var hasFloor = needsLateral ? [Bool](repeating: false, count: c) : []
            let sillCut = cfg.meanderBeltSillCutDepths
            let fLo = part == 1 ? max(0, firstMob! - 2) : 0
            let fHi = part == 1 ? min(c - 1, lastMob! + 2) : (c - 1)
            if needsLateral && fLo <= fHi {
                for i in fLo...fHi {
                    if part == 1 || split {
                        var flat = false
                        for j in max(0, i - 2)...min(c - 1, i + 2) where g.mob[j] > 0 { flat = true; break }
                        if !flat { continue }
                    }
                    let w = 0.5 * g.width[i]
                    var lo = Double.infinity, s = -w
                    while s <= w + 1e-9 {
                        lo = min(lo, bed.h[cell(nodes[i].x + g.nx[i] * s, nodes[i].z + g.nz[i] * s)])
                        s += 0.5
                    }
                    floorH[i] = lo
                    hasFloor[i] = true
                }
                if sillCut > 0 {
                    var runMin = Double.infinity
                    for i in 0..<c {
                        let depth = depthK * g.width[i]
                        if i >= fLo && i <= fHi && hasFloor[i] {
                            let excess = floorH[i] - runMin
                            if excess > 0 && excess <= sillCut * depth {
                                floorH[i] = runMin - 0.25 * depth
                            }
                        }
                        runMin = min(runMin, phf[cell(nodes[i].x, nodes[i].z)])
                    }
                }
            }
            var budget = 0.0
            let sLo = part == 1 ? max(1, firstMob!) : 1
            let sHi = part == 1 ? min(c - 2, lastMob!) : (c - 2)
            if sLo <= sHi {
                for i in sLo...sHi {
                let ck = cell(nodes[i].x, nodes[i].z)
                if blocked(ck) { budget = 0; continue }
                let b = g.width[i], w = 0.5 * b
                if g.mob[i] <= 0 {
                    if part == 1 { budget = 0; continue }
                    let a = nodes[i], bn = nodes[i + 1]
                    let d = dist(a, bn)
                    let hbn = Terrain.bilinear(bed.h, nn, bn.x, bn.z)
                    let ha = Terrain.bilinear(bed.h, nn, a.x, a.z)
                    let segSlope = d > 1e-6 ? max(0, ha - hbn) / (d * cs) : 0
                    let qA = 0.5 * (ch.discharge[i] + ch.discharge[i + 1]) * cellArea
                    let carveRate = cfg.meanderCarve * pow(max(qA, 0), m) * segSlope * dt
                    let steps = max(1, Int(d.rounded(.up)))
                    for sIdx in 0...steps {
                        let t = Double(sIdx) / Double(steps)
                        let k = cell(a.x + (bn.x - a.x) * t, a.z + (bn.z - a.z) * t)
                        if blocked(k) { continue }
                        pchan[k] = true; pveg[k] = 0
                        _ = erodeCell(k, min(carveRate, max(0, bed.h[k] - hbn) * capF), bed)
                    }
                    budget = 0
                    continue
                }
                if part == 2 { budget = 0; continue }
                var ref = 0.0
                let lo = max(0, i - 2), hi = min(c - 1, i + 2)
                for j in lo...hi { ref += floorH[j] }
                ref /= Double(hi - lo + 1)
                let depth = depthK * b
                let a = min(1, abs(bendCurv[i]) * b * gain)
                let kap = skew * a
                let eMax = kap > 1e-9 ? (-2 + (4 + 12 * kap * kap).squareRoot()) / (6 * kap) : 0
                let zbf = ref + depth * (1 - eMax * eMax) * (1 + kap * eMax)
                let sgn = bendCurv[i] > 0 ? -1.0 : 1.0
                let ox = sgn * g.nx[i], oz = sgn * g.nz[i]
                let barTarget = zbf - barTop * depth
                var s = w + 0.5, last = -1
                let inner = -(w + barW * b)
                while s >= inner - 1e-9 {
                    let k = cell(nodes[i].x + ox * s, nodes[i].z + oz * s)
                    s -= 0.5
                    let eta = (s + 0.5) / max(1e-6, w)
                    if eta < -1 && budget <= 0 { break }
                    if k == last || blocked(k) { continue }
                    last = k
                    if eta >= -1 {
                        let e = max(-1, min(1, eta))
                        let target = min(barTarget, zbf - depth * (1 - e * e) * (1 + kap * e))
                        pchan[k] = true; pbelt[k] = true; pveg[k] = 0
                        if lockHere { plock![k] = true }
                        if eta > -0.5 { page[k] = -1 }
                        if bed.h[k] > target {
                            budget += erodeCell(k, (bed.h[k] - target) * rel, bed)
                        } else if budget > 0 {
                            let dep = min(budget, (target - bed.h[k]) * rel)
                            depositCell(k, dep, bed); budget -= dep
                        }
                    } else if bed.h[k] < barTarget && budget > 0 {
                        let gap = barTarget - bed.h[k]
                        let dep = min(budget, gap * rel)
                        depositCell(k, dep, bed); budget -= dep
                        let atBar = barTarget - bed.h[k] <= 0.25 * depth
                        if atBar && (page[k] < 0 || gap > 0.2 * depth) { page[k] = ageAtEnd; pveg[k] = 0 }
                        if page[k] >= 0 { pbelt[k] = true; if lockHere { plock![k] = true } }
                    }
                }
            }
            }
        return g
    }

    struct DrainageSegment {
        var cells: [Int32]
        var endsAtConfluence: Bool
    }

    static func drainageSegments(config cfg: SimConfig, h: UnsafePointer<Double>, hf: UnsafePointer<Double>,
                                 area: UnsafePointer<Double>, receiver: UnsafePointer<Int32>) -> [DrainageSegment] {
        let nn = cfg.n, cnt = cfg.count, sea = cfg.sea
        let lakeEps = MeanderState.traceLakeDepth
        let minA = cfg.meanderMinCells * cfg.cellSize * cfg.cellSize
        nonisolated(unsafe) let ph = h, phf = hf, pa = area, prb = receiver
        @inline(__always) @Sendable func big(_ k: Int) -> Bool { phf[k] > sea && pa[k] >= minA }
        @inline(__always) @Sendable func bestDonor(_ r: Int) -> Int {
            let ri = r % nn, rj = r / nn
            var best = -1
            for dj in -1...1 {
                let j = rj + dj
                guard j >= 0, j < nn else { continue }
                for di in -1...1 where di != 0 || dj != 0 {
                    let i = ri + di
                    guard i >= 0, i < nn else { continue }
                    let d = j * nn + i
                    guard Int(prb[d]) == r, big(d) else { continue }
                    if best < 0 || pa[d] > pa[best] || (pa[d] == pa[best] && d < best) { best = d }
                }
            }
            return best
        }
        let chunks = max(1, min(Terrain.coreCount, cnt / 4096))
        var found = [[DrainageSegment]](repeating: [], count: chunks)
        found.withUnsafeMutableBufferPointer { fb in
            nonisolated(unsafe) let pf = fb.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunks) { ch in
                var segs: [DrainageSegment] = []
                var cells: [Int32] = []
                cells.reserveCapacity(64)
                for s in (cnt * ch / chunks)..<(cnt * (ch + 1) / chunks) where big(s) && bestDonor(s) < 0 {
                    cells.removeAll(keepingCapacity: true)
                    cells.append(Int32(s))
                    var c = s, confluence = false
                    while cells.count < cnt {
                        let r = Int(prb[c])
                        if r < 0 || r >= cnt || r == c { break }
                        if phf[r] <= sea || phf[r] - ph[r] > lakeEps { break }
                        cells.append(Int32(r))
                        if bestDonor(r) != c { confluence = true; break }
                        c = r
                    }
                    if cells.count >= 3 {
                        segs.append(DrainageSegment(cells: cells, endsAtConfluence: confluence))
                    }
                }
                pf[ch] = segs
            }
        }
        var totalSegs = 0
        for ch in 0..<chunks { totalSegs += found[ch].count }
        var out: [DrainageSegment] = []
        out.reserveCapacity(totalSegs)
        for ch in 0..<chunks { out.append(contentsOf: found[ch]) }
        return out
    }

    private func coupleBeltToDrainage(dt: Double) {
        let nn = n, cnt = cfg.count, cs = cfg.cellSize
        let cellArea = cs * cs
        guard cellArea > 0, cellArea.isFinite else { return }
        mark("belt.couple.segments")
        let segs = h.withUnsafeBufferPointer { hb in
            hf.withUnsafeBufferPointer { hfb in
            area.withUnsafeBufferPointer { ab in
            receiver.withUnsafeBufferPointer { rb in
                Terrain.drainageSegments(config: cfg, h: hb.baseAddress!, hf: hfb.baseAddress!,
                                         area: ab.baseAddress!, receiver: rb.baseAddress!)
            }}}
        }
        if segOwner.count != cnt {
            segOwner = [Int32](repeating: -1, count: cnt); segPos = [Int32](repeating: -1, count: cnt)
        }
        segOwner.withUnsafeMutableBufferPointer { ob in
            segPos.withUnsafeMutableBufferPointer { pb in
                let po = ob.baseAddress!, pp = pb.baseAddress!
                for (s, seg) in segs.enumerated() {
                    let s32 = Int32(s)
                    let own = seg.endsAtConfluence ? seg.cells.count - 1 : seg.cells.count
                    seg.cells.withUnsafeBufferPointer { cb in
                        let pc = cb.baseAddress!
                        for p in 0..<own {
                            let idx = Int(pc[p])
                            po[idx] = s32; pp[idx] = Int32(p)
                        }
                    }
                }
            }
        }
        defer {
            segOwner.withUnsafeMutableBufferPointer { ob in
                segPos.withUnsafeMutableBufferPointer { pb in
                    let po = ob.baseAddress!, pp = pb.baseAddress!
                    for seg in segs {
                        seg.cells.withUnsafeBufferPointer { cb in
                            for p in 0..<cb.count {
                                let idx = Int(cb[p])
                                po[idx] = -1; pp[idx] = -1
                            }
                        }
                    }
                }
            }
        }
        let old = meander.channels
        let slack = cfg.meanderBeltCouplingSlackCells
        let kW = cfg.meanderBeltAvulsionWidths, xD = cfg.meanderBeltAvulsionDepths
        let tAv = cfg.meanderBeltAvulsionYears
        let depthK = cfg.meanderBeltDepthPerWidth * cs
        let sea = cfg.sea, lakeEps = MeanderState.traceLakeDepth

        mark("belt.couple.match")
        var off = [Int](repeating: 0, count: old.count + 1)
        for l in old.indices { off[l + 1] = off[l] + old[l].nodes.count }
        var flatSeg = [Int32](repeating: -1, count: off[old.count]), flatPos = flatSeg
        let cfgL = cfg
        segOwner.withUnsafeBufferPointer { ob in
        segPos.withUnsafeBufferPointer { pb in
        hf.withUnsafeBufferPointer { hfb in
        h.withUnsafeBufferPointer { hb in
        flatSeg.withUnsafeMutableBufferPointer { fsb in
        flatPos.withUnsafeMutableBufferPointer { fpb in
            nonisolated(unsafe) let po = ob.baseAddress!, pp = pb.baseAddress!
            nonisolated(unsafe) let phf = hfb.baseAddress!, ph = hb.baseAddress!
            nonisolated(unsafe) let fs = fsb.baseAddress, fp = fpb.baseAddress
            let offsets = off
            let lineChunks = max(1, min(old.count, Terrain.coreCount * 4))
            DispatchQueue.concurrentPerform(iterations: lineChunks) { cc in
            for l in (old.count * cc / lineChunks)..<(old.count * (cc + 1) / lineChunks) {
                let ch = old[l], base = offsets[l]
                var prev: Int32 = -1
                for (i, p) in ch.nodes.enumerated() {
                    let ci0 = min(max(Int(p.x.rounded()), 0), nn - 1), cj0 = min(max(Int(p.z.rounded()), 0), nn - 1)
                    let k0 = cj0 * nn + ci0
                    if phf[k0] <= sea || phf[k0] - ph[k0] > lakeEps { prev = -1; continue }
                    let tol = 0.5 * MeanderState.beltWidthCells(discharge: ch.discharge[i], config: cfgL) + slack
                    let rMax = Int(tol.rounded(.up)) + 1
                    var bS: Int32 = -1, bP: Int32 = -1, bD2 = tol * tol + 1e-9
                    var vS: Int32 = -1, vP: Int32 = -1, vD2 = tol * tol + 1e-9
                    let prevEnd = prev >= 0 && segs[Int(prev)].endsAtConfluence ? Int(segs[Int(prev)].cells.last!) : -1
                    for r in 0...rMax {
                        if bS >= 0, Double(r) - 0.75 > bD2.squareRoot() + 1.0 { break }
                        for dj in -r...r {
                            let j = cj0 + dj
                            guard j >= 0, j < nn else { continue }
                            let edge = abs(dj) == r
                            var di = -r
                            while di <= r {
                                let i2 = ci0 + di
                                if i2 >= 0, i2 < nn {
                                    let k = j * nn + i2
                                    let ow = po[k]
                                    if ow >= 0 || k == prevEnd {
                                        let dx = Double(i2) - p.x, dz = Double(j) - p.z
                                        let d2 = dx * dx + dz * dz
                                        if ow >= 0, d2 < bD2 { bS = ow; bP = pp[k]; bD2 = d2 }
                                        if prev >= 0, ow == prev || k == prevEnd, d2 < vD2 {
                                            vS = prev
                                            vP = k == prevEnd ? Int32(segs[Int(prev)].cells.count - 1) : pp[k]
                                            vD2 = d2
                                        }
                                    }
                                }
                                if r == 0 { break }
                                di += edge ? 1 : 2 * r
                            }
                        }
                    }
                    if vS >= 0, vD2.squareRoot() <= bD2.squareRoot() + 1.0 { bS = vS; bP = vP }
                    fs![base + i] = bS; fp![base + i] = bP
                    prev = bS
                }
            }
            }
        }}}}}}
        let mSeg = old.indices.map { Array(flatSeg[off[$0]..<off[$0 + 1]]) }
        let mPos = old.indices.map { Array(flatPos[off[$0]..<off[$0 + 1]]) }

        mark("belt.couple.runs")
        struct Run { var line: Int; var i0: Int; var i1: Int; var pa: Int; var pb: Int }
        struct Gap { var line: Int; var i0: Int; var i1: Int; var runA: Int; var runB: Int; var width: Double }
        var runs: [Run] = [], gaps: [Gap] = []
        var segRuns = [[Int]](repeating: [], count: segs.count)
        for (l, ch) in old.enumerated() {
            let sg = mSeg[l], ps = mPos[l], c = ch.nodes.count
            var anchors: [Run] = []
            var i = 0
            while i < c {
                guard sg[i] >= 0 else { i += 1; continue }
                var a = Run(line: l, i0: i, i1: i, pa: Int(ps[i]), pb: Int(ps[i]))
                var j = i + 1
                while j < c, sg[j] == sg[i], Int(ps[j]) >= a.pb - 3 { a.i1 = j; a.pb = max(a.pb, Int(ps[j])); j += 1 }
                anchors.append(a)
                i = j
            }
            var cum = [Double](repeating: 0, count: c)
            for q in 1..<max(1, c) { cum[q] = cum[q - 1] + dist(ch.nodes[q - 1], ch.nodes[q]) }
            var k = 0
            var gapAtAnchor: [Int: Int] = [:]
            while k < anchors.count {
                var cur = anchors[k]
                let s = Int(sg[cur.i0])
                var next = k + 1
                var pendingGap: (Int, Int, Double, Int)? = nil
                while true {
                    var b = next
                    while b < anchors.count, Int(sg[anchors[b].i0]) != s { b += 1 }
                    guard b < anchors.count, anchors[b].pa >= cur.pb - 3 else { break }
                    let nb = anchors[b]
                    let bw = MeanderState.beltWidthCells(discharge: ch.discharge[cur.i1], config: cfg)
                    var avulse = cum[nb.i0] - cum[cur.i1] >= kW * bw
                    if !avulse, xD.isFinite, nb.i0 - cur.i1 >= 2, nb.pa > cur.pb {
                        var hl = 0.0, hp = 0.0
                        h.withUnsafeBufferPointer { hb in
                            for q in (cur.i1 + 1)..<nb.i0 { hl += Terrain.bilinear(hb.baseAddress!, nn, ch.nodes[q].x, ch.nodes[q].z) }
                        }
                        hl /= Double(nb.i0 - cur.i1 - 1)
                        for p in cur.pb...nb.pa { hp += h[Int(segs[s].cells[p])] }
                        hp /= Double(nb.pa - cur.pb + 1)
                        avulse = hl - hp > xD * depthK * bw
                    }
                    if avulse, tAv > 0 {
                        let key = years.bitPattern &* 0x9E37_79B9_7F4A_7C15
                            ^ UInt64(truncatingIfNeeded: segs[s].cells[0]) &* 0xD1B5_4A32_D192_ED03
                        let u = 0.5 * (MeanderState.hashUnit(key, cur.pb) + 1)
                        avulse = u < Terrain.relaxFraction(dt: dt, tau: tAv)
                    }
                    if avulse { pendingGap = (cur.i1, nb.i0, bw, b); break }
                    cur.i1 = nb.i1; cur.pb = max(cur.pb, nb.pb)
                    next = b + 1
                }
                runs.append(cur)
                let rid = runs.count - 1
                segRuns[s].append(rid)
                if let g = gapAtAnchor[k] { gaps[g].runB = rid }
                if let g = pendingGap {
                    gaps.append(Gap(line: l, i0: g.0, i1: g.1, runA: rid, runB: -1, width: g.2))
                    gapAtAnchor[g.3] = gaps.count - 1
                }
                k = next
            }
        }

        mark("belt.couple.build")
        var selected = [Bool](repeating: false, count: runs.count)
        var newChannels: [RiverChannel] = []
        newChannels.reserveCapacity(segs.count)
        for (s, seg) in segs.enumerated() {
            let cand = segRuns[s].sorted {
                let a = runs[$0], b = runs[$1]
                let la = a.i1 - a.i0, lb = b.i1 - b.i0
                return la != lb ? la > lb : (a.line != b.line ? a.line < b.line : a.i0 < b.i0)
            }
            var acc: [Int] = []
            for r in cand where !acc.contains(where: { runs[$0].pa <= runs[r].pb && runs[r].pa <= runs[$0].pb }) {
                acc.append(r)
            }
            acc.sort { runs[$0].pa < runs[$1].pa }
            for r in acc { selected[r] = true }
            let L = seg.cells.count
            var nodes: [MeanderNode] = [], pos: [Int] = [], inserted: [Bool] = []
            var place: [Int] = [], born: [Double] = []
            func addCells(_ from: Int, _ to: Int, _ where_: Int) {
                guard from < to else { return }
                for p in from..<to {
                    let k = Int(seg.cells[p])
                    nodes.append(MeanderNode(x: Double(k % nn), z: Double(k / nn))); pos.append(p); inserted.append(true)
                    place.append(where_); born.append(years)
                }
            }
            var prevPb = -1, prevLine = -1
            for r in acc {
                let run = runs[r]
                addCells(prevPb + 1, run.pa, prevLine < 0 ? 0 : (prevLine == run.line ? 1 : 2))
                prevLine = run.line
                let ch = old[run.line]
                for i in run.i0...run.i1 {
                    nodes.append(ch.nodes[i])
                    pos.append(mSeg[run.line][i] == Int32(s) ? Int(mPos[run.line][i]) : -1)
                    let b = ch.bornAt(i)
                    inserted.append(false); place.append(-1)
                    born.append(b >= years - WaterRender.ribbonGrowYears ? b : -.infinity)
                }
                prevPb = max(prevPb, run.pb)
            }
            addCells(prevPb + 1, L, prevLine < 0 ? 0 : 3)
            guard nodes.count >= 3 else { continue }
            for _ in 0..<3 {
                var prevNode = nodes[0]
                for i in 1..<(nodes.count - 1) {
                    let cur = nodes[i]
                    if inserted[i] {
                        nodes[i].x = cur.x + 0.5 * (0.5 * (prevNode.x + nodes[i + 1].x) - cur.x)
                        nodes[i].z = cur.z + 0.5 * (0.5 * (prevNode.z + nodes[i + 1].z) - cur.z)
                    }
                    prevNode = cur
                }
            }
            var dis = [Double](repeating: 0, count: nodes.count)
            area.withUnsafeBufferPointer { ab in
                let pa = ab.baseAddress!
                var run = 0.0
                for i in nodes.indices {
                    if pos[i] >= 0 {
                        let p = seg.endsAtConfluence && pos[i] == L - 1 ? L - 2 : pos[i]
                        run = max(run, pa[Int(seg.cells[p])] / cellArea)
                    }
                    dis[i] = run
                }
            }
            for i in nodes.indices where dis[i] >= cfg.meanderBeltMinCells {
                if inserted[i] {
                    meander.coupledInserted += 1
                    if !acc.isEmpty { meander.insertedByPlace[place[i]] += 1 }
                } else { meander.coupledKept += 1 }
            }
            if let log = beltCouplingLog, (dis.last ?? 0) >= cfg.meanderBeltMinCells {
                var line = "SEG \(s) L=\(L) conf=\(seg.endsAtConfluence) Q=\(Int(dis.last ?? 0)) Kandidaten \(cand.count) gewählt:"
                for r in acc { let q = runs[r]; line += " [Lauf \(q.line) Knoten \(q.i0)…\(q.i1)/\(old[q.line].nodes.count) pos \(q.pa)…\(q.pb)]" }
                for r in cand where !acc.contains(r) { let q = runs[r]; line += " verworfen[Lauf \(q.line) \(q.i0)…\(q.i1) pos \(q.pa)…\(q.pb)]" }
                line += " eingesetzt \(inserted.filter { $0 }.count) von \(nodes.count)"
                log(line)
            }
            if acc.count == 1, runs[acc[0]].i0 == 0, runs[acc[0]].i1 == old[runs[acc[0]].line].nodes.count - 1,
               !inserted.contains(true) {
                newChannels.append(RiverChannel(nodes: nodes, discharge: dis, born: born))
            } else {
                newChannels.append(meander.resampled(RiverChannel(nodes: nodes, discharge: dis, born: born), config: cfg))
            }
        }
        for g in gaps where g.runB >= 0 && selected[g.runA] && selected[g.runB] {
            let ch = old[g.line]
            guard ch.discharge[g.i0] >= cfg.meanderBeltMinCells else { continue }
            meander.avulsions += 1
            abandonChannel(Array(ch.nodes[g.i0...g.i1]), width: g.width, age: dt)
        }
        meander.retraced += segs.indices.filter { segRuns[$0].isEmpty }.count
        meander.channels = newChannels
    }
    private var segOwner: [Int32] = []
    func beltCouplingStep(dt: Double) -> Double {
        let interval = cfg.meanderBeltCouplingYears
        guard interval > 0, interval.isFinite else { return dt }
        let elapsed = floor(beltCouplingCarry / interval) * interval
        let exposure = elapsed > 0 ? max(dt, elapsed) : 0
        beltCouplingCarry = beltCouplingCarry - exposure + dt
        return exposure
    }
    private var segPos: [Int32] = []
    var beltCouplingLog: ((String) -> Void)?

    func beltBedLockedForTests(_ k: Int) -> Bool { dropletGateBuf.count > k && dropletGateBuf[k] }

    func coupleBeltForTests(dt: Double) {
        let ox0 = meander.oxbows.count
        coupleBeltToDrainage(dt: dt)
        plugOxbows(from: ox0)
    }

    private func abandonChannel(_ nodes: [MeanderNode], width b: Double, age: Double) {
        guard nodes.count >= 4 else { return }
        var len = 0.0
        for i in 1..<nodes.count { len += dist(nodes[i - 1], nodes[i]) }
        if len >= cfg.meanderBeltAbandonMinWidths * b && len <= cfg.meanderBeltMaxLoopWidths * b {
            meander.abandon(nodes, age: age)
        }
        let nn = n, r = 0.5 * b, ri = Int(r.rounded(.up))
        for p in nodes {
            let ci0 = Int(p.x.rounded()), cj0 = Int(p.z.rounded())
            for j in max(0, cj0 - ri)...min(nn - 1, cj0 + ri) {
                for i in max(0, ci0 - ri)...min(nn - 1, ci0 + ri) {
                    let dx = Double(i) - p.x, dz = Double(j) - p.z
                    guard dx * dx + dz * dz <= r * r else { continue }
                    let k = j * nn + i
                    if barAge[k] < 0 { barAge[k] = age }
                }
            }
        }
    }

    func dropletCount(dtYears dt: Double) -> Int {
        let density = Double(n * n) / (640.0 * 640.0)
        dropCarry += dt * cfg.hydraulicPerYear * density
        let drops = Int(dropCarry)
        dropCarry -= Double(drops)
        return drops
    }

    private func buildDepositDamp() {
        let damp = cfg.flowDepositDamp
        guard damp < 1 else {
            if !depositDampBuf.isEmpty { depositDampBuf = [] }
            return
        }
        if depositDampBuf.count != cfg.count {
            depositDampBuf = .init(repeating: 1, count: cfg.count)
        }
        let cellArea = cfg.cellSize * cfg.cellSize
        let lo = cfg.channelFlowMinCells * cellArea
        let hi = max(lo + 1e-12, cfg.channelFlowFullCells * cellArea)
        let cnt = cfg.count
        area.withUnsafeBufferPointer { ab in
        depositDampBuf.withUnsafeMutableBufferPointer { db in
            let pa = ab.baseAddress!, pd = db.baseAddress!
            parallel(cnt) { klo, khi in
                for k in klo..<khi {
                    if pa[k] <= lo { pd[k] = 1; continue }
                    let x = min(1, (pa[k] - lo) / (hi - lo))
                    pd[k] = 1 - (1 - damp) * (x * x * (3 - 2 * x))
                }
            }
        }}
    }

    public func step(dtYears dt: Double) {
        guard dt > 0, dt.isFinite else { return }

        mark("applyUplift")
        applyUplift(dt: dt, gatedAmount: upliftAmount(dt: dt,
                                                      floorPer100y: reliefServoRate()))
        mark("regenerateDisturbed")
        regenerateDisturbed(dt: dt)
        mark("updateLithology")
        updateLithology()
        flowStepCount &+= 1
        let mfdInterval = max(1, cfg.mfdUpdateInterval)
        let updateMFD = cfg.braidingEnabled || Int(flowStepCount % UInt32(mfdInterval)) == 0
        computeFlow(includeMFD: updateMFD, dtYears: dt)
        mark("relaxWaterLevel")
        relaxWaterLevel(dt: dt)
        mark("updateSaltCrust")
        updateSaltCrust(dt: dt)
        mark("updateIce")
        updateIce(dt: dt)
        if cfg.meanderEnabled && cfg.meanderBelt {
            mark("meanderBelt")
            meanderBeltStep(dt: dt)
        } else if cfg.meanderEnabled {
            mark("migrateMeander")
            migrateMeander(dt: dt)
            mark("meanderStamp")
            meanderStamp(dt: dt)
        }
        let passes = max(1, Int((dt / 100).rounded()))
        if cfg.hydraulicEnabled {
            let deltaOn = cfg.deltaTrapFraction > 0
            var deltaBefore = (sum: 0.0, land: 0)
            if deltaOn { mark("deltaYield"); deltaBefore = deltaHeightSum() }
            if cfg.outletIncision {
                mark("outletIncision"); outletIncision(dt: dt)
            }
            mark("channelCarve"); channelCarve(dt: dt)
            var deltaYieldPerCell = 0.0
            if deltaOn {
                mark("deltaYield")
                let after = deltaHeightSum(collectMouths: true).sum
                deltaYieldPerCell = max(0, deltaBefore.sum - after) / Double(max(1, deltaBefore.land))
            }
            if cfg.basinFill { mark("fillLakes"); fillLakes(dt: dt) }
            if cfg.puddleFillYears > 0 { mark("fillShallowPonds"); fillShallowPonds(dt: dt) }
            if cfg.braidingEnabled { mark("braidPass"); braidPass(dt: dt) }
            let drops = dropletCount(dtYears: dt)
            let firstDrop = dropsEmitted
            dropsEmitted &+= UInt64(drops)
            mark("Hydraulic.erode")
            fill(&trackBuf, 0)
            buildDepositDamp()
            Hydraulic.erode(h: &h, rock: &rock, sed: &sed, n: n, count: drops,
                            seed: seed, floor: cfg.floor, p: cfg.hydraulic,
                            seaLevel: cfg.hydraulicSkipWaterSpawns ? cfg.sea : nil,
                            firstDrop: firstDrop,
                            hf: hf, receiver: receiver,
                            stream: streamMap,
                            channel: cfg.meanderEnabled ? isChannel : [],
                            depositDamp: depositDampBuf,
                            bedLocked: beltDropletGate(),
                            flowWeight: flowWeight,
                            erodibility: lithErodeK,
                            track: &trackBuf)
            mark("streamMapEWMA")
            let lam = Terrain.relaxFraction(dt: dt, tau: cfg.streamMapMemoryYears)
            let r0 = cfg.streamRefRate
            streamRate.withUnsafeMutableBufferPointer { srb in
            streamMap.withUnsafeMutableBufferPointer { smb in
            trackBuf.withUnsafeBufferPointer { tbb in
                let psr = srb.baseAddress!, psm = smb.baseAddress!, ptb = tbb.baseAddress!
                parallel(cfg.count) { lo, hi in
                    for k in lo..<hi {
                        let v = (1 - lam) * psr[k] + lam * (ptb[k] / dt)
                        psr[k] = v
                        psm[k] = v / (v + r0)
                    }
                }
            }}}
            if cfg.floodplainEnabled { mark("floodplainAggradation"); floodplainAggradation(dt: dt) }
            if deltaOn {
                mark("deltaDeposit"); deltaDeposit(yieldPerCell: deltaYieldPerCell)
            }
            let refN = 639.0, m1 = Double(n - 1)
            let kYear = cfg.hillDiffusion * (m1 * m1) / (refN * refN) / 100.0
            let totalK = kYear * dt
            let nSub = max(1, Int((totalK / 0.2).rounded(.up)))
            let subK = totalK / Double(nSub)
            mark("hillslopeDiffusion")
            for _ in 0..<nSub { hillslopeDiffusion(base: subK) }
            let wave = waveSchedule(dt: dt)
            mark("wavePass")
            for _ in 0..<wave.count { wavePass(relax: wave.relax) }
        } else {
            transportLimited(dt: dt)
            let wave = waveSchedule(dt: dt)
            for i in 0..<max(passes, wave.count) {
                if i < passes { diffusionPass() }
                if i < wave.count { wavePass(relax: wave.relax) }
            }
        }
        if cfg.meanderEnabled && cfg.meanderBelt && cfg.meanderBeltCoupling && cfg.meanderBeltSymmetricStamp {
            mark("belt.finishProfile")
            for ci in meander.channels.indices where MeanderState.migrates(meander.channels[ci], cfg) {
                beltStamp(dt: 0.5 * dt, only: ci, ageAtEnd: 0)
            }
        }
        mark("updateClimate")
        updateClimate(dt: dt)
        mark("updateVegetation")
        updateVegetation(years: dt)
        mark(nil)
        years += dt
    }

    private func relaxWaterLevel(dt: Double) {
        guard cfg.lakeLevelResponseYears > 0 else { waterLevel = hf; return }
        let wlam = Terrain.relaxFraction(dt: dt, tau: cfg.lakeLevelResponseYears)
        waterLevel.withUnsafeMutableBufferPointer { wlb in
        hf.withUnsafeBufferPointer { hfb in
            let pwl = wlb.baseAddress!, phf = hfb.baseAddress!
            parallel(cfg.count) { lo, hi in
                for k in lo..<hi {
                    pwl[k] = phf[k] < pwl[k] ? phf[k] : pwl[k] + (phf[k] - pwl[k]) * wlam
                }
            }
        }}
    }

    public func landRelief() -> Double {
        let count = min(cfg.count, h.count)
        guard count > 0, cfg.sea.isFinite else { return 0 }
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for k in 0..<count where h[k] > cfg.sea && h[k].isFinite {
            lo = min(lo, h[k]); hi = max(hi, h[k])
        }
        if hi < lo { return 0 }
        return min(hi - lo, .greatestFiniteMagnitude)
    }

    public func landReliefRobust() -> Double {
        Terrain.landReliefRobust(heights: h, sea: cfg.sea)
    }

    public static func landReliefRobust(heights: [Double], sea: Double) -> Double {
        landHeightQuantiles(heights: heights, sea: sea).high
    }

    public func landReliefHigh() -> Double { landReliefRobust() }

    public func landReliefLow() -> Double {
        let q = Terrain.landHeightQuantiles(heights: h, sea: cfg.sea)
        return q.low
    }

    public static func landHeightQuantiles(heights: [Double], sea: Double)
        -> (high: Double, low: Double) {
        guard let q = landHeightQuantiles(heights: heights, sea: sea,
                                          probs: [0.05, 0.5, 0.95])
        else { return (0, 0) }
        return (q[2] - q[1], q[1] - q[0])
    }

    public static func landHeightQuantiles(heights: [Double], sea: Double,
                                           probs: [Double]) -> [Double]? {
        guard sea.isFinite, !probs.isEmpty else { return nil }
        for i in 0..<probs.count {
            let p = probs[i]
            guard p.isFinite && p >= 0 && p <= 1, i == 0 || p >= probs[i - 1] else { return nil }
        }
        let bins = 4096
        let span = 2.0
        var hist = [Int](repeating: 0, count: bins)
        var total = 0
        let top = sea + span
        heights.withUnsafeBufferPointer { hb in
        hist.withUnsafeMutableBufferPointer { histb in
            guard let ph = hb.baseAddress, let phist = histb.baseAddress else { return }
            let cnt = hb.count
            for k in 0..<cnt {
                let v = ph[k]
                guard v > sea && v.isFinite else { continue }
                let b = v >= top
                    ? bins - 1
                    : min(bins - 1, max(0, Int((v - sea) / span * Double(bins))))
                phist[b] += 1
                total += 1
            }
        }}
        guard total >= 20 else { return nil }
        var out = [Double](repeating: sea + span, count: probs.count)
        var cum = 0, next = 0
        for b in 0..<bins {
            cum += hist[b]
            while next < probs.count,
                  cum > Int((Double(total - 1) * probs[next]).rounded()) {
                out[next] = sea + (Double(b) + 0.5) * span / Double(bins)
                next += 1
            }
            if next == probs.count { break }
        }
        return out
    }

    public func reliefServoRate() -> Double {
        reliefServoRate(reliefSignal: landReliefRobust())
    }

    public func reliefServoRate(reliefSignal: Double) -> Double {
        guard cfg.reliefServoPer100y > 0, cfg.reliefServoBand > 0 else { return 0 }
        let deficit = cfg.reliefTarget - reliefSignal
        guard deficit > 0 else { return 0 }
        return cfg.reliefServoPer100y * min(1, deficit / cfg.reliefServoBand)
    }

    public func upliftDecayRatePer100y() -> Double {
        let u0 = cfg.upliftDecayStartPer100y, uFloor = cfg.upliftDecayFloorPer100y
        guard cfg.upliftDecayYears > 0 else { return u0 }
        return uFloor + (u0 - uFloor) * exp(-years / cfg.upliftDecayYears)
    }

    private func upliftDecayIntegral(from a: Double, to b: Double) -> Double {
        let u0 = cfg.upliftDecayStartPer100y, uFloor = cfg.upliftDecayFloorPer100y
        if u0 <= 0 && uFloor <= 0 { return 0 }
        let tau = cfg.upliftDecayYears
        guard tau > 0 else { return u0 * (b - a) / 100 }
        let decayed = (u0 - uFloor) * tau * (exp(-a / tau) - exp(-b / tau))
        return (uFloor * (b - a) + decayed) / 100
    }

    func upliftDecayAmount(dt: Double) -> Double {
        upliftDecayIntegral(from: years, to: years + dt)
    }

    func upliftAmount(dt: Double, floorPer100y: Double) -> Double {
        let a = years, b = years + dt
        let s = max(0, floorPer100y)
        if s <= 0 { return upliftDecayIntegral(from: a, to: b) }
        let u0 = cfg.upliftDecayStartPer100y, uFloor = cfg.upliftDecayFloorPer100y
        let tau = cfg.upliftDecayYears
        guard tau > 0, u0 != uFloor else { return max(u0, s) * (b - a) / 100 }
        func rate(_ t: Double) -> Double { uFloor + (u0 - uFloor) * exp(-t / tau) }
        let rA = rate(a), rB = rate(b)
        if min(rA, rB) >= s { return upliftDecayIntegral(from: a, to: b) }
        if max(rA, rB) <= s { return s * (b - a) / 100 }
        let ratio = (s - uFloor) / (u0 - uFloor)
        let tStar = min(max(-tau * log(ratio), a), b)
        return u0 > uFloor
            ? upliftDecayIntegral(from: a, to: tStar) + s * (b - tStar) / 100
            : s * (tStar - a) / 100 + upliftDecayIntegral(from: tStar, to: b)
    }

    public func ridgeCurvature(maxAreaCells: Double = 2) -> Double {
        guard n >= 3,
              h.count >= n * n,
              area.count >= n * n,
              cfg.sea.isFinite,
              maxAreaCells > 0,
              maxAreaCells.isFinite else { return 0 }
        let cellArea = cfg.cellSize * cfg.cellSize
        guard cellArea > 0, cellArea.isFinite else { return 0 }
        let limit = maxAreaCells * cellArea
        var sum = 0.0
        var count = 0
        for j in 1..<(n - 1) {
            for i in 1..<(n - 1) {
                let k = j * n + i
                let hk = h[k]
                guard hk > cfg.sea, hk.isFinite, area[k] <= limit else { continue }
                let hLeft = h[k - 1], hRight = h[k + 1], hUp = h[k - n], hDown = h[k + n]
                guard hLeft.isFinite, hRight.isFinite, hUp.isFinite, hDown.isFinite else { continue }
                let laplacian = (hLeft + hRight + hUp + hDown - 4 * hk) / cellArea
                guard laplacian.isFinite else { continue }
                sum += laplacian
                count += 1
            }
        }
        return count == 0 ? 0 : sum / Double(count)
    }

    public func maxHeight() -> Double { h.max() ?? 0 }
    public func minHeight() -> Double { h.min() ?? 0 }

    public func totalOutletArea() -> Double {
        guard cfg.count > 0,
              receiver.count == cfg.count,
              area.count == cfg.count else { return 0 }
        let cellArea = cfg.cellSize * cfg.cellSize
        guard cellArea > 0, cellArea.isFinite else { return 0 }
        var sum = 0.0
        for k in 0..<cfg.count where receiver[k] < 0 && area[k].isFinite {
            sum += area[k]
        }
        return sum / cellArea
    }

    public func landCellCount() -> Int {
        guard cfg.count > 0,
              hf.count == cfg.count,
              cfg.sea.isFinite else { return 0 }
        var c = 0
        for k in 0..<cfg.count where hf[k] > cfg.sea && hf[k].isFinite { c += 1 }
        return c
    }

    public func receiverAgreement(with other: [Int32]) -> Double {
        guard cfg.count > 0,
              hf.count == cfg.count,
              receiver.count == cfg.count,
              other.count == cfg.count,
              cfg.sea.isFinite else { return 1 }
        var same = 0, total = 0
        for k in 0..<cfg.count where hf[k] > cfg.sea && hf[k].isFinite {
            total += 1
            if receiver[k] == other[k] { same += 1 }
        }
        return total == 0 ? 1 : Double(same) / Double(total)
    }

    public func snapshotReceivers() -> [Int32] { receiver }
}

struct TerrainState {
    var h: [Double] = []
    var rock: [Double] = []
    var sed: [Double] = []
    var upliftBase: [Double] = []
    var rain: [Double] = []
    var rainWeight: [Double] = []
    var lithHardness: [Double] = []
    var lithErodeK: [Double] = []
    var lithBed: [Double] = []
    var lithProvince: [Double] = []
    var temperature: [Double] = []
    var snow: [Double] = []
    var ice: [Double] = []
    var veg: [Double] = []
    var vegClass: [UInt8] = []
    var riparian: [Double] = []
    var heightBands: HeightBands = .legacyAbsolute
    var hf: [Double] = []
    var waterLevel: [Double] = []
    var lakeBalance: [Double] = []
    var saltCrust: [Double] = []
    var endorheicInflow: [Double] = []
    var endorheicBasin: [UInt8] = []
    var playaBed: [Bool] = []
    var receiver: [Int32] = []
    var order: [Int32] = []
    var floodParent: [Int32] = []
    var area: [Double] = []
    var areaMFD: [Double] = []
    var isChannel: [Bool] = []
    var barAge: [Double] = []
    var streamMap: [Double] = []
    var streamRate: [Double] = []
    var disturb: [Double] = []
    var regenPending: [Double] = []
    var disturbActive = false
    var meanderChannels: [RiverChannel] = []
    var oxbows: [[MeanderNode]] = []
    var oxbowAge: [Double] = []
    var years: Double = 0
    var seed: UInt32 = 0
    var dropsEmitted: UInt64 = 0
    var dropCarry: Double = 0
    var beltCouplingCarry: Double = 0
    var flowStepCount: UInt32 = 0
}

extension Terrain {
    var state: TerrainState {
        var s = TerrainState()
        s.h = h; s.rock = rock; s.sed = sed; s.upliftBase = upliftBase
        s.rain = rain; s.rainWeight = rainWeight
        s.lithHardness = lithHardness; s.lithErodeK = lithErodeK
        s.lithBed = lithBed; s.lithProvince = lithProvince
        s.temperature = temperature; s.snow = snow; s.ice = ice
        s.veg = veg; s.vegClass = vegClass; s.riparian = riparian
        s.heightBands = heightBands
        s.hf = hf; s.waterLevel = waterLevel; s.lakeBalance = lakeBalance
        s.saltCrust = saltCrust; s.endorheicInflow = endorheicInflow
        s.endorheicBasin = endorheicBasin.map(\.rawValue); s.playaBed = playaBed
        s.receiver = receiver; s.order = order; s.floodParent = floodParent
        s.area = area; s.areaMFD = areaMFD
        s.isChannel = isChannel; s.streamMap = streamMap; s.streamRate = streamRate
        s.barAge = barAge
        s.disturb = disturb; s.regenPending = regenPending
        s.disturbActive = disturbActive
        s.meanderChannels = meander.channels
        s.oxbows = meander.oxbows
        s.oxbowAge = meander.oxbowAge
        s.years = years; s.seed = seed
        s.dropsEmitted = dropsEmitted; s.dropCarry = dropCarry
        s.beltCouplingCarry = beltCouplingCarry
        s.flowStepCount = flowStepCount
        return s
    }

    func restore(_ s: TerrainState) {
        h = s.h; rock = s.rock; sed = s.sed; upliftBase = s.upliftBase
        rain = s.rain; rainWeight = s.rainWeight
        lithHardness = s.lithHardness; lithErodeK = s.lithErodeK
        lithBed = s.lithBed; lithProvince = s.lithProvince
        temperature = s.temperature; snow = s.snow; ice = s.ice
        underIce = []
        veg = s.veg; vegClass = s.vegClass; riparian = s.riparian
        heightBands = s.heightBands
        hf = s.hf; waterLevel = s.waterLevel; lakeBalance = s.lakeBalance
        saltCrust = s.saltCrust; endorheicInflow = s.endorheicInflow
        endorheicBasin = s.endorheicBasin.map(BasinRole.init(persisted:)); playaBed = s.playaBed
        receiver = s.receiver; order = s.order; floodParent = s.floodParent
        area = s.area; areaMFD = s.areaMFD
        isChannel = s.isChannel; streamMap = s.streamMap; streamRate = s.streamRate
        barAge = s.barAge
        disturb = s.disturb; regenPending = s.regenPending
        disturbActive = s.disturbActive
        let m = MeanderState()
        m.channels = s.meanderChannels
        m.oxbows = s.oxbows
        m.oxbowAge = s.oxbowAge
        meander = m
        years = s.years
        seed = s.seed
        noise = SimplexNoise(seed: s.seed)
        dropsEmitted = s.dropsEmitted
        dropCarry = s.dropCarry
        beltCouplingCarry = s.beltCouplingCarry
        flowStepCount = s.flowStepCount
    }
}

extension Double {
    @inline(__always) func magnitudeHypot(_ y: Double) -> Double {
        (self * self + y * y).squareRoot()
    }
}

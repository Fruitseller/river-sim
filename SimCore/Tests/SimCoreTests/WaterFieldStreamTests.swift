import XCTest

@testable import SimCore
@testable import SimRender

final class WaterFieldStreamTests: XCTestCase {

    private let n = 64, row = 12

    private func streamWorld(from x0: Int, to x1: Int,
                             pond: (x: Int, side: Int)? = nil,
                             channel: Bool = false) -> Terrain {
        let config = renderConfig(n: n)
        let terrain = Terrain(allocating: config, seed: 1337)
        var state = terrain.state
        let cellArea = config.cellSize * config.cellSize
        for k in 0..<(n * n) {
            state.h[k] = 0.3
            state.receiver[k] = -1
            state.area[k] = 0
            state.areaMFD[k] = 0
            state.streamMap[k] = 0
        }
        for i in x0...x1 {
            let k = row * n + i
            state.areaMFD[k] = 20 * config.renderMinCells * cellArea
            state.area[k] = state.areaMFD[k]
            state.streamMap[k] = 1
            if i < x1 { state.receiver[k] = Int32(k + 1) }
        }
        state.waterLevel = state.h
        if let pond {
            for j in (row - pond.side / 2)..<(row - pond.side / 2 + pond.side) {
                for i in pond.x..<(pond.x + pond.side) { state.waterLevel[j * n + i] = 0.35 }
            }
        }
        terrain.restore(state)
        if channel {
            terrain.meander.channels = [
                RiverChannel(nodes: (2..<(n - 2)).map { MeanderNode(x: Double($0), z: Double(row)) },
                             discharge: Array(repeating: 20 * config.renderMinCells, count: n - 4))
            ]
        }
        return terrain
    }

    private func visible(_ bytes: [UInt8], x: Int, y: Int? = nil) -> Bool {
        bytes[((y ?? row) * n + x) * 4] >= byte01(WaterRender.riverMaskLo)
    }

    private func visibleCells(_ bytes: [UInt8]) -> Int {
        (0..<(n * n)).filter { bytes[$0 * 4] >= byte01(WaterRender.riverMaskLo) }.count
    }

    private func underBand(cover: Double) -> (bytes: [UInt8], field: WaterFieldRenderer, terrain: Terrain) {
        let terrain = streamWorld(from: 10, to: 45, channel: true)
        let field = WaterFieldRenderer()
        let bytes = field.bytes(terrain, blend: 1, geometryMode: true,
                                bandChannelFlags: [true],
                                bandCoverage: [Double](repeating: cover, count: n * n),
                                deferTail: true)
        return (bytes, field, terrain)
    }

    func testBarelyCoveredStreamIsNotAnEdgeRemnant() {
        let bare = underBand(cover: 0)
        let cells = visibleCells(bare.bytes)
        XCTAssertGreaterThanOrEqual(cells, WaterRender.streamGateCells,
                                    "Aufbau: der Bach ist ohne Band sichtbar")
        XCTAssertLessThan(cells, WaterRender.wetMeadowMaxCells, "Aufbau: eine KLEINE Komponente")

        let faint = underBand(cover: WaterRender.remnantMinBandCoverage * 0.5)
        XCTAssertTrue(visible(faint.bytes, x: 28), "Raster-Wasser unter kaum deckendem Band bleibt")
        XCTAssertFalse(faint.field.wetMeadow.contains(true), "kein Rest-Fleck, keine nasse Wiese")
        XCTAssertEqual(faint.field.remnantStats.count, 0)
    }

    func testWellCoveredEdgeRemnantIsStillTakenBack() {
        let cover = max(WaterRender.remnantMinBandCoverage, 0.9)
        let covered = underBand(cover: cover)
        XCTAssertTrue(covered.field.wetMeadow[row * n + 28], "Rest unter deckendem Band wird nasse Wiese")
        XCTAssertGreaterThan(covered.field.remnantStats.count, 0)
        XCTAssertFalse(visible(covered.bytes, x: 28), "und trägt nur noch den Saum")
    }

    private func render(_ terrain: Terrain) -> (bytes: [UInt8], field: WaterFieldRenderer) {
        let field = WaterFieldRenderer()
        let bytes = field.bytes(terrain, blend: 1, geometryMode: true,
                                bandChannelFlags: [], bandCoverage: [], deferTail: true)
        return (bytes, field)
    }

    func testStreamRunsThroughAWetMeadowPond() {
        let side = 4
        let terrain = streamWorld(from: 4, to: 60, pond: (x: 28, side: side))
        XCTAssertLessThan(side * side, WaterRender.wetMeadowMaxCells)
        let (bytes, field) = render(terrain)
        let inPond = row * n + 30
        XCTAssertTrue(field.wetMeadow[inPond], "Aufbau: der Tümpel ist nasse Wiese")
        XCTAssertEqual(bytes[inPond * 4 + 1], 0, "die Wiese trägt kein See-Gate")
        for x in 20...40 {
            XCTAssertTrue(visible(bytes, x: x), "Lücke im Bach an Spalte \(x)")
        }
    }

    func testWetMeadowPondStaysDryBesideTheStream() {
        let terrain = streamWorld(from: 4, to: 60, pond: (x: 28, side: 6))
        let (bytes, field) = render(terrain)
        let pondRows = (row - 3)..<(row + 3)
        for j in pondRows where j != row {
            for i in 29..<33 {
                XCTAssertTrue(field.wetMeadow[j * n + i])
                XCTAssertEqual(bytes[(j * n + i) * 4 + 1], 0, "kein See-Gate im Tümpel")
                XCTAssertFalse(visible(bytes, x: i, y: j),
                               "Tümpel-Fläche (\(i), \(j)) darf kein Raster-Fluss sein")
            }
        }
    }

    func testIsolatedWetMeadowPondHasNoThread() {
        let terrain = streamWorld(from: 4, to: 20, pond: (x: 40, side: 4))
        let (bytes, field) = render(terrain)
        XCTAssertTrue(field.wetMeadow[row * n + 41])
        for x in 38...46 { XCTAssertFalse(visible(bytes, x: x), "Faden im Tümpel an Spalte \(x)") }
    }

    func testLakeKeepsItsOwnWaterWithoutAThread() {
        let terrain = streamWorld(from: 4, to: 60, pond: (x: 24, side: 16))
        XCTAssertGreaterThanOrEqual(16 * 16, WaterRender.wetMeadowMaxCells)
        let (bytes, field) = render(terrain)
        XCTAssertFalse(field.wetMeadow.contains(true))
        let inLake = row * n + 31
        XCTAssertGreaterThan(bytes[inLake * 4 + 1], 0, "See malt der See-Kanal")
        XCTAssertFalse(visible(bytes, x: 31), "kein Raster-Faden im See")
    }
}

import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter für zwei Ränder des Raster-Wassers, an denen ein Bach ABREISST
/// (Review zu #174 C): die Rest-Flecken-Regel unter einem teilweise deckenden
/// Band (`WaterRender.remnantMinBandCoverage`) und die Fortsetzung der
/// Kontinuitäts-Kette durch nasse Wiese. Beide laufen auf kleinen Kunstwelten:
/// ebenes Land, ein Bach in Zeile `row` (Stream-Map und Abfluss gesetzt, D8-
/// Empfänger von links nach rechts), die Felder der Gegenstelle bleiben leer.
final class WaterFieldStreamTests: XCTestCase {

    private let n = 64, row = 12

    /// Ebene auf 0,3 mit einem Bach in Zeile `row` von `x0` bis `x1`. `pond`
    /// = quadratischer Tümpel (0,05 tief, Kante `side`, linke obere Ecke
    /// `(px, row - side / 2)`), den der Bach in der Mitte durchquert.
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

    // MARK: Rest-Flecken unter einem Band, das kaum deckt

    private func underBand(cover: Double) -> (bytes: [UInt8], field: WaterFieldRenderer, terrain: Terrain) {
        let terrain = streamWorld(from: 10, to: 45, channel: true)
        let field = WaterFieldRenderer()
        let bytes = field.bytes(terrain, blend: 1, geometryMode: true,
                                bandChannelFlags: [true],
                                bandCoverage: [Double](repeating: cover, count: n * n),
                                deferTail: true)
        return (bytes, field, terrain)
    }

    /// An einer Steilstufe blendet das Band aus (Kaskaden-Übergabe), seine
    /// Deckung läuft über kleine Werte aus. Dort ist das Raster das Wasser: ein
    /// kleiner Raster-Rest unter fast nicht deckendem Band darf nicht als
    /// „Rest-Fleck am Band" zurückgenommen und zu nasser Wiese werden.
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

    /// Gegenprobe: wo das Band deckt (aber nicht voll), bleibt die Regel wie
    /// dokumentiert (`docs/river-coast-render-measurements.md` §A).
    func testWellCoveredEdgeRemnantIsStillTakenBack() {
        let cover = max(WaterRender.remnantMinBandCoverage, 0.9)
        let covered = underBand(cover: cover)
        XCTAssertTrue(covered.field.wetMeadow[row * n + 28], "Rest unter deckendem Band wird nasse Wiese")
        XCTAssertGreaterThan(covered.field.remnantStats.count, 0)
        XCTAssertFalse(visible(covered.bytes, x: 28), "und trägt nur noch den Saum")
    }

    // MARK: Bach durch nasse Wiese

    private func render(_ terrain: Terrain) -> (bytes: [UInt8], field: WaterFieldRenderer) {
        let field = WaterFieldRenderer()
        let bytes = field.bytes(terrain, blend: 1, geometryMode: true,
                                bandChannelFlags: [], bandCoverage: [], deferTail: true)
        return (bytes, field)
    }

    /// Ein Bach durch einen Tümpel unter `wetMeadowMaxCells`: der Tümpel ist
    /// nasse Wiese (kein See-Kanal), der Bach aber läuft hindurch. Vorher
    /// endete die Kontinuitäts-Kette am ersten Tümpel-Rand, und der Bach hatte
    /// im Tümpel eine Lücke.
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

    /// Der Tümpel selbst bleibt Wiese: außerhalb der Bach-Linie (Zeile `row`)
    /// malt das Raster im Tümpel kein Wasser. Der Tümpel-Teppich kommt nicht zurück.
    func testWetMeadowPondStaysDryBesideTheStream() {
        let terrain = streamWorld(from: 4, to: 60, pond: (x: 28, side: 6))
        let (bytes, field) = render(terrain)
        // Die Randspalten (28, 33) nimmt die Verbreiterung des Baches von
        // außen mit; das gilt unverändert seit vor #174 und ist hier nicht
        // der Gegenstand.
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

    /// Ein Tümpel ohne Bach bleibt ganz Wiese, ohne Faden.
    func testIsolatedWetMeadowPondHasNoThread() {
        let terrain = streamWorld(from: 4, to: 20, pond: (x: 40, side: 4))
        let (bytes, field) = render(terrain)
        XCTAssertTrue(field.wetMeadow[row * n + 41])
        for x in 38...46 { XCTAssertFalse(visible(bytes, x: x), "Faden im Tümpel an Spalte \(x)") }
    }

    /// Ein SEE (ab `wetMeadowMaxCells`) bleibt Wasser des See-Kanals; die Kette
    /// zieht keinen zweiten Faden hindurch.
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

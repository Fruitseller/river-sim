import XCTest
@testable import SimCore

/// Tests für den Pseudozufallsgenerator `Mulberry32` und `SimplexNoise` (`Noise.swift`).
final class NoiseTests: XCTestCase {

    /// Mulberry32 muss bei gleichem Seed bit-identische Sequenzen im Intervall [0, 1) erzeugen.
    func testMulberry32Determinism() {
        var rng1 = Mulberry32(seed: 42)
        var rng2 = Mulberry32(seed: 42)
        var diffRng = Mulberry32(seed: 43)

        var values1: [Double] = []
        var values2: [Double] = []
        var diffValues: [Double] = []
        for _ in 0..<100 {
            let v1 = rng1.next()
            let v2 = rng2.next()
            let vd = diffRng.next()
            XCTAssertGreaterThanOrEqual(v1, 0.0)
            XCTAssertLessThan(v1, 1.0)
            values1.append(v1)
            values2.append(v2)
            diffValues.append(vd)
        }

        XCTAssertEqual(values1, values2, "Gleicher Seed muss identische Folgen liefern")
        XCTAssertNotEqual(values1, diffValues, "Unterschiedliche Seeds müssen sich unterscheiden")
    }

    /// SimplexNoise liefert bei gleichem Seed deterministische Werte.
    /// fBm und ridged müssen im Intervall [0, 1] liegen.
    func testSimplexNoiseDeterminismAndRange() {
        let noise1 = SimplexNoise(seed: 1234)
        let noise2 = SimplexNoise(seed: 1234)

        for j in 0..<10 {
            for i in 0..<10 {
                let x = Double(i) * 0.1
                let y = Double(j) * 0.1
                let v1 = noise1.value(x, y)
                let v2 = noise2.value(x, y)
                XCTAssertEqual(v1, v2, "SimplexNoise muss deterministisch sein")
                XCTAssertGreaterThanOrEqual(v1, -1.5)
                XCTAssertLessThanOrEqual(v1, 1.5)

                let fbm = noise1.fbm01(x, y, octaves: 4)
                XCTAssertGreaterThanOrEqual(fbm, 0.0)
                XCTAssertLessThanOrEqual(fbm, 1.0)

                let ridged = noise1.ridged01(x, y, octaves: 4)
                XCTAssertGreaterThanOrEqual(ridged, 0.0)
                XCTAssertLessThanOrEqual(ridged, 1.0)
            }
        }
    }

    /// Nicht-endliche (NaN, ±inf) oder extrem große Koordinaten dürfen nicht
    /// zu Speicherzugriffsfehlern oder Int-Konvertierungsabbrüchen führen,
    /// sondern werden sicher auf 0 gefaltet.
    func testSimplexNoiseNonFiniteAndOutOfBoundsSafety() {
        let noise = SimplexNoise(seed: 999)

        XCTAssertEqual(noise.value(Double.nan, 0.0), 0.0)
        XCTAssertEqual(noise.value(0.0, Double.nan), 0.0)
        XCTAssertEqual(noise.value(Double.infinity, 0.0), 0.0)
        XCTAssertEqual(noise.value(0.0, -Double.infinity), 0.0)
        XCTAssertEqual(noise.value(Double.nan, Double.infinity), 0.0)

        // Extrem große Koordinaten jenseits des Definitionsbereichs
        XCTAssertEqual(noise.value(1e12, 0.0), 0.0)
        XCTAssertEqual(noise.value(0.0, -1e12), 0.0)

        // Auch über fBm01 müssen NaN-Koordinaten sicher zu neutralem Wert führen
        let fbmNan = noise.fbm01(Double.nan, 0.0, octaves: 4)
        XCTAssertEqual(fbmNan, 0.5)

        let fbmInf = noise.fbm01(0.0, Double.infinity, octaves: 4)
        XCTAssertEqual(fbmInf, 0.5)
    }

    /// Nicht-positive Oktaven (octaves <= 0) oder nicht-endliche Parameter
    /// dürfen keine Division durch Null (0/0 = NaN) auslösen.
    func testFractalNoiseWithNonPositiveOctavesAndNonFiniteParams() {
        let noise = SimplexNoise(seed: 555)

        // fbm01 liefert bei octaves <= 0 defensiv den neutralen Mittelwert 0.5
        XCTAssertEqual(noise.fbm01(1.0, 2.0, octaves: 0), 0.5)
        XCTAssertEqual(noise.fbm01(1.0, 2.0, octaves: -3), 0.5)

        // ridged01 liefert bei octaves <= 0 oder ungültigen Parametern defensiv 0.0
        XCTAssertEqual(noise.ridged01(1.0, 2.0, octaves: 0), 0.0)
        XCTAssertEqual(noise.ridged01(1.0, 2.0, octaves: -2), 0.0)
        XCTAssertEqual(noise.ridged01(1.0, 2.0, octaves: 3, lacunarity: Double.nan), 0.0)
        XCTAssertEqual(noise.ridged01(1.0, 2.0, octaves: 3, gain: Double.infinity), 0.0)
    }
}

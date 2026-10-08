import XCTest
@testable import SimCore
@testable import SimRender

/// Abnahmematrix für Landschaftsqualität (Issue #150, Spec #156, Parent #117).
///
/// Definiert die standardisierten Vergleichswelten und Kamerapositionen für reproduzierbare
/// Vorher/Nachher-Vergleiche und Abnahmemessungen zukünftiger Grafik- und Simulations-Tickets.
///
/// Enthält:
/// 1. Vertragsprüfungen der Matrixdefinition (ungatet, Teil der Pflichtsuite)
/// 2. Baseline-Metriken-Lauf der physikalischen Felder (gegatet mit RS_MEASURE=1, Namensendung Diagnostic)
final class GraphicsMatrixTests: XCTestCase {

    public struct MatrixCamera {
        public let id: String
        public let targetX: Double
        public let targetZ: Double
        public let distance: Double
        public let yaw: Double
        public let pitch: Double
        public let sunAzimuth: Double?
        public let sunElevation: Double?
        public let description: String

        public init(id: String, targetX: Double, targetZ: Double, distance: Double, yaw: Double, pitch: Double,
                    sunAzimuth: Double? = nil, sunElevation: Double? = nil, description: String) {
            self.id = id
            self.targetX = targetX
            self.targetZ = targetZ
            self.distance = distance
            self.yaw = yaw
            self.pitch = pitch
            self.sunAzimuth = sunAzimuth
            self.sunElevation = sunElevation
            self.description = description
        }
    }

    public struct MatrixWorldSpec {
        public let seed: UInt32
        public let name: String
        public let description: String
        public let primaryFeatures: [String]
        public let cameras: [MatrixCamera]

        public init(seed: UInt32, name: String, description: String, primaryFeatures: [String], cameras: [MatrixCamera]) {
            self.seed = seed
            self.name = name
            self.description = description
            self.primaryFeatures = primaryFeatures
            self.cameras = cameras
        }
    }

    public static let standardYears: [Double] = [0.0, 20_000.0, 100_000.0]

    /// Verbindliche Spezifikation der Vergleichswelten und Kameraperspektiven.
    public static let matrixWorlds: [MatrixWorldSpec] = [
        // -------------------------------------------------------------
        // Seed 1337: Flusstal Soča (Referenzwelt der Studie #116)
        // Steiles Kerbtal, canyonartiger Hauptfluss, bewaldete Talsohle,
        // Grate und Mündung ins Meer.
        // -------------------------------------------------------------
        MatrixWorldSpec(
            seed: 1337,
            name: "Flusstal Soča",
            description: "Dramatisches felsiges Kerbtal mit Hauptfluss, Zuflüssen, dichter Talbewaldung und Meeresdelta",
            primaryFeatures: ["bewaldete Täler", "Flussschlucht", "Küste/Mündung", "kahle Grate"],
            cameras: [
                MatrixCamera(
                    id: "overview",
                    targetX: 0.0, targetZ: 0.0,
                    distance: 151.846515, yaw: 0.7, pitch: 0.85,
                    description: "Vollständige Inselübersicht (Standard-Studienkamera aus #116)"
                ),
                MatrixCamera(
                    id: "detail",
                    targetX: -12.0, targetZ: -25.0,
                    distance: 42.0, yaw: 0.7, pitch: 0.85,
                    description: "Nahansicht des Soča-Flusstals mit Waldsaum und Felsflanken (#116)"
                ),
                MatrixCamera(
                    id: "grazing",
                    targetX: -10.0, targetZ: -20.0,
                    distance: 38.0, yaw: 0.7, pitch: 1.35,
                    description: "Sehr flacher Blickwinkel (~13° über Horizont) entlang der Talflanke"
                ),
                MatrixCamera(
                    id: "backlight",
                    targetX: -12.0, targetZ: -25.0,
                    distance: 45.0, yaw: -0.87, pitch: 0.85,
                    sunAzimuth: -50.0, sunElevation: 28.0,
                    description: "Gegenlichtaufnahme direkt gegen die tiefstehende Sonne (Azimut -50°)"
                ),
                MatrixCamera(
                    id: "coast",
                    targetX: -36.0, targetZ: -32.0,
                    distance: 45.0, yaw: 0.9, pitch: 0.85,
                    description: "Mündungsdelta des Hauptflusses an der Meeresküste mit Brandungssaum"
                ),
                MatrixCamera(
                    id: "snow",
                    targetX: 18.0, targetZ: 14.0,
                    distance: 48.0, yaw: 0.6, pitch: 0.75,
                    description: "Hohe Gebirgsrippe und Übergang von Fels zu Firnfeldern"
                )
            ]
        ),

        // -------------------------------------------------------------
        // Seed 42: Binnenseen & Beckenlandschaft
        // Dokumentiert in #121/nickmcd für dynamisch füllende und schneidende
        // Krater- und Beckenseen, breite Verlandungszonen und Uferlinien.
        // -------------------------------------------------------------
        MatrixWorldSpec(
            seed: 42,
            name: "Seen- und Beckenplateau",
            description: "Hochplateau mit großem Binnensee, Verlandungsauen und dynamischem Auslass-Sill",
            primaryFeatures: ["Seen", "Verlandungszonen", "Seeufer", "bewaldete Beckenränder"],
            cameras: [
                MatrixCamera(
                    id: "overview",
                    targetX: 0.0, targetZ: 0.0,
                    distance: 151.846515, yaw: 0.7, pitch: 0.85,
                    description: "Übersicht über die Insel mit zentralem Seen- und Entwässerungssystem"
                ),
                MatrixCamera(
                    id: "detail",
                    targetX: 4.0, targetZ: -6.0,
                    distance: 45.0, yaw: 0.5, pitch: 0.80,
                    description: "Nahansicht des großen Binnensees und der einmündenden Zuflüsse"
                ),
                MatrixCamera(
                    id: "grazing",
                    targetX: 6.0, targetZ: -4.0,
                    distance: 40.0, yaw: 0.4, pitch: 1.35,
                    description: "Extrem flacher Blick über die weite Wasserfläche des Binnensees"
                ),
                MatrixCamera(
                    id: "backlight",
                    targetX: 4.0, targetZ: -6.0,
                    distance: 48.0, yaw: -0.87, pitch: 0.85,
                    sunAzimuth: -50.0, sunElevation: 28.0,
                    description: "Gegenlicht über dem Seebecken mit Reflexions- und Schattenprüfung"
                ),
                MatrixCamera(
                    id: "coast",
                    targetX: 12.0, targetZ: -10.0,
                    distance: 38.0, yaw: 1.1, pitch: 0.85,
                    description: "Uferlinie des Binnensees mit Verlandungssaum und Schilf-/Auenwald"
                ),
                MatrixCamera(
                    id: "snow",
                    targetX: -22.0, targetZ: 20.0,
                    distance: 50.0, yaw: 0.7, pitch: 0.75,
                    description: "Umgebender Krater- und Beckenrand mit kahlen Steilhängen"
                )
            ]
        ),

        // -------------------------------------------------------------
        // Seed 20: Hochalpines Massiv & Kaltklima
        // Dokumentiert in melt-runoff-measurements.md für maximale Spitzenhöhe
        // (maxH 0.75), die meisten schneegespeisten Läufe (306) und glaziale Kare.
        // -------------------------------------------------------------
        MatrixWorldSpec(
            seed: 20,
            name: "Hochalpines Massiv",
            description: "Extremes Hochgebirge mit maximalem Relief, weiten Schneefeldern und schroffen Graten",
            primaryFeatures: ["verschneite Hänge", "kahle Grate", "glaziale Kare", "hochalpiner Übergang"],
            cameras: [
                MatrixCamera(
                    id: "overview",
                    targetX: 0.0, targetZ: 0.0,
                    distance: 151.846515, yaw: 0.7, pitch: 0.85,
                    description: "Übersicht über das gesamte alpine Zentralmassiv und seine Gletscherkare"
                ),
                MatrixCamera(
                    id: "detail",
                    targetX: -8.0, targetZ: 10.0,
                    distance: 42.0, yaw: 0.6, pitch: 0.80,
                    description: "Nahansicht eines hochalpinen Karenbeckens mit Schneefeld und Schmelzbach"
                ),
                MatrixCamera(
                    id: "grazing",
                    targetX: -6.0, targetZ: 12.0,
                    distance: 38.0, yaw: 0.5, pitch: 1.35,
                    description: "Flacher Blick über die Schneefelder und Steilflanken gegen den Horizont"
                ),
                MatrixCamera(
                    id: "backlight",
                    targetX: -8.0, targetZ: 10.0,
                    distance: 46.0, yaw: -0.87, pitch: 0.85,
                    sunAzimuth: -50.0, sunElevation: 28.0,
                    description: "Gegenlicht an den scharfen Felsgraten mit Schattenwurf auf Schneefelder"
                ),
                MatrixCamera(
                    id: "coast",
                    targetX: 30.0, targetZ: -28.0,
                    distance: 48.0, yaw: 0.8, pitch: 0.85,
                    description: "Steilküste am Fuße des Massivs, wo alpine Bäche ins Meer stürzen"
                ),
                MatrixCamera(
                    id: "snow",
                    targetX: -10.0, targetZ: 14.0,
                    distance: 40.0, yaw: 0.6, pitch: 0.70,
                    description: "Zentraler Hochgipfel mit scharfen Graten und dauerhafter Schneedecke"
                )
            ]
        )
    ]

    // MARK: - Vertragsprüfungen (Teil der Pflichtsuite)

    func testMatrixContractSpecification() {
        let worlds = Self.matrixWorlds
        XCTAssertGreaterThanOrEqual(worlds.count, 3, "Mindestens 3 Seeds müssen in der Matrix definiert sein")
        XCTAssertTrue(worlds.contains { $0.seed == 1337 }, "Seed 1337 (Studienreferenz) ist Pflicht")

        let expectedYears = [0.0, 20_000.0, 100_000.0]
        XCTAssertEqual(Self.standardYears, expectedYears, "Matrix muss Jahre 0, 20k und 100k umfassen")

        let requiredCameras = ["overview", "detail", "grazing", "backlight", "coast", "snow"]
        let worldSize = SimConfig.production.world
        let maxCoord = worldSize * 0.5

        for world in worlds {
            XCTAssertFalse(world.name.isEmpty, "Jede Welt braucht einen Namen")
            XCTAssertFalse(world.description.isEmpty, "Jede Welt braucht eine Beschreibung")
            XCTAssertGreaterThanOrEqual(world.primaryFeatures.count, 3, "Jede Welt deckt mindestens 3 Hauptmerkmale ab")

            var cameraIds = Set<String>()
            for cam in world.cameras {
                XCTAssertFalse(cameraIds.contains(cam.id), "Kamera-ID '\(cam.id)' doppelt in Seed \(world.seed)")
                cameraIds.insert(cam.id)

                // Gültigkeit der Koordinaten und Parameter
                XCTAssertGreaterThanOrEqual(cam.targetX, -maxCoord, "targetX außerhalb der Welt")
                XCTAssertLessThanOrEqual(cam.targetX, maxCoord, "targetX außerhalb der Welt")
                XCTAssertGreaterThanOrEqual(cam.targetZ, -maxCoord, "targetZ außerhalb der Welt")
                XCTAssertLessThanOrEqual(cam.targetZ, maxCoord, "targetZ außerhalb der Welt")

                XCTAssertGreaterThan(cam.distance, 10.0, "Kameraabstand zu klein")
                XCTAssertLessThan(cam.distance, worldSize * 2.0, "Kameraabstand zu groß")

                XCTAssertGreaterThan(cam.pitch, 0.2, "Pitch zu flach (senkrecht von oben)")
                XCTAssertLessThan(cam.pitch, 1.55, "Pitch zu steil (horizontal oder unterhalb Horizont)")
            }

            for req in requiredCameras {
                XCTAssertTrue(cameraIds.contains(req),
                              "Welt Seed \(world.seed) fehlt Pflichtkamera '\(req)'")
            }
        }
    }

    func testMatrixLandscapeFeatureCoverage() {
        let allFeatures = Self.matrixWorlds.flatMap { $0.primaryFeatures }
        XCTAssertTrue(allFeatures.contains { $0.contains("bewaldet") }, "Bewaldete Täler müssen abgedeckt sein")
        XCTAssertTrue(allFeatures.contains { $0.contains("Schnee") || $0.contains("kahl") },
                      "Kahle oder verschneite Hänge müssen abgedeckt sein")
        XCTAssertTrue(allFeatures.contains { $0.contains("See") || $0.contains("Küste") || $0.contains("Mündung") },
                      "Seen oder Mündungen müssen abgedeckt sein")
    }

    // MARK: - Baseline-Messharness (gegatet mit RS_MEASURE=1)

    /// Headless-Messung der physikalischen Ausgangszustände über alle Matrixwelten.
    /// Laufzeit ca. 15 Minuten (3 Seeds über jeweils 100k Jahre bei n = 720).
    func testMatrixBaselineMetricsDiagnostic() throws {
        try skipUnlessMeasuring()

        let env = ProcessInfo.processInfo.environment
        let filterSeed = env["RS_SEED"].flatMap { UInt32($0) }
        let maxYear = env["RS_YEARS"].flatMap { Double($0) } ?? 100_000.0

        print("\n=== ABNAHMEMATRIX: PHYSIKALISCHE BASELINE-KENNZAHLEN ===")
        print("| Seed | Name | Stadium | max_y | Relief (p95-med) | See-Zellen | Ozean-Zellen | Schnee-Zellen | Wald-Zellen | Kanal-Knoten |")
        print("| ---: | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")

        let diag = TerrainDiagnostics()
        for spec in Self.matrixWorlds {
            if let fs = filterSeed, spec.seed != fs { continue }
            let t = Terrain(config: .production, seed: spec.seed, settleYears: SimConfig.productionSettleYears)
            var currentYear = 0.0

            for targetYear in Self.standardYears where targetYear <= maxYear + 1e-5 {
                while currentYear < targetYear - 1e-5 {
                    let stepSize = min(1000.0, targetYear - currentYear)
                    t.step(dtYears: stepSize)
                    currentYear += stepSize
                }

                let stats = diag.stats(t)
                let maxY = Double(stats[2]) * RenderContract.heightScale
                let robustRelief = Double(stats[16]) * RenderContract.heightScale

                let seaLevel = t.cfg.sea
                var lakeCount = 0
                var oceanCount = 0
                var snowCount = 0
                var vegCount = 0

                for i in 0..<t.cfg.count {
                    let hVal = t.h[i]
                    let wlVal = t.waterLevel[i]
                    if hVal <= seaLevel {
                        oceanCount += 1
                    } else if wlVal > hVal + 0.005 {
                        lakeCount += 1
                    }
                    if t.snow[i] > 0.05 { snowCount += 1 }
                    if t.veg[i] > 0.25 { vegCount += 1 }
                }

                let channelNodes = t.meander.channels.reduce(0) { $0 + $1.nodes.count }
                let stageName = targetYear == 0 ? "Jahr 0 (Einlauf)" : String(format: "Jahr %dk", Int(targetYear / 1000.0))

                print(String(
                    format: "| %d | %@ | %@ | %.2f m | %.2f m | %d | %d | %d | %d | %d |",
                    spec.seed, spec.name, stageName, maxY, robustRelief,
                    lakeCount, oceanCount, snowCount, vegCount, channelNodes
                ))
            }
        }
        print("=== ENDE MATRIXZAHLEN ===\n")
    }
}

import Foundation

/// Alle kalibrierbaren Konstanten des Simulationskerns an einem Ort.
/// Höhen sind normiert (~ -0.3 .. 1.4). Weltkoordinaten in abstrakten Einheiten.
public struct SimConfig: Sendable {
    public var n: Int = 256          // Grid-Auflösung (n × n)
    public var world: Double = 100   // Kantenlänge in Welteinheiten
    public var sea: Double = 0.15     // Meeresspiegel (normiert)
    public var floor: Double = -0.3   // tiefster Punkt (Tiefseegraben)

    // ---- Terrain-Generierung ----
    public var baseOctaves: Int = 5
    public var baseFreq: Double = 3    // Grundfrequenz (× 1/n)
    public var upliftFreq: Double = 2.5

    // ---- Stream-Power-Inzision (detachment-limited, FastScape) ----
    // dz/dt = U − K·A^m·S^n ;  n = 1 (implizit, unbedingt stabil)
    public var mExp: Double = 0.5      // Flächen-Exponent m
    public var kRock: Double = 8.0e-5  // Erodierbarkeit Grundgestein
    public var kSed: Double = 2.5e-4   // Erodierbarkeit lockeres Sediment (weicher)
    public var sedCoverThresh: Double = 0.01 // ab so viel Sediment gilt "bedeckt"
    public var transportCap: Double = 9.0  // Transportkapazität-Koeffizient (SPACE)

    // ---- Hangprozesse (thermische Erosion / Talus) ----
    public var talus: Double = 0.011   // kritische Höhendifferenz je Zelle
    public var thermalRelax: Double = 0.3
    public var rockCrumble: Double = 0.15 // Fels-Anteil beim Hangrutsch (Basis)

    // ---- Tektonik / Isostasie ----
    public var upliftPer100y: Double = 0.0026 // niedriger → Gipfel erosions-begrenzt (spitz), nicht an der Kappe abgeflacht
    public var isoHighClamp: Double = 0.82 // Hebung → 0 gegen diese Höhe (hohe Gipfel)
    public var isoLowRange: Double = 0.35   // Senkung → 0 gegen den Boden

    // ---- Küste ----
    public var waveBand: Double = 0.06
    public var waveTalus: Double = 0.002
    public var waveRelax: Double = 0.5

    // ---- Klima / Vegetation ----
    public var vegTimeConstant: Double = 250 // Jahre

    // ---- Mäander-Migration (Lagrange-Zentrumslinien) ----
    public var meanderMigration: Double = 5.0e-5 // kMig: laterale Rate ∝ Krümmung×Abfluss (sättigt Sinuosität ~2.3, bildet Altarme)
    public var meanderMinCells: Double = 85       // ab so viel Einzugsgebiet gilt "Hauptfluss"
    public var meanderNodeSpacing: Double = 1.5   // Ziel-Knotenabstand (Zellen)
    public var meanderNeckDist: Double = 1.2      // Halsbreite für Cutoff (Zellen)
    public var meanderSmooth: Double = 0.12       // milde Laplace-Glättung je Schritt
    public var meanderFlatSlope: Double = 0.02    // nur unter dieser Steigung mobil (Flachland)
    // ---- Mäander-Grid-Kopplung (M3) ----
    public var meanderCarve: Double = 2.5e-4      // Bett-Inzision entlang der Linie (∝ kSed)
    public var meanderBankErode: Double = 1.2e-4  // Prallhang-Erosion (lateral, massenerhaltend)
    public var meanderBankWidth: Double = 1.6     // Halbbreite Ufer-Versatz (Zellen)
    public var channelErodeDamp: Double = 0.4     // Grid-Stream-Power auf Kanalzellen (Reconciliation)

    public init() {}

    public var cellSize: Double { world / Double(n - 1) }
    public var count: Int { n * n }
}

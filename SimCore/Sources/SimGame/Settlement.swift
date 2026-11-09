import Foundation

/// Spielregeln einer Siedlung im Mutter-Natur-Prototyp (Issue #223): rein,
/// ohne Terrain — sie bekommt je abgeschlossenem Sim-Jahr die gemessene
/// Versorgung und schreibt Vorrat, Bevölkerung und Verlauf fort. Dadurch ist
/// die Jahresauswertung headless und unabhängig von Schritt-Aufteilung und
/// Bildrate prüfbar (`NatureGameTests`).
///
/// Alle Zahlen sind ein erster Versuch, KEINE validierte Balance (s.
/// `docs/nature-prototype.md`). Einheiten: Bevölkerung relativ zum Start
/// (1 = voll besiedelt), Vorrat in Jahresrationen je Kopf.
public enum SettlementRules {
    /// Ertrag je Kopf bei voller Versorgung. 1,25 heißt: ein gutes Jahr legt
    /// eine Viertel-Jahresration zurück.
    public static let yieldPerCapita = 1.25
    /// Start- und Höchstvorrat (Jahresrationen). Mit 1,5 überbrückt eine
    /// Siedlung EIN Totalausfall-Jahr ohne Abwanderung; ab dem zweiten
    /// beginnt sie, nach ~5 Totalausfall-Jahren ist sie verlassen.
    public static let startReserve = 1.5
    public static let maxReserve = 2.0
    /// Anteil der Bevölkerung, der je fehlender Jahresration abwandert.
    public static let emigrationPerShortage = 0.45
    /// Rückkehr/Zuzug je gutem Jahr, solange der Vorrat mindestens
    /// `regrowReserve` beträgt.
    public static let regrowPerYear = 0.04
    public static let regrowReserve = 0.5
    /// Unter diesem Bevölkerungsanteil gilt die Siedlung als verlassen
    /// (endgültig: wer geht, kommt im Prototyp nicht zurück).
    public static let abandonBelow = 0.2
    /// Überflutete Häuser kosten Reparatur-Arbeit (Jahresrationen je Jahr).
    public static let houseFloodCost = 0.35
    /// So viele Jahre bleiben im Verlauf (Anzeige).
    public static let historyLength = 12
}

public enum SettlementStatus: Int, Sendable {
    case stable = 0
    case undersupplied = 1
    case emigrating = 2
    case abandoned = 3

    public var label: String {
        switch self {
        case .stable: "stabil"
        case .undersupplied: "unterversorgt"
        case .emigrating: "Abwanderung"
        case .abandoned: "verlassen"
        }
    }
}

/// Grund des Problems im letzten Jahr.
public enum SupplyProblem: Int, Sendable {
    case none = 0
    /// Felder bekommen zu wenig Wasser.
    case drought = 1
    /// Felder oder Häuser stehen unter Wasser.
    case flood = 2

    public var label: String {
        switch self {
        case .none: "—"
        case .drought: "Wassermangel auf den Feldern"
        case .flood: "Überflutung"
        }
    }
}

/// Ein abgeschlossenes Jahr der Siedlung.
public struct YearRecord: Equatable, Sendable {
    public let year: Int
    /// Ernte relativ zum Bedarf der Bevölkerung (1 = genau gedeckt).
    public let harvest: Double
    public let problem: SupplyProblem
    public let reserve: Double
    public let population: Double
}

/// Was ein Jahr an Versorgung hatte — zeitgewichtetes Mittel über das Jahr.
public struct YearSupply: Equatable, Sendable {
    /// Bewässerte Feldfläche (0…1), überflutete Zellen zählen als 0.
    public var water: Double
    /// Überfluteter Feldanteil (0…1).
    public var floodedFields: Double
    /// Überfluteter Häuseranteil (0…1).
    public var floodedHouses: Double

    public init(water: Double, floodedFields: Double = 0, floodedHouses: Double = 0) {
        self.water = water
        self.floodedFields = floodedFields
        self.floodedHouses = floodedHouses
    }
}

/// Zustand einer Siedlung.
public struct SettlementState: Equatable, Sendable {
    public private(set) var population = 1.0
    public private(set) var reserve = SettlementRules.startReserve
    /// Aufeinanderfolgende schlechte Jahre (Ernte unter Bedarf).
    public private(set) var badStreak = 0
    public private(set) var status = SettlementStatus.stable
    public private(set) var problem = SupplyProblem.none
    public private(set) var history: [YearRecord] = []

    public init() {}

    public var isAbandoned: Bool { status == .abandoned }

    /// Schließt ein Sim-Jahr ab. `extraCost`: Jahresrationen, die die
    /// Siedlung für Gegenmaßnahmen ausgibt (Ausbessern, s. `NatureGame`).
    public mutating func closeYear(_ year: Int, supply: YearSupply, extraCost: Double = 0) {
        guard !isAbandoned else { return }
        let r = SettlementRules.self
        let harvest = max(0, supply.water) * r.yieldPerCapita
        let floodCost = supply.floodedHouses * r.houseFloodCost
        let net = harvest - 1 - floodCost - extraCost
        let bad = harvest < 1 || supply.floodedHouses > 0
        if bad {
            badStreak += 1
            problem = supply.floodedFields + supply.floodedHouses > 0.15 ? .flood : .drought
        } else {
            badStreak = 0
            problem = .none
        }
        reserve += net
        var left = 0.0
        if reserve < 0 {
            // Fehlende Rationen: ein Teil der Leute geht.
            left = min(population, population * r.emigrationPerShortage * -reserve)
            reserve = 0
        }
        population -= left
        reserve = min(reserve, r.maxReserve)
        if !bad && reserve >= r.regrowReserve {
            population = min(1, population + r.regrowPerYear)
        }
        if population < r.abandonBelow {
            status = .abandoned
        } else if left > 0 {
            status = .emigrating
        } else if bad {
            status = .undersupplied
        } else {
            status = .stable
        }
        history.append(YearRecord(year: year, harvest: harvest, problem: problem,
                                  reserve: reserve, population: population))
        if history.count > r.historyLength { history.removeFirst(history.count - r.historyLength) }
    }

    /// Ausgabe für Gegenmaßnahmen, ohne Jahresabschluss.
    mutating func spend(_ amount: Double) {
        reserve = max(0, reserve - amount)
    }
}

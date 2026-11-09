import Foundation
import SimCore

/// Spielzustand des Mutter-Natur-Prototyps (Issue #223): Siedlungen, Jahres-
/// uhr, Eingriffsbudget und die Gegenreaktion der Menschen. Liest das Terrain
/// (Entwässerung `area`, Füllstand `hf`) und schreibt es nur an zwei benannten
/// Stellen: dem Spieler-Pinsel (`brush`) und dem Ausbessern der Menschen
/// (`repair`). Keine Render-Logik, kein Godot — die Brücke reicht nur weiter.
///
/// Näherungen, ausdrücklich fürs Spiel (nicht Teil der Produktionsphysik):
/// - **Wasseranschluss**: eine Feldzelle ist bewässert, wenn im Umkreis
///   `irrigationReach` eine Zelle mit D8-Einzugsgebiet ≥ `needArea` Zellen
///   liegt (anteilig darunter). `area` ist ein Abfluss-GEWICHT (Regen × Fläche,
///   Landmittel 1), keine kalibrierte Durchflussmenge.
/// - **Überflutung**: eine Zelle steht unter Wasser, wenn der Füllstand `hf`
///   der Priority-Flood mehr als `floodDepth` über dem Boden liegt. Ein
///   aufgestauter See steht damit SOFORT auf Überlaufhöhe — keine bilanzierte
///   Füllung, keine Flutwelle.
/// - **Zeit**: gemeinsame Sim-Zeit. Ein Jahr wird abgeschlossen, sobald die
///   Sim-Jahre es überschreiten; die Versorgung des Jahres ist das
///   zeitgewichtete Mittel der Messungen nach jedem Schritt. Ein Schritt über
///   mehrere Jahre schließt jedes davon einzeln ab (mit derselben Messung).
public final class NatureGame {
    // MARK: Kalibrierung (erster Versuch, s. docs/nature-prototype.md)

    /// Bewässerungs-Reichweite eines Feldes (Zellen).
    public static let irrigationReach = 4.0
    /// Einzugsgebiet (Abfluss-Gewicht in Zellen), das ein Feld voll versorgt.
    public static let needArea = 700.0
    /// Kleinere Gerinne zählen erst ab diesem Gewicht (Hangrinnen sind kein
    /// Bewässerungswasser).
    public static let minSourceArea = 40.0
    /// Ab dieser Wassertiefe über dem Boden gilt eine Zelle als überflutet.
    public static let floodDepth = 0.01
    /// Eingriffsbudget in „Erdbewegung" (Σ |Δh| über alle Zellen aller
    /// Striche). Reicht für einen Durchstich des niedrigen Sattels plus den
    /// teureren hohen Sattel — aber nicht für beliebig viele Nachbesserungen.
    public static let defaultBudget = 2.5
    /// Mindestabstand eines Pinselstrichs zu Häusern und Feldern (Zellen,
    /// zusätzlich zum Pinselradius).
    public static let protectMargin = 1.5
    /// Größter erlaubter Pinselradius (Zellen) — kleine, gezielte Eingriffe.
    public static let maxBrushCells = 3.0
    /// Versuchszeitraum (Jahre): hält die Zielsiedlung so lange, ist der
    /// Versuch für Mutter Natur verloren.
    public static let trialYears = 300

    // Gegenreaktion „Ausbessern"
    /// Schlechte Jahre in Folge, ab denen die Menschen Eingriffe zurückbauen.
    public static let repairAfterBadYears = 2
    /// Reichweite der Ausbesserer um das Siedlungszentrum (Zellen). Der
    /// niedrige Sattel liegt darin, der hohe nicht.
    public static let repairReach = 24.0
    /// Höhe, die die Ausbesserer je Jahr und Zelle zurückbauen (bei voller
    /// Bevölkerung). Ein frischer Spitzhacken-Durchstich ist damit in zwei,
    /// drei Jahren zu; hat der umgeleitete Fluss ihn inzwischen tiefer
    /// gegraben, dauert es länger.
    public static let repairPerYear = 0.03
    /// Kosten des Ausbesserns (Jahresrationen je Jahr).
    public static let repairCost = 0.1
    /// Mindestbevölkerung für Ausbesserungs-Arbeit.
    public static let repairMinPopulation = 0.3

    // MARK: Zustand

    public let n: Int
    public let layouts: [SettlementLayout]
    public private(set) var settlements: [SettlementState]
    /// Versorgung je Siedlung aus der letzten Messung (nach dem letzten Schritt).
    public private(set) var lastSupply: [YearSupply]
    /// Wasser je Feldzelle (0…1) und Überflutung, letzte Messung — Anzeige.
    public private(set) var fieldWater: [[Double]]
    public private(set) var fieldFlooded: [[Bool]]
    /// Bauen die Menschen dieser Siedlung gerade zurück?
    public private(set) var repairing: [Bool]
    /// Abgeschlossene Sim-Jahre und Fortschritt im laufenden Jahr.
    public private(set) var yearsClosed = 0
    private var yearProgress = 0.0
    private var yearSums: [YearSupply]
    public private(set) var budgetUsed = 0.0
    /// Eingriffsbudget dieses Versuchs (Standard `defaultBudget`).
    public let budget: Double
    /// Gegenreaktion an/aus (nur für Vergleichsversuche).
    public let repairEnabled: Bool
    public private(set) var strokes = 0
    /// Vom Spieler veränderte Zellen → Höhe VOR dem ersten Eingriff.
    public private(set) var edits: [Int: Double] = [:]
    /// Zellen, die die Menschen im letzten Jahr zurückgebaut haben (Anzeige).
    public private(set) var lastRepairedCells: [Int] = []
    private let protected: Set<Int>
    private let protectedList: [Int]

    public init(n: Int = NatureScenario.n, layouts: [SettlementLayout] = NatureScenario.settlements(),
                budget: Double = NatureGame.defaultBudget, repairEnabled: Bool = true) {
        self.n = n
        self.budget = budget
        self.repairEnabled = repairEnabled
        self.layouts = layouts
        settlements = layouts.map { _ in SettlementState() }
        lastSupply = layouts.map { _ in YearSupply(water: 1) }
        fieldWater = layouts.map { [Double](repeating: 1, count: $0.fields.count) }
        fieldFlooded = layouts.map { [Bool](repeating: false, count: $0.fields.count) }
        repairing = layouts.map { _ in false }
        yearSums = layouts.map { _ in YearSupply(water: 0) }
        var p = Set<Int>()
        for l in layouts { p.formUnion(l.houses); p.formUnion(l.fields) }
        protected = p
        protectedList = p.sorted()
    }

    public var budgetLeft: Double { max(0, budget - budgetUsed) }
    public var targetIndex: Int? { layouts.firstIndex { $0.isTarget } }

    /// Versuchsende: Zielsiedlung verlassen (Natur gewinnt) oder
    /// Versuchszeitraum vorbei (Siedlung hat gehalten).
    public enum Outcome: Int, Sendable { case running = 0, natureWins = 1, settlementHeld = 2 }
    public var outcome: Outcome {
        if let t = targetIndex, settlements[t].isAbandoned { return .natureWins }
        if yearsClosed >= Self.trialYears { return .settlementHeld }
        return .running
    }

    // MARK: Messung

    /// Versorgung aller Siedlungen aus dem aktuellen Terrain-Zustand.
    public func measure(_ terrain: Terrain) {
        let area = terrain.area, h = terrain.h, hf = terrain.hf
        // `area` steht in Weltfläche (Zellen × cellSize²), die Schwellen hier in Zellen.
        let cell2 = max(1e-12, terrain.cfg.cellSize * terrain.cfg.cellSize)
        let r = Int(Self.irrigationReach.rounded(.up))
        let r2 = Self.irrigationReach * Self.irrigationReach
        for (s, l) in layouts.enumerated() {
            var waterSum = 0.0, flooded = 0
            for (f, k) in l.fields.enumerated() {
                let i = k % n, j = k / n
                let wet = hf[k] - h[k] > Self.floodDepth
                var best = 0.0
                for dj in -r...r {
                    for di in -r...r where Double(di * di + dj * dj) <= r2 {
                        let ii = i + di, jj = j + dj
                        guard ii >= 0, ii < n, jj >= 0, jj < n else { continue }
                        let a = area[jj * n + ii] / cell2
                        if a >= Self.minSourceArea { best = max(best, a) }
                    }
                }
                let w = wet ? 0 : min(1, best / Self.needArea)
                fieldWater[s][f] = w
                fieldFlooded[s][f] = wet
                waterSum += w
                if wet { flooded += 1 }
            }
            let housesWet = l.houses.filter { hf[$0] - h[$0] > Self.floodDepth }.count
            lastSupply[s] = YearSupply(
                water: l.fields.isEmpty ? 1 : waterSum / Double(l.fields.count),
                floodedFields: l.fields.isEmpty ? 0 : Double(flooded) / Double(l.fields.count),
                floodedHouses: l.houses.isEmpty ? 0 : Double(housesWet) / Double(l.houses.count))
        }
    }

    // MARK: Zeit

    /// Nach einem Sim-Schritt über `years` Jahre: messen, die Versorgung
    /// zeitgewichtet ins laufende Jahr buchen und jedes überschrittene Jahr
    /// abschließen. Gibt zurück, ob die Menschen das Terrain verändert haben
    /// (dann hat `advance` die Entwässerung schon nachgezogen).
    @discardableResult
    public func advance(_ terrain: Terrain, years: Double) -> Bool {
        guard years.isFinite, years > 0 else { return false }
        measure(terrain)
        return book(years: years, terrain: terrain)
    }

    /// Bucht `years` Jahre mit der zuletzt gemessenen Versorgung (`lastSupply`).
    /// Getrennt von `measure`, damit die Wächter Versorgungsverläufe ohne
    /// Terrain einspielen können.
    @discardableResult
    func book(years: Double, terrain: Terrain?) -> Bool {
        var remaining = years
        var changed = false
        // Toleranz gegen Rundung: 5 × 0,2 Jahre schließen genau ein Jahr ab.
        let eps = 1e-9
        while remaining > eps {
            let part = min(remaining, 1 - yearProgress)
            for s in yearSums.indices {
                yearSums[s].water += lastSupply[s].water * part
                yearSums[s].floodedFields += lastSupply[s].floodedFields * part
                yearSums[s].floodedHouses += lastSupply[s].floodedHouses * part
            }
            yearProgress += part
            remaining -= part
            if yearProgress >= 1 - eps {
                if closeYear(terrain) { changed = true }
                yearProgress = 0
                yearSums = layouts.map { _ in YearSupply(water: 0) }
            }
        }
        if changed, let terrain {
            terrain.recomputeFlowAfterEdit()
            measure(terrain)
        }
        return changed
    }

    private func closeYear(_ terrain: Terrain?) -> Bool {
        guard outcome == .running else {
            yearsClosed += 1
            return false
        }
        var changed = false
        lastRepairedCells = []
        for s in settlements.indices {
            settlements[s].closeYear(yearsClosed + 1, supply: yearSums[s])
            // Gegenreaktion NACH dem Jahresabschluss: wer zwei schlechte Jahre
            // in Folge hatte, schickt Leute los. Die Arbeit wirkt sofort aufs
            // Gelände, ihre Kosten gehen vom Vorrat ab.
            let st = settlements[s]
            repairing[s] = false
            guard repairEnabled, let terrain, !st.isAbandoned,
                  st.badStreak >= Self.repairAfterBadYears,
                  st.population >= Self.repairMinPopulation else { continue }
            if repair(s, terrain) {
                repairing[s] = true
                settlements[s].spend(Self.repairCost)
                changed = true
            }
        }
        yearsClosed += 1
        return changed
    }

    /// Gegenreaktion: die Menschen bauen Eingriffe des Spielers in ihrer
    /// Reichweite zurück (Durchstiche zuschütten, Dämme abtragen) — langsam,
    /// je nach Bevölkerung, und nur Zellen, die der Spieler verändert hat.
    /// Erosion, die einen Durchstich inzwischen vertieft hat, müssen sie
    /// mit abtragen; das kann länger dauern als ihre Vorräte reichen.
    private func repair(_ s: Int, _ terrain: Terrain) -> Bool {
        let l = layouts[s]
        let reach2 = Self.repairReach * Self.repairReach
        let rate = Self.repairPerYear * settlements[s].population
        var did = false
        for (k, original) in edits.sorted(by: { $0.key < $1.key }) {
            let di = Double(k % n - l.centerI), dj = Double(k / n - l.centerJ)
            guard di * di + dj * dj <= reach2 else { continue }
            let moved = terrain.restoreCell(k, toward: original, maxChange: rate)
            if moved != 0 {
                did = true
                lastRepairedCells.append(k)
            }
            if abs(terrain.h[k] - original) < 0.0005 { edits[k] = nil }
        }
        return did
    }

    // MARK: Eingriffe

    public enum BrushResult: Int, Sendable {
        case applied = 0
        case toolNotAllowed = 1
        case tooCloseToSettlement = 2
        case budgetExhausted = 3
        case trialOver = 4
    }

    /// Erlaubte Werkzeuge: Anheben, Absenken, Spitzhacke.
    public static var allowedTools: [BrushTool] { [.raise, .lower, .pickaxe] }

    /// Ein Pinselstrich des Spielers — mit Werkzeug-Liste, Schutzabstand zu
    /// Häusern/Feldern, Radius-Deckel und Budget. Der Aufrufer zieht danach
    /// wie im Sandkasten die Entwässerung nach.
    public func brush(_ tool: BrushTool, terrain: Terrain, gx: Double, gz: Double,
                      radiusWorld: Double, strength: Double) -> BrushResult {
        guard outcome == .running else { return .trialOver }
        guard Self.allowedTools.contains(tool) else { return .toolNotAllowed }
        guard budgetLeft > 0 else { return .budgetExhausted }
        let cell = terrain.cfg.cellSize
        guard cell > 0, gx.isFinite, gz.isFinite, radiusWorld.isFinite, strength.isFinite
        else { return .toolNotAllowed }
        let radius = min(radiusWorld, Self.maxBrushCells * cell)
        let rCells = radius / cell
        if isNearProtected(gx: gx, gz: gz, cells: rCells + Self.protectMargin) {
            return .tooCloseToSettlement
        }
        let r = Int(rCells.rounded(.up)) + 1
        let ci = Int(gx.rounded()), cj = Int(gz.rounded())
        var window: [(Int, Double)] = []
        for j in max(0, cj - r)...min(n - 1, cj + r) {
            for i in max(0, ci - r)...min(n - 1, ci + r) {
                window.append((j * n + i, terrain.h[j * n + i]))
            }
        }
        tool.apply(to: terrain, gx: gx, gz: gz, radiusWorld: radius,
                   strength: min(max(strength, 0), 3), target: 0)
        var cost = 0.0
        for (k, before) in window {
            let d = terrain.h[k] - before
            if d != 0 {
                cost += abs(d)
                if edits[k] == nil { edits[k] = before }
            }
        }
        budgetUsed += cost
        strokes += 1
        return .applied
    }

    func isNearProtected(gx: Double, gz: Double, cells: Double) -> Bool {
        let c2 = cells * cells
        for k in protectedList {
            let di = Double(k % n) - gx, dj = Double(k / n) - gz
            if di * di + dj * dj <= c2 { return true }
        }
        return false
    }

    /// Ist die Zelle Haus oder Feld?
    public func isProtected(_ k: Int) -> Bool { protected.contains(k) }

    // MARK: Test-Haken

    /// Setzt die Messung von Hand (Wächter ohne Terrain).
    func setSupplyForTests(_ supply: [YearSupply]) { lastSupply = supply }
}

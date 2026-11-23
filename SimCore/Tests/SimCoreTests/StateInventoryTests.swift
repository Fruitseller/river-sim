import XCTest
@testable import SimCore

final class StateInventoryTests: XCTestCase {

    enum Storage {
        case persistent(Persistence)
        case derived(reason: String, clearedOnRestore: Bool)
        case scratch(reason: String)

        enum Persistence {
            case sameName
            case fields([String])
            case outsideInventory(reason: String)
        }
    }

    static let classification: [(name: String, storage: Storage)] = [
        ("cfg", .persistent(.outsideInventory(reason:
            "Die Config ist kein Zustandsfeld, sondern reist als eigener "
            + "Plist-Block im Schnappschuss (s. WorldSnapshot: Datei-Config ist "
            + "autoritativ). Ihre Vollständigkeit sichert der Codable-Round-Trip "
            + "in WorldSnapshotTests, nicht das Inventar."))),
        ("n", .derived(reason: "cfg.n — `init(allocating:)` setzt es aus der "
            + "Datei-Config, bevor irgendein Feld gelesen wird.",
            clearedOnRestore: false)),

        ("h", .persistent(.sameName)),
        ("rock", .persistent(.sameName)),
        ("sed", .persistent(.sameName)),
        ("upliftBase", .persistent(.sameName)),
        ("rain", .persistent(.sameName)),
        ("rainWeight", .persistent(.sameName)),
        ("runoffWeight", .derived(reason:
            "Reine Ableitung aus `rain`, `temperature` und `snow` — alle drei "
            + "reisen mit — und `computeRain` (`updateRunoffWeight`) baut sie neu, "
            + "bevor irgendein Konsument sie liest: der erste Pass jedes `step()` "
            + "und jedes `computeFlow`. Damit erfüllt sie das Aufnahmekriterium "
            + "nicht (kein Pass liest sie, bevor er sie schreibt; Rendering und "
            + "Diagnose fragen sie nach dem Laden nicht ab), und eine Aufnahme "
            + "hätte die Formatversion auf 4 gehoben, ohne dass ein geladener "
            + "Zustand dadurch korrekter wäre. Dass `rainWeight` trotzdem "
            + "mitreist, ist die bewusste Großzügigkeit von Issue #8. "
            + "Kein Handgriff beim Zurückspielen nötig: `updateRunoffWeight` "
            + "LEERT das Feld selbst, sobald die Welt nichts zu schmelzen hat.",
            clearedOnRestore: false)),
        ("lithHardness", .persistent(.sameName)),
        ("lithErodeK", .persistent(.sameName)),
        ("lithBed", .persistent(.sameName)),
        ("lithProvince", .persistent(.sameName)),
        ("temperature", .persistent(.sameName)),
        ("snow", .persistent(.sameName)),
        ("ice", .persistent(.sameName)),
        ("underIce", .derived(reason:
            "Reine Ableitung aus `ice` (Schwelle `cfg.iceMinThickness`, Issue "
            + "#35): `updateIce` baut die Maske je Schritt neu, und zwar VOR "
            + "jedem Konsumenten. Sie wird beim Zurückspielen trotzdem von Hand "
            + "geleert — sonst gatete die Maske eines FREMDEN Terrains den "
            + "fluvialen Abtrag, bis der erste `updateIce` läuft.",
            clearedOnRestore: true)),
        ("iceRate", .scratch(reason:
            "Arbeitspuffer des Eistransports (Zwei-Phasen-Scratch, s. "
            + "`iceFlowSubStep`): Ausstrom je Einheit Oberflächen-Abfall.")),
        ("iceSurf", .scratch(reason:
            "Arbeitspuffer des Eistransports: die eingefrorene Eis-Oberfläche "
            + "des Teilschritts.")),
        ("iceEroH", .scratch(reason:
            "Arbeitspuffer des Eistransports: Zeilen-Kastensummen der glazialen "
            + "Erosionsrate (erste Hälfte der Schleifspur), je Teilschritt neu.")),
        ("iceAvTarget", .scratch(reason:
            "Arbeitspuffer des Lawinen-Abgangs (`iceAvalancheMap`): Ziel-Zelle je "
            + "Quellzelle, wird je `updateIce` im Arbeitsfenster neu geschrieben.")),
        ("iceAvFeed", .scratch(reason:
            "Arbeitspuffer des Lawinen-Abgangs: Netto-Änderung der Firn-Zufuhr "
            + "je Zelle in einem Teilschritt; außerhalb der Lawinenliste 0 und "
            + "am Ende jedes `updateIce` dorthin zurückgesetzt.")),
        ("iceAvPhi", .scratch(reason:
            "Arbeitspuffer des Lawinen-Abgangs: abgehender Anteil je Quellzelle, "
            + "wird mit `iceAvTarget` je Karte neu geschrieben und nur dort gelesen, "
            + "wo `iceAvTarget` ein Ziel trägt.")),
        ("iceEro", .scratch(reason:
            "Arbeitspuffer des Eistransports: lokale glaziale Erosionsrate, die "
            + "Pass 2 über die Schleifspur mittelt.")),
        ("veg", .persistent(.sameName)),
        ("vegClass", .persistent(.sameName)),
        ("riparian", .persistent(.sameName)),
        ("vegScratch", .scratch(reason:
            "Pingpong-Puffer der Riparian-Dilatation, je Aufruf neu gefüllt.")),
        ("vegScratchRow", .scratch(reason:
            "Zwischenstufe des separablen Samen-Druck-Maximums in "
            + "`updateVegetation`.")),
        ("vegTypeFactor", .derived(reason:
            "Aus der Config gebaut (`vegTypeFactorForest`/`Riparian`), fix je "
            + "Terrain — `init(allocating:)` legt sie an.",
            clearedOnRestore: false)),
        ("heightBands", .persistent(.sameName)),

        ("hf", .persistent(.sameName)),
        ("waterLevel", .persistent(.sameName)),
        ("lakeBalance", .persistent(.sameName)),
        ("endorheicBasin", .persistent(.sameName)),
        ("saltCrust", .persistent(.sameName)),
        ("endorheicInflow", .persistent(.sameName)),
        ("playaBed", .persistent(.sameName)),
        ("basinSeen", .scratch(reason:
            "Arbeitspuffer der Becken-Komponentensuche.")),
        ("basinCells", .scratch(reason:
            "Zellen des aktuellen Beckens (Bilanz-Sortierung), je Becken neu.")),
        ("basinSlots", .scratch(reason:
            "Plätze der Beckenzellen in `order` (lokale Umsortierung).")),
        ("orderPos", .scratch(reason:
            "Umkehrabbildung zu `order`, nur beim Deckeln gefüllt.")),
        ("receiver", .persistent(.sameName)),
        ("area", .persistent(.sameName)),
        ("areaMFD", .persistent(.sameName)),
        ("order", .persistent(.sameName)),
        ("floodParent", .persistent(.sameName)),
        ("heap", .scratch(reason:
            "Halde des Priority-Flood, je Lauf neu befüllt.")),
        ("visited", .scratch(reason:
            "Besuchsmarken des Priority-Flood, je Lauf neu gesetzt.")),
        ("scratch", .scratch(reason:
            "Arbeitspuffer der Hangdiffusion — der Pass schreibt jede Zelle, "
            + "bevor er sie liest.")),
        ("areaPow", .scratch(reason:
            "`A^m` je Zelle für `outletIncision`, je Aufruf neu gerechnet.")),
        ("incisionGate", .scratch(reason:
            "Gate-Status der Auslass-Inzision (Runde 7), je Aufruf vollständig "
            + "neu gesetzt, bevor die serielle Schleife ihn liest.")),
        ("incisionKErode", .scratch(reason:
            "Erosionsfaktor je Zelle für `outletIncision` (Runde 7), je Aufruf "
            + "neu gerechnet, bevor die serielle Schleife ihn liest.")),
        ("braidStatus", .scratch(reason:
            "Braid-Gate je Zelle (Runde 7), vor dem seriellen Lauf des Passes "
            + "vollständig neu gesetzt.")),
        ("carveStatus", .scratch(reason:
            "Vorfilter des `channelCarve` (Runde 7) — `area` und `inBelt` ändern "
            + "sich im Pass nicht; der Puffer wird je Aufruf neu gesetzt.")),
        ("mfdRoutes", .scratch(reason:
            "MFD-Nachbargewichte, vor jeder Akkumulation vollständig neu vorbereitet.")),
        ("mfdRouteCounts", .scratch(reason:
            "Route-Klassifikation des MFD-Passes (Runde 7), mit den Routen zusammen "
            + "vor jedem Lesen vollständig neu gesetzt.")),
        ("mfdDispersed", .scratch(reason:
            "Disbursive MFD-Gewichte (Runde 7) — wird nur für canDisperse-Zellen "
            + "geschrieben und nur nach frischem `mfdRouteCounts`-Flag gelesen.")),
        ("qs", .scratch(reason:
            "Sedimentfracht in Transit (`transportLimited`, Testpfad) — der Pass "
            + "beschreibt sie in Empfänger-Reihenfolge, bevor er sie liest.")),
        ("isChannel", .persistent(.sameName)),
        ("barAge", .persistent(.sameName)),
        ("inBelt", .scratch(reason:
            "Maske der Zellen, deren Sohle der Gürtel-Stempel in diesem Schritt "
            + "setzt (Issue #174); `meanderBeltStep` leert sie zu Beginn jedes "
            + "Schritts, bevor `channelCarve` sie liest.")),
        ("beltSubsteps", .derived(reason:
            "Teilschritt-Zahl des letzten Gürtel-Schritts — reine Diagnose, kein "
            + "Pass liest sie.",
            clearedOnRestore: false)),
        ("streamMap", .persistent(.sameName)),
        ("streamRate", .persistent(.sameName)),
        ("trackBuf", .scratch(reason:
            "Tropfen-Besuchszahl je Zelle, je Schritt neu gezählt.")),
        ("depositDampBuf", .scratch(reason:
            "Faktor der Tropfen-Deposition je Zelle (Issue #108) — `buildDepositDamp` "
            + "leitet ihn je Schritt vollständig aus `area`/Config ab, direkt vor dem "
            + "einzigen Leser (`Hydraulic.erode`).")),
        ("deltaMouthCells", .scratch(reason:
            "Mündungsliste des laufenden Schritts (`deltaHeightSum`, Issue #174), "
            + "vor `deltaDeposit` je Schritt neu aus dem Flussnetz gesammelt.")),
        ("dropletGateBuf", .scratch(reason:
            "Sperrmaske der Tropfen (Eis oder Gürtelbett, Issue #174) — "
            + "`beltDropletGate` füllt sie je Schritt vollständig aus `underIce`/`inBelt`, "
            + "direkt vor dem einzigen Leser (`Hydraulic.erode`).")),
        ("pondSeen", .scratch(reason:
            "Arbeitspuffer der Pfützen-Komponentensuche.")),
        ("segOwner", .scratch(reason:
            "Zuordnung Zelle → D8-Abschnitt der Gürtel-Kopplung (Issue #187) — "
            + "`coupleBeltToDrainage` setzt sie je Schritt aus dem frischen Abflussfeld "
            + "und räumt sie am Ende des Passes wieder auf −1.")),
        ("segPos", .scratch(reason:
            "Position der Zelle in ihrem D8-Abschnitt, wie `segOwner`.")),
        ("beltCouplingLog", .scratch(reason:
            "Diagnose-Haken der Kopplung (nur Tests), kein Zustand.")),
        ("noise", .derived(reason:
            "Permutationstabelle, rein aus `seed` rekonstruiert — `restore` baut "
            + "sie mit `SimplexNoise(seed:)` neu auf, statt sie zu speichern.",
            clearedOnRestore: false)),

        ("disturb", .persistent(.sameName)),
        ("regenPending", .persistent(.sameName)),
        ("disturbActive", .persistent(.sameName)),

        ("meander", .persistent(.fields(["meanderChannels", "oxbows", "oxbowAge"]))),

        ("years", .persistent(.sameName)),
        ("seed", .persistent(.sameName)),
        ("flowStepCount", .persistent(.sameName)),
        ("dropsEmitted", .persistent(.sameName)),
        ("dropCarry", .persistent(.sameName)),
        ("beltCouplingCarry", .persistent(.sameName)),

        ("mfdMinA", .derived(reason:
            "Aus der Config vorgerechnet: `braidMinCells · cellSize²`.",
            clearedOnRestore: false)),
        ("mfdFlatCell", .derived(reason:
            "Aus der Config vorgerechnet: `meanderFlatSlope · cellSize`.",
            clearedOnRestore: false)),
    ]

    private func makeTerrain() -> Terrain {
        var c = SimConfig()
        c.n = 32; c.world = calibrationWorld
        return Terrain(allocating: c, seed: 1)
    }

    private static var byName: [String: Storage] {
        Dictionary(classification.map { ($0.name, $0.storage) },
                   uniquingKeysWith: { a, _ in a })
    }

    private static func claimedInventoryFields(_ entry: (name: String, storage: Storage))
        -> [String] {
        guard case let .persistent(p) = entry.storage else { return [] }
        switch p {
        case .sameName: return [entry.name]
        case let .fields(names): return names
        case .outsideInventory: return []
        }
    }

    func testEveryStoredPropertyOfTerrainIsClassified() {
        let table = Self.byName
        XCTAssertEqual(table.count, Self.classification.count,
                       "Doppelter Name in der Einordnung")

        let mirrored = Mirror(reflecting: makeTerrain()).children.compactMap(\.label)
        for name in mirrored {
            XCTAssertNotNil(table[name],
                            "Terrain.\(name) ist nirgends einsortiert — die "
                            + "Eigenschaft wäre für Fingerprint und Spielstand "
                            + "unsichtbar. In StateInventoryTests.classification "
                            + "eintragen: persistent (ins Inventar TerrainState "
                            + "aufnehmen), abgeleitet oder Scratch (jeweils mit "
                            + "Begründung).")
        }
        let live = Set(mirrored)
        for entry in Self.classification {
            XCTAssertTrue(live.contains(entry.name),
                          "Die Einordnung führt Terrain.\(entry.name), die "
                          + "Eigenschaft gibt es nicht mehr — Eintrag entfernen, "
                          + "sonst deckt die Tabelle einen Bestand von gestern.")
        }
    }

    func testEveryExclusionCarriesItsReason() {
        for entry in Self.classification {
            let reason: String?
            switch entry.storage {
            case let .persistent(.outsideInventory(r)): reason = r
            case .persistent: reason = nil
            case let .derived(r, _): reason = r
            case let .scratch(r): reason = r
            }
            guard let reason else { continue }
            XCTAssertGreaterThan(reason.count, 30,
                                 "Terrain.\(entry.name) steht ohne tragfähige "
                                 + "Begründung außerhalb des Inventars")
        }
    }

    func testPersistentPropertiesAndInventoryFieldsMatch() {
        let inventory = Set(Mirror(reflecting: TerrainState()).children.compactMap(\.label))
        var claimed: [String] = []
        for entry in Self.classification {
            for field in Self.claimedInventoryFields(entry) {
                claimed.append(field)
                XCTAssertTrue(inventory.contains(field),
                              "Terrain.\(entry.name) ist als persistent "
                              + "eingeordnet, aber TerrainState hat kein Feld "
                              + "`\(field)` — der Zustand ginge beim Speichern "
                              + "verloren.")
            }
        }
        let claimedSet = Set(claimed)
        XCTAssertEqual(claimed.count, claimedSet.count,
                       "Zwei Einordnungen beanspruchen dasselbe Inventar-Feld")
        for field in inventory {
            XCTAssertTrue(claimedSet.contains(field),
                          "TerrainState.\(field) hat keine Quelle in der "
                          + "Einordnung von Terrain — entweder fehlt die "
                          + "Eigenschaft oder das Inventar-Feld ist verwaist.")
        }
    }

    func testDerivedFieldsAreClearedByTheRestorePath() throws {
        let expected = Set(Self.classification.compactMap { entry -> String? in
            guard case let .derived(_, cleared) = entry.storage, cleared else { return nil }
            return entry.name
        })

        let body = try restoreBody()
        for name in expected {
            XCTAssertTrue(body.contains("\(name) = []"),
                          "Terrain.restore leert `\(name)` nicht — nach dem Laden "
                          + "stünde dort die Ableitung des VORHERIGEN Terrains, "
                          + "bis der zuständige Pass sie neu baut.")
        }
        let cleared = try SourceProbe(body, language: .swift)
            .captures(pattern: "([A-Za-z_][A-Za-z0-9_]*) = \\[\\]")
        for name in cleared {
            XCTAssertTrue(expected.contains(name),
                          "Terrain.restore leert `\(name)` von Hand, die "
                          + "Einordnung führt das Feld aber nicht als "
                          + "`clearedOnRestore` — die Begründung dafür gehört in "
                          + "StateInventoryTests.classification.")
        }

        let snapshot = try RepoSource.probe("SimCore/Sources/SimCore/WorldSnapshot.swift")
        assertContains(snapshot, "Terrain(allocating: config, seed: state.seed)",
                       hint: "WorldSnapshot.decode legt das Terrain nicht mehr "
                       + "leer an — die Einordnung beschreibt einen anderen Weg")
        assertContains(snapshot, "terrain.restore(state)",
                       hint: "WorldSnapshot.decode spielt den Zustand nicht mehr "
                       + "über Terrain.restore zurück")
    }

    private func restoreBody() throws -> String {
        let probe = try RepoSource.probe("SimCore/Sources/SimCore/Terrain.swift")
        let lines = probe.code.components(separatedBy: "\n")
        struct NotFound: Error {}
        guard let start = lines.firstIndex(where: {
            $0.contains("func restore(_ s: TerrainState)")
        }) else {
            XCTFail("Terrain.restore(_:) nicht gefunden — Zurückspiel-Logik "
                    + "umbenannt? Der Wächter prüft sonst nichts.")
            throw NotFound()
        }
        let rest = lines[(start + 1)...]
        guard let end = rest.firstIndex(where: { $0 == "    }" }) else {
            XCTFail("Ende von Terrain.restore(_:) nicht gefunden (Marker "
                    + "„    }\") — der Wächter prüfte sonst ein falsches "
                    + "Intervall.")
            throw NotFound()
        }
        return rest[..<end].joined(separator: "\n")
    }
}

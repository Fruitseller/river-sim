import XCTest
@testable import SimCore

/// **Vollständigkeits-Wächter der Sprosse ÜBER dem Inventar** (Issue #98).
///
/// Seit Issue #78 ist geprüft, dass Fingerabdruck und Speicherformat jedes Feld
/// des Inventars (`TerrainState`) sehen. Der Schritt DAVOR — von der Klasse
/// `Terrain` ins Inventar — war ungeprüft: eine neue gespeicherte Eigenschaft,
/// die nie ins Inventar kommt, ist für `fingerprint()` UND für den Spielstand
/// unsichtbar, ohne dass ein Test fällt. Das ist dieselbe Lücke wie #78, eine
/// Ebene höher.
///
/// Dieser Wächter spiegelt `Terrain` und verlangt für JEDE gespeicherte
/// Eigenschaft eine Einordnung in der Tabelle unten — persistent, abgeleitet
/// oder Scratch. Eine nirgends einsortierte Eigenschaft macht ihn rot.
///
/// **Die Tabelle ist zugleich die eine Stelle, an der die Ausschluss-
/// Begründungen stehen.** Vorher lagen sie verteilt: teils am Feld in
/// `Terrain.swift`, teils als Hand-Liste in der Doku von `TerrainState`. Eine
/// verteilte Begründung driftet stumm; hier fällt sie mit dem Feld zusammen um.
///
/// Aufnahmekriterium des Inventars (unverändert, s. `TerrainState`): jedes Feld,
/// das ein `step()` LIEST, bevor es es schreibt, plus alles, was
/// Rendering/Diagnose sofort nach dem Laden brauchen. Bewusst großzügig — auch
/// je Schritt neu abgeleitete Felder reisen mit, damit „geladener Zustand ==
/// gespeicherter Zustand" feldweise prüfbar ist.
///
/// Die Asymmetrie beim ZURÜCKSPIELEN, die vom Inventar aus nicht sichtbar ist:
/// abgeleitete Felder stehen zwar nicht im Inventar, dürfen nach dem Laden aber
/// auch nicht mit dem Inhalt eines fremden Terrains stehen bleiben. Wer von Hand
/// geleert werden muss, ist an der Einordnung ablesbar
/// (`clearedOnRestore`) und wird gegen die echte Zurückspiel-Logik geprüft
/// (`testDerivedFieldsAreClearedByTheRestorePath`).
final class StateInventoryTests: XCTestCase {

    // MARK: - Die Einordnung

    /// Rolle einer gespeicherten Eigenschaft von `Terrain`.
    enum Storage {
        /// **persistent** — reist im Spielstand mit.
        case persistent(Persistence)
        /// **abgeleitet** — bewusst NICHT im Inventar, weil ein Pass die
        /// Eigenschaft neu ableitet, bevor irgendein Konsument sie liest.
        /// `clearedOnRestore`: muss `restore` sie zusätzlich von Hand leeren?
        case derived(reason: String, clearedOnRestore: Bool)
        /// **Scratch** — reiner Arbeitspuffer, den sein Pass vor dem ersten
        /// Lesen vollständig überschreibt.
        case scratch(reason: String)

        /// Auf welchem Weg eine persistente Eigenschaft mitreist.
        enum Persistence {
            /// Gleichnamiges Feld im Inventar `TerrainState`.
            case sameName
            /// Fächert im Inventar in mehrere Felder auf.
            case fields([String])
            /// Reist im Schnappschuss, aber außerhalb des Inventars — mit
            /// Begründung, denn das ist die Ausnahme.
            case outsideInventory(reason: String)
        }
    }

    /// **Die Einordnung.** Reihenfolge wie die Deklarationen in `Terrain.swift`,
    /// damit sich beides nebeneinander lesen lässt.
    static let classification: [(name: String, storage: Storage)] = [
        ("cfg", .persistent(.outsideInventory(reason:
            "Die Config ist kein Zustandsfeld, sondern reist als eigener "
            + "Plist-Block im Schnappschuss (s. WorldSnapshot: Datei-Config ist "
            + "autoritativ). Ihre Vollständigkeit sichert der Codable-Round-Trip "
            + "in WorldSnapshotTests, nicht das Inventar."))),
        ("n", .derived(reason: "cfg.n — `init(allocating:)` setzt es aus der "
            + "Datei-Config, bevor irgendein Feld gelesen wird.",
            clearedOnRestore: false)),

        // Kernfelder
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

        // Entwässerung
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
        ("qs", .scratch(reason:
            "Sedimentfracht in Transit (`transportLimited`, Testpfad) — der Pass "
            + "beschreibt sie in Empfänger-Reihenfolge, bevor er sie liest.")),
        ("isChannel", .persistent(.sameName)),
        ("streamMap", .persistent(.sameName)),
        ("streamRate", .persistent(.sameName)),
        ("trackBuf", .scratch(reason:
            "Tropfen-Besuchszahl je Zelle, je Schritt neu gezählt.")),
        ("pondSeen", .scratch(reason:
            "Arbeitspuffer der Pfützen-Komponentensuche.")),
        ("noise", .derived(reason:
            "Permutationstabelle, rein aus `seed` rekonstruiert — `restore` baut "
            + "sie mit `SimplexNoise(seed:)` neu auf, statt sie zu speichern.",
            clearedOnRestore: false)),

        // Störung / Regeneration (Issue #26)
        ("disturb", .persistent(.sameName)),
        ("regenPending", .persistent(.sameName)),
        ("disturbActive", .persistent(.sameName)),

        // Mäander (Issue #7)
        ("meander", .persistent(.fields(["meanderChannels", "oxbows", "oxbowAge"]))),

        // Zähler
        ("years", .persistent(.sameName)),
        ("seed", .persistent(.sameName)),
        ("flowStepCount", .persistent(.sameName)),
        ("dropsEmitted", .persistent(.sameName)),
        ("dropCarry", .persistent(.sameName)),

        // Aus der Config vorgerechnet (Hot-Loops)
        ("mfdMinA", .derived(reason:
            "Aus der Config vorgerechnet: `braidMinCells · cellSize²`.",
            clearedOnRestore: false)),
        ("mfdFlatCell", .derived(reason:
            "Aus der Config vorgerechnet: `meanderFlatSlope · cellSize`.",
            clearedOnRestore: false)),
    ]

    // MARK: - Helfer

    /// Ein Terrain, das nur seine Puffer anlegt (kein `generate`) — für den
    /// Spiegel genügt das, und der Test bleibt billig.
    private func makeTerrain() -> Terrain {
        var c = SimConfig()
        c.n = 32; c.world = calibrationWorld
        return Terrain(allocating: c, seed: 1)
    }

    private static var byName: [String: Storage] {
        Dictionary(classification.map { ($0.name, $0.storage) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// Die Inventar-Felder, die eine Einordnung für sich beansprucht.
    private static func claimedInventoryFields(_ entry: (name: String, storage: Storage))
        -> [String] {
        guard case let .persistent(p) = entry.storage else { return [] }
        switch p {
        case .sameName: return [entry.name]
        case let .fields(names): return names
        case .outsideInventory: return []
        }
    }

    // MARK: - Die Wächter

    /// JEDE gespeicherte Eigenschaft von `Terrain` ist eingeordnet — und jede
    /// Einordnung betrifft eine Eigenschaft, die es noch gibt.
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

    /// Ein Ausschluss ohne Begründung ist eine Behauptung: `abgeleitet` und
    /// `Scratch` (und der Sonderweg an der Config) tragen ihre Begründung an der
    /// Einordnung, nicht verstreut an den Feldern.
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

    /// Beide Richtungen zwischen Einordnung und Inventar: was als persistent
    /// eingeordnet ist, hat ein Feld in `TerrainState` — und jedes Feld des
    /// Inventars hat eine Quelle in `Terrain`. Sonst führte das Inventar ein
    /// Feld, das kein Pass mehr füllt.
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

    /// Die Asymmetrie beim Zurückspielen, gegen die echte Logik geprüft: genau
    /// die als `clearedOnRestore` eingeordneten Felder werden in `restore` von
    /// Hand geleert — keines mehr, keines weniger.
    ///
    /// Quelltext-Wächter, weil es um die ABWESENHEIT eines Handgriffs geht: ein
    /// Verhaltenstest sähe nichts, solange `restore` auf einem frisch
    /// angelegten Terrain läuft (dort sind die Felder ohnehin leer) — genau der
    /// Weg, den `WorldSnapshot.decode` nimmt.
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

        // Und `restore` ist wirklich der Weg, den ein geladener Spielstand
        // nimmt: sonst prüfte der Wächter oben eine tote Funktion.
        let snapshot = try RepoSource.probe("SimCore/Sources/SimCore/WorldSnapshot.swift")
        assertContains(snapshot, "Terrain(allocating: config, seed: state.seed)",
                       hint: "WorldSnapshot.decode legt das Terrain nicht mehr "
                       + "leer an — die Einordnung beschreibt einen anderen Weg")
        assertContains(snapshot, "terrain.restore(state)",
                       hint: "WorldSnapshot.decode spielt den Zustand nicht mehr "
                       + "über Terrain.restore zurück")
    }

    /// Körper von `Terrain.restore(_:)` in der Code-Sicht (ohne Kommentare —
    /// eine auskommentierte Leerung leert nichts).
    private func restoreBody() throws -> String {
        let probe = try RepoSource.probe("SimCore/Sources/SimCore/Terrain.swift")
        let lines = probe.code.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.contains("func restore(_ s: TerrainState)")
        }) else {
            XCTFail("Terrain.restore(_:) nicht gefunden — Zurückspiel-Logik "
                    + "umbenannt? Der Wächter prüft sonst nichts.")
            struct NotFound: Error {}
            throw NotFound()
        }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(where: { $0 == "    }" }) ?? rest.endIndex
        return rest[..<end].joined(separator: "\n")
    }
}

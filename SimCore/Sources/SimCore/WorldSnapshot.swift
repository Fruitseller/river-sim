import Foundation

/// **Welt-Speicherformat** (Issue #8). Schreibt und liest den vollständigen
/// Sim-Zustand (`TerrainState`, Inventar in `Terrain.swift`) plus Seed und
/// Config in EINE versionierte Datei.
///
/// ## Warum ein eigenes Binärformat
///
/// Der Zustand besteht aus ~25 Feldern à n² `Double` (n = 832 → 692 224 Zellen,
/// 5,5 MB je Feld; eine Welt ≈ 109 MB, gemessen 166 Byte/Zelle). Zwei harte
/// Anforderungen bestimmen die Kodierung:
///
/// 1. **Bit-Genauigkeit.** Die Abnahme-Invariante ist Determinismus: ein
///    geladener Zustand muss bit-identisch weiterlaufen. Ein einzelnes
///    verlorenes ULP divergiert über das chaotische System messbar (dieselbe
///    Erfahrung wie bei `powFast`). Gespeichert wird deshalb das
///    IEEE-754-Bitmuster jedes `Double`, nicht seine Dezimaldarstellung.
/// 2. **Größe/Zeit.** JSON braucht für dieselben Zahlen ~3× so viele Bytes und
///    einen Parser je Zahl (109 MB → ~350 MB Text). Plist-XML
///    genauso. Binäres Plist wäre bit-genau, verpackt aber jedes Element als
///    eigenes Objekt — für 17 Mio. Zahlen unbrauchbar.
///
/// Deshalb: roher Block-Transfer der Zahlenfelder (`memcpy`-Tempo,
/// Little-Endian) in einem selbstbeschreibenden Container. Die **Config** ist
/// dagegen klein und ändert ihre Felder häufig — sie liegt als **binäres Plist**
/// (Codable-synthetisiert, `Double` exakt als 8 Byte) im Container. So muss
/// niemand beim Hinzufügen einer Stellschraube in `Config.swift` daran denken,
/// den Serialisierer nachzuziehen; eine fehlende Stellschraube in einer alten
/// Datei ist ein harter Dekodier-Fehler statt eines stillen Default-Werts.
///
/// ## Aufbau
///
/// ```text
/// Kopf (28 Byte, ungeprüft lesbar — für die Versionsprüfung ohne Vollladen):
///   [0..8)   Magic "RIVERSIM" (ASCII)
///   [8..12)  u32 Formatversion
///   [12..20) u64 Länge der Nutzdaten
///   [20..28) u64 FNV-1a-64 der Nutzdaten
/// Nutzdaten:
///   u32 Länge + Bytes  binäres Plist der SimConfig
///   u32 seed · f64 years · u64 dropsEmitted · f64 dropCarry
///   u32 flowStepCount · u8 disturbActive
///   8 × f64            Höhenbänder (Issue #4)
///   u32 Feldzahl, je Feld:
///     u32 Länge + Name (ASCII) · u8 Typ (0 f64 · 1 i32 · 2 u8 · 3 bool)
///     u8 Kodierung (0 roh · 1 konstant) · u32 Elementzahl · Nutzdaten
///   u32 Kanalzahl, je Kanal: u32 Knotenzahl · Knoten (f64 x, f64 z) · f64 Abfluss
///   u32 Altarmzahl, je Altarm: u32 Knotenzahl · Knoten; danach f64 Alter je Altarm
/// ```
///
/// Der Kopf trägt Länge UND Prüfsumme der Nutzdaten: eine abgebrochene
/// Speicherung (Absturz, volle Platte) fällt beim Laden auf, statt als Welt mit
/// Müll-Feldern durchzugehen. Die **Version wird VOR der Prüfsumme geprüft**,
/// damit eine Datei aus einer älteren Version die Meldung „falsche Version"
/// bekommt und nicht „defekt".
///
/// Feldnamen reisen mit: Umbenennen/Umsortieren im Inventar ist damit ein
/// erkennbarer Fehler und kein stiller Feldversatz.
///
/// ## Config-Abweichung (Abnahmepunkt 4)
///
/// Die Datei-Config ist **autoritativ** — eine geladene Welt läuft mit exakt der
/// Config, mit der sie gespeichert wurde, auch wenn der Programm-Default sich
/// seither geändert hat. Begründung: Feldlängen (`n`), Kalibrierung und
/// Bit-Determinismus hängen zusammen; ein Mischen aus Datei- und
/// Programm-Config wäre eine dritte, nirgends getestete Konfiguration. Wer eine
/// alte Welt mit neuer Physik weiterlaufen lassen will, braucht dafür eine
/// bewusste Migration, keinen stillen Merge. Folge: Änderungen an
/// `SimConfig()`-Defaults wirken nur auf NEUE Welten.
public enum WorldSnapshot {
    /// Erkennungsmarke am Dateianfang.
    public static let magic: [UInt8] = Array("RIVERSIM".utf8)

    /// **Formatversion.** Bei jeder Änderung an Inventar, Reihenfolge oder
    /// Kodierung um 1 erhöhen — alte Dateien werden dann abgelehnt (es gibt
    /// bewusst keine Aufwärts-Migration, s. Typ-Doku).
    public static let version: UInt32 = 2

    /// Übliche Dateiendung („river-sim world").
    public static let fileExtension = "rsworld"

    private static let headerLength = 28

    /// Little-Endian ist Teil des Formats: die Zahlenfelder werden als Block
    /// kopiert (bei 17 Mio. Werten ist elementweises Byte-Swapping kein
    /// Nebeneffekt mehr, sondern die Laufzeit). Alle Zielplattformen (x86_64,
    /// arm64) sind LE; auf einer Big-Endian-Maschine bricht der Zugriff
    /// kontrolliert ab, statt Müll zu schreiben.
    private static var hostIsLittleEndian: Bool { UInt32(1).littleEndian == 1 }

    // MARK: - Datei-Ebene

    /// Schreibt die Welt **atomar** nach `path` (Foundation legt eine temporäre
    /// Datei daneben und ersetzt das Ziel per `rename`): ein Absturz mitten im
    /// Schreiben lässt den vorherigen Spielstand intakt, statt ihn zu
    /// halbieren. Fehlende Ordner werden angelegt. Rückgabe: Dateigröße in Byte.
    @discardableResult
    public static func write(_ terrain: Terrain, to path: String) throws -> Int {
        let data = try encode(terrain)
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        if !dir.path.isEmpty {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw SnapshotError.writeFailed(path: path, reason: error.localizedDescription)
        }
        return data.count
    }

    /// Lädt eine Welt aus `path`. Wirft `SnapshotError` mit deutscher
    /// Beschreibung — insbesondere `unsupportedVersion` für Dateien aus einer
    /// anderen Formatversion.
    public static func read(from path: String) throws -> Terrain {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw SnapshotError.readFailed(path: path, reason: error.localizedDescription)
        }
        return try decode(data)
    }

    /// Liest NUR den Kopf (28 Byte) und gibt die Formatversion zurück — für eine
    /// Vorprüfung, ohne über 100 MB zu laden.
    public static func peekVersion(at path: String) throws -> UInt32 {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw SnapshotError.readFailed(path: path, reason: "Datei nicht lesbar")
        }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: headerLength)
        var reader = ByteReader(head)
        return try readHeader(&reader).version
    }

    /// Liest Kopf + Config-Block, aber KEINE Felder. Damit kann ein Frontend vor
    /// dem Laden entscheiden, ob es diese Welt darstellen kann (die
    /// Render-Pipeline steht je Sitzung auf einem festen `n`).
    public static func peekConfig(at path: String) throws -> SimConfig {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw SnapshotError.readFailed(path: path, reason: "Datei nicht lesbar")
        }
        defer { try? handle.close() }
        var head = ByteReader(handle.readData(ofLength: headerLength + 4))
        _ = try readHeader(&head)
        let length = Int(try head.u32())
        let blob = handle.readData(ofLength: length)
        guard blob.count == length else {
            throw SnapshotError.truncated(expected: headerLength + 4 + length,
                                          found: headerLength + 4 + blob.count)
        }
        do {
            return try PropertyListDecoder().decode(SimConfig.self, from: blob)
        } catch {
            throw SnapshotError.configDecodingFailed(reason: "\(error)")
        }
    }

    // MARK: - Kodieren

    public static func encode(_ terrain: Terrain) throws -> Data {
        guard hostIsLittleEndian else { throw SnapshotError.unsupportedHostByteOrder }
        let state = terrain.state
        var body = ByteWriter()

        let configData: Data
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            configData = try encoder.encode(terrain.cfg)
        } catch {
            throw SnapshotError.configEncodingFailed(reason: error.localizedDescription)
        }
        body.blob(configData)

        body.u32(state.seed)
        body.f64(state.years)
        body.u64(state.dropsEmitted)
        body.f64(state.dropCarry)
        body.u32(state.flowStepCount)
        body.u8(state.disturbActive ? 1 : 0)

        let b = state.heightBands
        for v in [b.vegFull, b.vegRamp, b.rockStart, b.rockFull,
                  b.snowStart, b.snowFull, b.coniferLow, b.coniferHigh] { body.f64(v) }

        body.u32(UInt32(doubleFields.count + int32Fields.count
                        + uint8Fields.count + boolFields.count))
        for f in doubleFields { body.field(f.name, kind: .f64, values: state[keyPath: f.path]) }
        for f in int32Fields { body.field(f.name, kind: .i32, values: state[keyPath: f.path]) }
        for f in uint8Fields { body.field(f.name, kind: .u8, values: state[keyPath: f.path]) }
        for f in boolFields {
            body.field(f.name, kind: .bool,
                       values: state[keyPath: f.path].map { $0 ? UInt8(1) : UInt8(0) })
        }

        body.u32(UInt32(state.meanderChannels.count))
        for ch in state.meanderChannels {
            body.u32(UInt32(ch.nodes.count))
            for node in ch.nodes { body.f64(node.x); body.f64(node.z) }
            body.doubles(ch.discharge)
        }
        body.u32(UInt32(state.oxbows.count))
        for ox in state.oxbows {
            body.u32(UInt32(ox.count))
            for node in ox { body.f64(node.x); body.f64(node.z) }
        }
        body.doubles(state.oxbowAge)

        var out = ByteWriter()
        out.bytes(magic)
        out.u32(version)
        out.u64(UInt64(body.data.count))
        out.u64(fnv1a64(body.data))
        out.data.append(body.data)
        return out.data
    }

    // MARK: - Dekodieren

    public static func decode(_ data: Data) throws -> Terrain {
        guard hostIsLittleEndian else { throw SnapshotError.unsupportedHostByteOrder }
        var reader = ByteReader(data)
        let header = try readHeader(&reader)
        guard reader.remaining >= Int(header.payloadLength) else {
            throw SnapshotError.truncated(expected: headerLength + Int(header.payloadLength),
                                          found: data.count)
        }
        let payload = try reader.take(Int(header.payloadLength))
        let sum = fnv1a64(payload)
        guard sum == header.checksum else {
            throw SnapshotError.checksumMismatch(expected: header.checksum, found: sum)
        }

        var body = ByteReader(payload)
        let configData = try body.blob()
        let config: SimConfig
        do {
            config = try PropertyListDecoder().decode(SimConfig.self, from: configData)
        } catch {
            throw SnapshotError.configDecodingFailed(reason: "\(error)")
        }
        let count = config.count

        var state = TerrainState()
        state.seed = try body.u32()
        state.years = try body.f64()
        state.dropsEmitted = try body.u64()
        state.dropCarry = try body.f64()
        state.flowStepCount = try body.u32()
        state.disturbActive = try body.u8() != 0
        state.heightBands = HeightBands(vegFull: try body.f64(), vegRamp: try body.f64(),
                                       rockStart: try body.f64(), rockFull: try body.f64(),
                                       snowStart: try body.f64(), snowFull: try body.f64(),
                                       coniferLow: try body.f64(), coniferHigh: try body.f64())

        let fieldCount = Int(try body.u32())
        let expectedFields = doubleFields.count + int32Fields.count
            + uint8Fields.count + boolFields.count
        guard fieldCount == expectedFields else {
            throw SnapshotError.fieldCountMismatch(expected: expectedFields, found: fieldCount)
        }
        for f in doubleFields {
            state[keyPath: f.path] = try body.field(f, kind: .f64, count: count) {
                try $0.doubles($1)
            }
        }
        for f in int32Fields {
            state[keyPath: f.path] = try body.field(f, kind: .i32, count: count) {
                try $0.int32s($1)
            }
        }
        for f in uint8Fields {
            state[keyPath: f.path] = try body.field(f, kind: .u8, count: count) {
                try $0.uint8s($1)
            }
        }
        for f in boolFields {
            let raw = try body.field(f, kind: .bool, count: count) { try $0.uint8s($1) }
            state[keyPath: f.path] = raw.map { $0 != 0 }
        }

        // `reserveCapacity` NIE direkt mit einer Zahl aus der Datei: eine
        // gefälschte Knotenzahl würde Gigabytes anfordern, bevor der
        // Längen-Check der Leseoperationen greift. Obergrenze ist, was im Rest
        // der Datei überhaupt stehen kann.
        let channelCount = Int(try body.u32())
        var channels: [RiverChannel] = []
        channels.reserveCapacity(min(channelCount, body.remaining / 4))
        for _ in 0..<channelCount {
            let nodeCount = Int(try body.u32())
            var nodes: [MeanderNode] = []
            nodes.reserveCapacity(min(nodeCount, body.remaining / 24)) // x, z, Abfluss
            for _ in 0..<nodeCount {
                nodes.append(MeanderNode(x: try body.f64(), z: try body.f64()))
            }
            let discharge = try body.doubles(nodeCount)
            channels.append(RiverChannel(nodes: nodes, discharge: discharge))
        }
        state.meanderChannels = channels

        let oxbowCount = Int(try body.u32())
        var oxbows: [[MeanderNode]] = []
        oxbows.reserveCapacity(min(oxbowCount, body.remaining / 4))
        for _ in 0..<oxbowCount {
            let nodeCount = Int(try body.u32())
            var nodes: [MeanderNode] = []
            nodes.reserveCapacity(min(nodeCount, body.remaining / 16)) // x, z
            for _ in 0..<nodeCount {
                nodes.append(MeanderNode(x: try body.f64(), z: try body.f64()))
            }
            oxbows.append(nodes)
        }
        state.oxbows = oxbows
        state.oxbowAge = try body.doubles(oxbowCount)

        guard body.remaining == 0 else {
            throw SnapshotError.trailingBytes(count: body.remaining)
        }

        let terrain = Terrain(allocating: config, seed: state.seed)
        terrain.restore(state)
        return terrain
    }

    private struct Header {
        let version: UInt32
        let payloadLength: UInt64
        let checksum: UInt64
    }

    private static func readHeader(_ reader: inout ByteReader) throws -> Header {
        // Erst die Marke, dann die Länge: eine fremde (womöglich winzige) Datei
        // soll „keine river-sim-Welt" heißen und nicht „unvollständig".
        guard reader.remaining >= magic.count else { throw SnapshotError.badMagic }
        let mark = try reader.take(magic.count)
        guard Array(mark) == magic else { throw SnapshotError.badMagic }
        guard reader.remaining >= headerLength - magic.count else {
            throw SnapshotError.truncated(expected: headerLength,
                                          found: magic.count + reader.remaining)
        }
        // Version VOR Prüfsumme: eine Datei aus einer anderen Version soll als
        // solche gemeldet werden, nicht als „defekt".
        let fileVersion = try reader.u32()
        guard fileVersion == version else {
            throw SnapshotError.unsupportedVersion(found: fileVersion, expected: version)
        }
        return Header(version: fileVersion,
                      payloadLength: try reader.u64(),
                      checksum: try reader.u64())
    }

    // MARK: - Feld-Inventar (Reihenfolge = Dateireihenfolge)

    /// Ein Feld des Inventars. `mayBeEmpty` gilt für die Felder, die
    /// abschaltbare Physik führt (leeres Array = Schalter aus) — bei allen
    /// anderen ist eine andere Länge als `cfg.count` ein Fehler.
    struct FieldSpec<T> {
        let name: String
        let path: WritableKeyPath<TerrainState, [T]>
        let mayBeEmpty: Bool
        init(_ name: String, _ path: WritableKeyPath<TerrainState, [T]>,
             mayBeEmpty: Bool = false) {
            self.name = name
            self.path = path
            self.mayBeEmpty = mayBeEmpty
        }
    }

    /// Die Tests iterieren diese Tabellen (statt eine zweite Feldliste zu
    /// führen): ein neues Feld im Inventar wird damit automatisch mitgeprüft.
    static let doubleFields: [FieldSpec<Double>] = [
        .init("h", \.h), .init("rock", \.rock), .init("sed", \.sed),
        .init("upliftBase", \.upliftBase), .init("rain", \.rain),
        .init("rainWeight", \.rainWeight, mayBeEmpty: true),
        .init("lithHardness", \.lithHardness, mayBeEmpty: true),
        .init("lithErodeK", \.lithErodeK, mayBeEmpty: true),
        .init("lithBed", \.lithBed, mayBeEmpty: true),
        .init("lithProvince", \.lithProvince, mayBeEmpty: true),
        .init("veg", \.veg), .init("riparian", \.riparian),
        .init("hf", \.hf), .init("waterLevel", \.waterLevel),
        .init("lakeBalance", \.lakeBalance), .init("saltCrust", \.saltCrust),
        .init("endorheicInflow", \.endorheicInflow),
        .init("area", \.area), .init("areaMFD", \.areaMFD),
        .init("streamMap", \.streamMap), .init("streamRate", \.streamRate),
        .init("disturb", \.disturb), .init("regenPending", \.regenPending),
    ]
    static let int32Fields: [FieldSpec<Int32>] = [
        .init("receiver", \.receiver), .init("order", \.order),
        .init("floodParent", \.floodParent),
    ]
    static let uint8Fields: [FieldSpec<UInt8>] = [
        .init("vegClass", \.vegClass), .init("endorheicBasin", \.endorheicBasin),
    ]
    static let boolFields: [FieldSpec<Bool>] = [
        .init("isChannel", \.isChannel), .init("playaBed", \.playaBed),
    ]

    fileprivate enum FieldKind: UInt8 {
        case f64 = 0, i32 = 1, u8 = 2, bool = 3
    }

    /// Kodierung eines Feldes: `raw` = alle Elemente, `constant` = ein Element
    /// für alle. Der Konstant-Fall ist der Normalfall für die Felder
    /// abschaltbarer oder ruhender Physik (`disturb`, `regenPending`,
    /// `isChannel` …) und spart je Feld 5,5 MB, ohne irgendetwas zu runden.
    fileprivate enum FieldEncoding: UInt8 {
        case raw = 0, constant = 1
    }

    // MARK: - Prüfsumme

    /// FNV-1a (64 bit) — erkennt abgeschnittene/verfälschte Dateien. Bewusst
    /// keine Krypto-Hash: es geht um Datenintegrität, nicht um Manipulation.
    private static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x100_0000_01b3
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for byte in p {
                hash = (hash ^ UInt64(byte)) &* prime
            }
        }
        return hash
    }
}

// MARK: - Fehler

public enum SnapshotError: Error, CustomStringConvertible {
    case unsupportedHostByteOrder
    case badMagic
    case unsupportedVersion(found: UInt32, expected: UInt32)
    case truncated(expected: Int, found: Int)
    case trailingBytes(count: Int)
    case checksumMismatch(expected: UInt64, found: UInt64)
    case configEncodingFailed(reason: String)
    case configDecodingFailed(reason: String)
    case fieldCountMismatch(expected: Int, found: Int)
    case fieldNameMismatch(expected: String, found: String)
    case fieldKindMismatch(field: String)
    case fieldLengthMismatch(field: String, expected: Int, found: Int)
    case readFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case .unsupportedHostByteOrder:
            return "Diese Plattform ist Big-Endian; das Weltformat ist Little-Endian."
        case .badMagic:
            return "Keine river-sim-Welt (Erkennungsmarke fehlt)."
        case let .unsupportedVersion(found, expected):
            return "Welt-Format Version \(found), erwartet \(expected) — "
                + "die Datei stammt aus einer anderen Programmversion und wird nicht geladen."
        case let .truncated(expected, found):
            return "Datei unvollständig: \(expected) Byte erwartet, \(found) gefunden."
        case let .trailingBytes(count):
            return "Datei hat \(count) Byte Überhang — Format passt nicht."
        case let .checksumMismatch(expected, found):
            return "Prüfsumme falsch (erwartet \(expected), gefunden \(found)) — "
                + "Datei beschädigt oder abgebrochen geschrieben."
        case let .configEncodingFailed(reason):
            return "Config nicht speicherbar: \(reason)"
        case let .configDecodingFailed(reason):
            return "Config nicht lesbar (Feld fehlt oder Typ passt nicht): \(reason)"
        case let .fieldCountMismatch(expected, found):
            return "Feldzahl \(found), erwartet \(expected) — Inventar passt nicht."
        case let .fieldNameMismatch(expected, found):
            return "Feld „\(found)“ an der Stelle von „\(expected)“ — Inventar passt nicht."
        case let .fieldKindMismatch(field):
            return "Feld „\(field)“ hat den falschen Elementtyp."
        case let .fieldLengthMismatch(field, expected, found):
            return "Feld „\(field)“: \(found) Elemente, erwartet \(expected) "
                + "(passt nicht zur Gitterauflösung der Datei)."
        case let .readFailed(path, reason):
            return "„\(path)“ nicht lesbar: \(reason)"
        case let .writeFailed(path, reason):
            return "„\(path)“ nicht schreibbar: \(reason)"
        }
    }
}

// MARK: - Byte-Ebene

/// Anhängender Schreiber. `Data` wächst amortisiert; die großen Zahlenfelder
/// gehen als Block hinein (kein Element-Append).
private struct ByteWriter {
    var data = Data()

    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { appendRaw(v.littleEndian) }
    mutating func u64(_ v: UInt64) { appendRaw(v.littleEndian) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }

    mutating func blob(_ b: Data) {
        u32(UInt32(b.count))
        data.append(b)
    }

    mutating func string(_ s: String) { blob(Data(s.utf8)) }

    private mutating func appendRaw<T>(_ value: T) {
        var v = value
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    /// Blocktransfer eines Zahlen-Arrays (Little-Endian-Hostspeicher).
    mutating func block<T>(_ values: [T]) {
        values.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            data.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
                count: buf.count * MemoryLayout<T>.stride))
        }
    }

    mutating func doubles(_ values: [Double]) { block(values) }

    /// Feld mit Kopf (Name, Typ, Kodierung, Länge). Sind alle Elemente gleich,
    /// wird nur eines geschrieben (`constant`).
    mutating func field<T: Equatable>(_ name: String, kind: WorldSnapshot.FieldKind,
                                      values: [T]) {
        string(name)
        u8(kind.rawValue)
        if values.count > 1, isConstant(values) {
            u8(WorldSnapshot.FieldEncoding.constant.rawValue)
            u32(UInt32(values.count))
            block([values[0]])
        } else {
            u8(WorldSnapshot.FieldEncoding.raw.rawValue)
            u32(UInt32(values.count))
            block(values)
        }
    }

    /// Gleichheit über das Bitmuster: `Double`-Vergleich würde −0.0 und 0.0
    /// verschmelzen (und NaN nie gleich finden) — beim Wiederherstellen soll
    /// exakt das gespeicherte Muster zurückkommen.
    private func isConstant<T: Equatable>(_ values: [T]) -> Bool {
        if let d = values as? [Double] {
            let first = d[0].bitPattern
            for v in d where v.bitPattern != first { return false }
            return true
        }
        let first = values[0]
        for v in values where v != first { return false }
        return true
    }
}

/// Lesender Zeiger über eine `Data`-Scheibe. Jeder Zugriff prüft die Länge —
/// eine abgeschnittene Datei wirft, statt über den Rand zu lesen.
private struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    var remaining: Int { data.count - offset }

    private mutating func advance(_ n: Int) throws -> Range<Data.Index> {
        guard remaining >= n else {
            throw SnapshotError.truncated(expected: offset + n, found: data.count)
        }
        let start = data.startIndex + offset
        offset += n
        return start..<(start + n)
    }

    mutating func take(_ n: Int) throws -> Data { data[try advance(n)] }

    mutating func u8() throws -> UInt8 { try scalar(UInt8.self) }
    mutating func u32() throws -> UInt32 { UInt32(littleEndian: try scalar(UInt32.self)) }
    mutating func u64() throws -> UInt64 { UInt64(littleEndian: try scalar(UInt64.self)) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    mutating func blob() throws -> Data { try take(Int(try u32())) }

    mutating func string() throws -> String {
        String(decoding: try blob())
    }

    private mutating func scalar<T>(_ type: T.Type) throws -> T {
        let range = try advance(MemoryLayout<T>.size)
        var value: T?
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: range.lowerBound - data.startIndex)
            value = base.loadUnaligned(as: T.self)
        }
        return value!
    }

    /// Blocktransfer in ein frisches Array (keine Zwischenkopie je Element).
    mutating func block<T>(_ count: Int, _ type: T.Type) throws -> [T] {
        let range = try advance(count * MemoryLayout<T>.stride)
        guard count > 0 else { return [] }
        let source = data
        return [T](unsafeUninitializedCapacity: count) { buf, initialized in
            source.copyBytes(to: buf, from: range)
            initialized = count
        }
    }

    mutating func doubles(_ count: Int) throws -> [Double] { try block(count, Double.self) }
    mutating func int32s(_ count: Int) throws -> [Int32] { try block(count, Int32.self) }
    mutating func uint8s(_ count: Int) throws -> [UInt8] { try block(count, UInt8.self) }

    /// Liest ein Feld inklusive Kopf und prüft Name, Typ und Länge gegen das
    /// Inventar (`read` liefert die Elemente der jeweiligen Breite).
    mutating func field<T, Spec>(_ spec: Spec, kind: WorldSnapshot.FieldKind, count: Int,
                                 _ read: (inout ByteReader, Int) throws -> [T]) throws -> [T]
    where Spec: FieldSpecReading {
        let name = try string()
        guard name == spec.specName else {
            throw SnapshotError.fieldNameMismatch(expected: spec.specName, found: name)
        }
        guard try u8() == kind.rawValue else {
            throw SnapshotError.fieldKindMismatch(field: name)
        }
        let encoding = try u8()
        let length = Int(try u32())
        let allowed = spec.specMayBeEmpty ? [0, count] : [count]
        guard allowed.contains(length) else {
            throw SnapshotError.fieldLengthMismatch(field: name, expected: count, found: length)
        }
        switch encoding {
        case WorldSnapshot.FieldEncoding.constant.rawValue:
            let one = try read(&self, 1)
            guard let value = one.first else {
                throw SnapshotError.fieldLengthMismatch(field: name, expected: count, found: 0)
            }
            return [T](repeating: value, count: length)
        case WorldSnapshot.FieldEncoding.raw.rawValue:
            return try read(&self, length)
        default:
            throw SnapshotError.fieldKindMismatch(field: name)
        }
    }
}

/// Nur damit der Feldleser die beiden Inventar-Angaben lesen kann, ohne den
/// generischen `FieldSpec<T>` nach außen zu tragen.
private protocol FieldSpecReading {
    var specName: String { get }
    var specMayBeEmpty: Bool { get }
}

extension WorldSnapshot.FieldSpec: FieldSpecReading {
    var specName: String { name }
    var specMayBeEmpty: Bool { mayBeEmpty }
}

private extension String {
    /// ASCII/UTF-8-Bytes → String; unlesbare Bytes ergeben einen leeren Namen
    /// und damit einen sauberen `fieldNameMismatch`.
    init(decoding data: Data) {
        self = String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Config-Serialisierung

// `SimConfig`, `HydraulicParams` und `HeightBands` sind Codable-**synthetisiert**
// (die Konformität steht bei der jeweiligen Typdeklaration, weil Swift die
// Synthese nur in der Ursprungsdatei erzeugt): die Datei bekommt damit
// automatisch jede neue Stellschraube aus `Config.swift`, ohne dass hier eine
// Liste nachgezogen werden muss — eine vergessene Stellschraube wäre ein stiller
// Determinismus-Bruch. `Equatable` ist der Wächter dafür: der Round-Trip-Test
// vergleicht die ganze Config, nicht einzelne Felder.

/// Handgeschrieben, weil `ErosionFilter.Params` Tupel führt (`rounding`,
/// `onset`, `assumedSlope`) — Tupel sind nicht `Codable`. Sie werden als Arrays
/// fester Länge geschrieben; eine falsche Länge ist ein Dekodier-Fehler.
extension ErosionFilter.Params: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case strength, gullyWeight, detail, rounding, onset, assumedSlope
        case scale, octaves, lacunarity, gain, cellScale, normalization
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        strength = try c.decode(Double.self, forKey: .strength)
        gullyWeight = try c.decode(Double.self, forKey: .gullyWeight)
        detail = try c.decode(Double.self, forKey: .detail)
        let r = try c.decode([Double].self, forKey: .rounding)
        let o = try c.decode([Double].self, forKey: .onset)
        let a = try c.decode([Double].self, forKey: .assumedSlope)
        guard r.count == 4, o.count == 4, a.count == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .rounding, in: c,
                debugDescription: "Tupel-Längen der Pre-Erosions-Parameter passen nicht")
        }
        rounding = (r[0], r[1], r[2], r[3])
        onset = (o[0], o[1], o[2], o[3])
        assumedSlope = (a[0], a[1])
        scale = try c.decode(Double.self, forKey: .scale)
        octaves = try c.decode(Int.self, forKey: .octaves)
        lacunarity = try c.decode(Double.self, forKey: .lacunarity)
        gain = try c.decode(Double.self, forKey: .gain)
        cellScale = try c.decode(Double.self, forKey: .cellScale)
        normalization = try c.decode(Double.self, forKey: .normalization)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(strength, forKey: .strength)
        try c.encode(gullyWeight, forKey: .gullyWeight)
        try c.encode(detail, forKey: .detail)
        try c.encode([rounding.0, rounding.1, rounding.2, rounding.3], forKey: .rounding)
        try c.encode([onset.0, onset.1, onset.2, onset.3], forKey: .onset)
        try c.encode([assumedSlope.0, assumedSlope.1], forKey: .assumedSlope)
        try c.encode(scale, forKey: .scale)
        try c.encode(octaves, forKey: .octaves)
        try c.encode(lacunarity, forKey: .lacunarity)
        try c.encode(gain, forKey: .gain)
        try c.encode(cellScale, forKey: .cellScale)
        try c.encode(normalization, forKey: .normalization)
    }

    public static func == (l: Self, r: Self) -> Bool {
        l.strength == r.strength && l.gullyWeight == r.gullyWeight && l.detail == r.detail
            && l.rounding == r.rounding && l.onset == r.onset
            && l.assumedSlope == r.assumedSlope && l.scale == r.scale
            && l.octaves == r.octaves && l.lacunarity == r.lacunarity && l.gain == r.gain
            && l.cellScale == r.cellScale && l.normalization == r.normalization
    }
}

import Foundation

public enum WorldSnapshot {
    public static let magic: [UInt8] = Array("RIVERSIM".utf8)

    public static let version: UInt32 = 12

    public static let fileExtension = "rsworld"

    private static let headerLength = 28

    private static var hostIsLittleEndian: Bool { UInt32(1).littleEndian == 1 }

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

    public static func read(from path: String) throws -> Terrain {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw SnapshotError.readFailed(path: path, reason: error.localizedDescription)
        }
        return try decode(data)
    }

    public static func peekVersion(at path: String) throws -> UInt32 {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw SnapshotError.readFailed(path: path, reason: "Datei nicht lesbar")
        }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: headerLength)
        var reader = ByteReader(head)
        return try readHeader(&reader).version
    }

    public static func peekConfig(at path: String) throws -> SimConfig {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw SnapshotError.readFailed(path: path, reason: "Datei nicht lesbar")
        }
        defer { try? handle.close() }
        var head = ByteReader(handle.readData(ofLength: headerLength + 4))
        let header = try readHeader(&head)
        let rawLength = try head.u32()
        guard let length = Int(exactly: rawLength),
              UInt64(length) + 4 <= header.payloadLength else {
            let maxSafe = UInt64(Int.max) - UInt64(headerLength + 4)
            let exp = headerLength + 4 + Int(min(UInt64(rawLength), maxSafe))
            let found = headerLength + Int(min(header.payloadLength, UInt64(Int.max) - UInt64(headerLength)))
            throw SnapshotError.truncated(expected: exp, found: found)
        }
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
        body.f64(state.beltCouplingCarry)
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

    public static func decode(_ data: Data) throws -> Terrain {
        guard hostIsLittleEndian else { throw SnapshotError.unsupportedHostByteOrder }
        var reader = ByteReader(data)
        let header = try readHeader(&reader)
        guard let payloadLength = Int(exactly: header.payloadLength),
              reader.remaining >= payloadLength else {
            let maxSafe = UInt64(Int.max) - UInt64(headerLength)
            let exp = headerLength + Int(min(header.payloadLength, maxSafe))
            throw SnapshotError.truncated(expected: exp, found: data.count)
        }
        let payload = try reader.take(payloadLength)
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
        state.beltCouplingCarry = try body.f64()
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

        let channelCount = Int(try body.u32())
        var channels: [RiverChannel] = []
        channels.reserveCapacity(min(channelCount, body.remaining / 4))
        for _ in 0..<channelCount {
            let nodeCount = Int(try body.u32())
            var nodes: [MeanderNode] = []
            nodes.reserveCapacity(min(nodeCount, body.remaining / 24))
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
            nodes.reserveCapacity(min(nodeCount, body.remaining / 16))
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
        guard reader.remaining >= magic.count else { throw SnapshotError.badMagic }
        let mark = try reader.take(magic.count)
        guard Array(mark) == magic else { throw SnapshotError.badMagic }
        guard reader.remaining >= headerLength - magic.count else {
            throw SnapshotError.truncated(expected: headerLength,
                                          found: magic.count + reader.remaining)
        }
        let fileVersion = try reader.u32()
        guard fileVersion == version else {
            throw SnapshotError.unsupportedVersion(found: fileVersion, expected: version)
        }
        return Header(version: fileVersion,
                      payloadLength: try reader.u64(),
                      checksum: try reader.u64())
    }

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

    nonisolated(unsafe) static let doubleFields: [FieldSpec<Double>] = [
        .init("h", \.h), .init("rock", \.rock), .init("sed", \.sed),
        .init("upliftBase", \.upliftBase), .init("rain", \.rain),
        .init("rainWeight", \.rainWeight, mayBeEmpty: true),
        .init("lithHardness", \.lithHardness, mayBeEmpty: true),
        .init("lithErodeK", \.lithErodeK, mayBeEmpty: true),
        .init("lithBed", \.lithBed, mayBeEmpty: true),
        .init("lithProvince", \.lithProvince, mayBeEmpty: true),
        .init("temperature", \.temperature, mayBeEmpty: true),
        .init("snow", \.snow, mayBeEmpty: true),
        .init("ice", \.ice, mayBeEmpty: true),
        .init("veg", \.veg), .init("riparian", \.riparian),
        .init("barAge", \.barAge),
        .init("hf", \.hf), .init("waterLevel", \.waterLevel),
        .init("lakeBalance", \.lakeBalance), .init("saltCrust", \.saltCrust),
        .init("endorheicInflow", \.endorheicInflow),
        .init("area", \.area), .init("areaMFD", \.areaMFD),
        .init("streamMap", \.streamMap), .init("streamRate", \.streamRate),
        .init("disturb", \.disturb), .init("regenPending", \.regenPending),
    ]
    nonisolated(unsafe) static let int32Fields: [FieldSpec<Int32>] = [
        .init("receiver", \.receiver), .init("order", \.order),
        .init("floodParent", \.floodParent),
    ]
    nonisolated(unsafe) static let uint8Fields: [FieldSpec<UInt8>] = [
        .init("vegClass", \.vegClass), .init("endorheicBasin", \.endorheicBasin),
    ]
    nonisolated(unsafe) static let boolFields: [FieldSpec<Bool>] = [
        .init("isChannel", \.isChannel), .init("playaBed", \.playaBed),
    ]

    fileprivate enum FieldKind: UInt8 {
        case f64 = 0, i32 = 1, u8 = 2, bool = 3
    }

    fileprivate enum FieldEncoding: UInt8 {
        case raw = 0, constant = 1
    }

    private static func fnv1a64(_ data: Data) -> UInt64 {
        var h = StateHasher()
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) { h.mix(byte: byte) }
        }
        return h.hash
    }
}

private struct StateHasher {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func mix(byte: UInt8) {
        hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
    }
    mutating func mix(_ value: UInt64) {
        var bits = value
        for _ in 0..<8 {
            mix(byte: UInt8(truncatingIfNeeded: bits))
            bits >>= 8
        }
    }
    mutating func mix(_ value: Double) { mix(value.bitPattern) }
    mutating func mix(_ values: [Double]) {
        mix(UInt64(values.count))
        for v in values { mix(v.bitPattern) }
    }
    mutating func mix(_ values: [Int32]) {
        mix(UInt64(values.count))
        for v in values { mix(UInt64(UInt32(bitPattern: v))) }
    }
    mutating func mix(_ values: [UInt8]) {
        mix(UInt64(values.count))
        for v in values { mix(UInt64(v)) }
    }
    mutating func mix(_ values: [Bool]) {
        mix(UInt64(values.count))
        for v in values { mix(UInt64(v ? 1 : 0)) }
    }
}

extension TerrainState {
    func fingerprint() -> UInt64 {
        var f = StateHasher()
        f.mix(UInt64(seed))
        f.mix(years)
        f.mix(dropsEmitted)
        f.mix(dropCarry)
        f.mix(beltCouplingCarry)
        f.mix(UInt64(flowStepCount))
        f.mix(UInt64(disturbActive ? 1 : 0))
        let bands = Mirror(reflecting: heightBands).children
            .compactMap { $0.value as? Double }
        f.mix(UInt64(bands.count))
        for v in bands { f.mix(v) }
        for spec in WorldSnapshot.doubleFields { f.mix(self[keyPath: spec.path]) }
        for spec in WorldSnapshot.int32Fields { f.mix(self[keyPath: spec.path]) }
        for spec in WorldSnapshot.uint8Fields { f.mix(self[keyPath: spec.path]) }
        for spec in WorldSnapshot.boolFields { f.mix(self[keyPath: spec.path]) }
        f.mix(UInt64(meanderChannels.count))
        for ch in meanderChannels {
            f.mix(UInt64(ch.nodes.count))
            for node in ch.nodes { f.mix(node.x); f.mix(node.z) }
            f.mix(ch.discharge)
        }
        f.mix(UInt64(oxbows.count))
        for ox in oxbows {
            f.mix(UInt64(ox.count))
            for node in ox { f.mix(node.x); f.mix(node.z) }
        }
        f.mix(oxbowAge)
        return f.hash
    }
}

extension Terrain {
    public func fingerprint() -> UInt64 { state.fingerprint() }
}

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

    mutating func block<T>(_ values: [T]) {
        values.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            data.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
                count: buf.count * MemoryLayout<T>.stride))
        }
    }

    mutating func doubles(_ values: [Double]) { block(values) }

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

private struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    var remaining: Int { data.count - offset }

    private mutating func advance(_ n: Int) throws -> Range<Data.Index> {
        guard n >= 0, remaining >= n else {
            let maxSafe = Int.max - offset
            let exp = n > maxSafe ? Int.max : offset + max(0, n)
            throw SnapshotError.truncated(expected: exp, found: data.count)
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

    mutating func blob() throws -> Data {
        let raw = try u32()
        guard let len = Int(exactly: raw) else {
            let maxSafe = UInt64(Int.max) - UInt64(offset)
            let exp = offset + Int(min(UInt64(raw), maxSafe))
            throw SnapshotError.truncated(expected: exp, found: data.count)
        }
        return try take(len)
    }

    mutating func string() throws -> String {
        String(decoding: try blob())
    }

    private mutating func scalar<T>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        let range = try advance(size)
        var value: T?
        data.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            let base = baseAddress.advanced(by: range.lowerBound - data.startIndex)
            value = base.loadUnaligned(as: T.self)
        }
        guard let result = value else {
            throw SnapshotError.truncated(expected: offset - size, found: data.count)
        }
        return result
    }

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

private protocol FieldSpecReading {
    var specName: String { get }
    var specMayBeEmpty: Bool { get }
}

extension WorldSnapshot.FieldSpec: FieldSpecReading {
    var specName: String { name }
    var specMayBeEmpty: Bool { mayBeEmpty }
}

private extension String {
    init(decoding data: Data) {
        self = String(data: data, encoding: .utf8) ?? ""
    }
}

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

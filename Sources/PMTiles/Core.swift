// Core operations from the pmtiles spec §3. Pure functions on bytes and values:
// no Foundation, no I/O, no global state.

// MARK: - decode_header

/// Spec operation `decode_header`: decodes the fixed 127-byte archive header.
/// Bytes after the first 127 are ignored.
public func decodeHeader(_ bytes: some Collection<UInt8>) throws(PMTilesError) -> Header {
    let b = Array(bytes.prefix(127))
    guard b.count == 127 else { throw PMTilesError(.invalidInput, "pmtiles.truncated") }
    guard b[0..<7].elementsEqual("PMTiles".utf8) else { throw PMTilesError(.invalidInput, "pmtiles.bad_magic") }
    guard b[7] == 3 else { throw PMTilesError(.unsupported, "pmtiles.unsupported_version") }

    func u64(_ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = v << 8 | UInt64(b[o + i]) }
        return v
    }
    func i32(_ o: Int) -> Int32 {
        Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
    }
    // E7 integers to degrees: divide, don't multiply by 1e-7.
    func deg(_ o: Int) -> Double { Double(i32(o)) / 10_000_000 }
    func count(_ o: Int) -> UInt64? { let v = u64(o); return v == 0 ? nil : v }

    return Header(
        specVersion: 3,
        rootDirectoryOffset: u64(8), rootDirectoryLength: u64(16),
        metadataOffset: u64(24), metadataLength: u64(32),
        leafDirectoriesOffset: u64(40), leafDirectoriesLength: u64(48),
        tileDataOffset: u64(56), tileDataLength: u64(64),
        addressedTilesCount: count(72), tileEntriesCount: count(80), tileContentsCount: count(88),
        clustered: b[96] == 1,
        internalCompression: Compression(raw: b[97]),
        tileCompression: Compression(raw: b[98]),
        tileType: TileType(raw: b[99]),
        minZoom: b[100], maxZoom: b[101],
        bounds: BBox(minLon: deg(102), minLat: deg(106), maxLon: deg(110), maxLat: deg(114)),
        centerZoom: b[118],
        center: LonLat(lon: deg(119), lat: deg(123))
    )
}

// MARK: - decode_directory

/// Reads unsigned LEB128 varints, at most 10 bytes and 64 bits (spec §3).
struct VarintReader {
    let bytes: [UInt8]
    var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func next() throws(PMTilesError) -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for n in 0..<10 {
            guard index < bytes.count else { throw PMTilesError(.invalidInput, "pmtiles.truncated") }
            let byte = bytes[index]
            index += 1
            // The 10th byte may only carry bit 63.
            if n == 9 && byte > 1 { throw PMTilesError(.invalidInput, "pmtiles.varint_overflow") }
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        throw PMTilesError(.invalidInput, "pmtiles.varint_overflow")
    }
}

/// Spec operation `decode_directory`: decodes an **already decompressed** directory.
/// The entry count is checked against `limits.maxDirectoryEntries` before any entry
/// is read or allocated. Bytes after the last offset are ignored.
public func decodeDirectory(_ bytes: some Collection<UInt8>, limits: Limits = Limits()) throws(PMTilesError) -> [Entry] {
    try decodeDirectory(bytes: Array(bytes), limits: limits)
}

package func decodeDirectory(bytes: [UInt8], limits: Limits) throws(PMTilesError) -> [Entry] {
    // Hot path: unsafe pointers with explicit length checks (every byte read is checked
    // against the end), so the loops skip per-access bounds checks. Failures are a
    // one-byte code until the end, so the per-varint check copies nothing.
    var failure = Failure.none
    let entries: [Entry] = bytes.withUnsafeBufferPointer { b in
        var r = UnsafeVarintReader(b)
        let n = r.next()
        if r.failure != .none { failure = r.failure; return [] }
        guard n <= limits.maxDirectoryEntries else { failure = .tooManyEntries; return [] }
        let count = Int(n)
        return [Entry](unsafeUninitializedCapacity: count) { e, initialized in
            e.initialize(repeating: Entry(tileId: 0, offset: 0, length: 0, runLength: 0))
            failure = decodeEntries(&r, e, count)
            initialized = count
        }
    }
    switch failure {
    case .none: return entries
    case .truncated: throw PMTilesError(.invalidInput, "pmtiles.truncated")
    case .varintOverflow: throw PMTilesError(.invalidInput, "pmtiles.varint_overflow")
    case .invalid: throw PMTilesError(.invalidInput, "pmtiles.invalid_directory")
    case .tooManyEntries: throw PMTilesError(.limitExceeded, "pmtiles.directory_too_large")
    }
}

enum Failure: UInt8 { case none, truncated, varintOverflow, invalid, tooManyEntries }

private func decodeEntries(_ r: inout UnsafeVarintReader, _ e: UnsafeMutableBufferPointer<Entry>, _ count: Int) -> Failure {
    var last: UInt64 = 0
    for i in 0..<count {
        let delta = r.next()
        if r.failure != .none { return r.failure }
        // Tile ids must strictly increase (D-002).
        if i > 0 && delta == 0 { return .invalid }
        let (id, overflow) = last.addingReportingOverflow(delta)
        if overflow { return .invalid }
        last = id
        e[i].tileId = id
    }
    for i in 0..<count {
        let v = r.next()
        if r.failure != .none { return r.failure }
        if v > UInt64(UInt32.max) { return .invalid }
        e[i].runLength = UInt32(truncatingIfNeeded: v)
    }
    for i in 0..<count {
        let v = r.next()
        if r.failure != .none { return r.failure }
        if v > UInt64(UInt32.max) { return .invalid }
        e[i].length = UInt32(truncatingIfNeeded: v)
    }
    for i in 0..<count {
        let v = r.next()
        if r.failure != .none { return r.failure }
        if v == 0 {
            // "Continue from the previous entry": the first entry has none (D-002).
            if i == 0 { return .invalid }
            let (off, overflow) = e[i - 1].offset.addingReportingOverflow(UInt64(e[i - 1].length))
            if overflow { return .invalid }
            e[i].offset = off
        } else {
            e[i].offset = v - 1
        }
    }
    return .none
}

/// Varint reader over an unsafe buffer. Never throws: records the first failure and
/// returns 0 afterwards, so hot loops check a byte instead of unwinding.
struct UnsafeVarintReader {
    let b: UnsafeBufferPointer<UInt8>
    var index = 0
    var failure = Failure.none

    init(_ b: UnsafeBufferPointer<UInt8>) { self.b = b }

    @inline(__always) mutating func next() -> UInt64 {
        // Fast path: directory values almost always fit in one or two bytes.
        if index + 1 < b.count {
            let b0 = b[index]
            if b0 < 0x80 {
                index += 1
                return UInt64(b0)
            }
            let b1 = b[index + 1]
            if b1 < 0x80 {
                index += 2
                return UInt64(b0 & 0x7F) | UInt64(b1) << 7
            }
        }
        return slow()
    }

    @inline(never) mutating func slow() -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for n in 0..<10 {
            guard index < b.count else { failure = .truncated; return 0 }
            let byte = b[index]
            index += 1
            // The 10th byte may only carry bit 63.
            if n == 9 && byte > 1 { failure = .varintOverflow; return 0 }
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        failure = .varintOverflow
        return 0
    }
}

// MARK: - tile ids

/// The last tile id at zoom 31: `(4^32 - 1) / 3 - 1`.
public let maxTileId: UInt64 = 0x5555_5555_5555_5554

/// Number of tiles at all zooms below `z`: `(4^z - 1) / 3`.
@inline(__always) func tilesBelow(_ z: UInt8) -> UInt64 {
    z == 0 ? 0 : (UInt64(1) << (2 * UInt64(z)) &- 1) / 3
}

/// The Hilbert-curve rotation, with wrapping arithmetic: only the low bits matter.
@inline(__always) func rotate(_ n: UInt64, _ x: inout UInt64, _ y: inout UInt64, _ rx: UInt64, _ ry: UInt64) {
    if ry == 0 {
        if rx != 0 {
            x = n &- 1 &- x
            y = n &- 1 &- y
        }
        swap(&x, &y)
    }
}

/// Spec operation `zxy_to_tile_id`.
public func zxyToTileId(_ coord: TileCoord) throws(PMTilesError) -> UInt64 {
    guard coord.z <= 31 else { throw PMTilesError(.invalidInput, "pmtiles.invalid_zoom") }
    let size = UInt64(1) << UInt64(coord.z)
    guard UInt64(coord.x) < size, UInt64(coord.y) < size else {
        throw PMTilesError(.invalidInput, "pmtiles.tile_out_of_range")
    }
    var acc = tilesBelow(coord.z)
    var x = UInt64(coord.x), y = UInt64(coord.y)
    var a = Int(coord.z) - 1
    while a >= 0 {
        let s = UInt64(1) << UInt64(a)
        let rx = s & x, ry = s & y
        acc &+= ((3 &* rx) ^ ry) << UInt64(a)
        rotate(s, &x, &y, rx, ry)
        a -= 1
    }
    return acc
}

/// Spec operation `tile_id_to_zxy`.
public func tileIdToZxy(_ tileId: UInt64) throws(PMTilesError) -> TileCoord {
    guard tileId <= maxTileId else { throw PMTilesError(.invalidInput, "pmtiles.invalid_zoom") }
    // Largest z with tilesBelow(z) <= tileId.
    var z: UInt8 = 0
    while z < 31 && tilesBelow(z + 1) <= tileId { z += 1 }
    var pos = tileId - tilesBelow(z)
    var x: UInt64 = 0, y: UInt64 = 0
    let n = UInt64(1) << UInt64(z)
    var s: UInt64 = 1
    while s < n {
        let rx = (pos / 2) & s
        let ry = (pos ^ rx) & s
        rotate(s, &x, &y, rx, ry)
        x &+= rx
        y &+= ry
        pos >>= 1
        s <<= 1
    }
    return TileCoord(z: z, x: UInt32(truncatingIfNeeded: x), y: UInt32(truncatingIfNeeded: y))
}

// MARK: - find_entry

/// Spec operation `find_entry`: the entry covering `tileId`, or `nil` when absent.
/// A leaf pointer (`runLength == 0`) covers every id up to the next entry (D-003).
public func findEntry(_ entries: [Entry], tileId: UInt64) -> Entry? {
    var lo = 0, hi = entries.count - 1
    while lo <= hi {
        let mid = (lo + hi) / 2
        if entries[mid].tileId < tileId {
            lo = mid + 1
        } else if entries[mid].tileId > tileId {
            hi = mid - 1
        } else {
            return entries[mid]
        }
    }
    if hi >= 0 {
        let e = entries[hi]
        if e.runLength == 0 || tileId - e.tileId < UInt64(e.runLength) { return e }
    }
    return nil
}

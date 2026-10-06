// Conformance runner: every case in `.spec/conformance/manifest.json`, compared the way
// the case says (`exact`, `float_tol`, `json_equal`, `bytes`).
// Usage: swift run pmtiles-conformance [manifest.json]   (exit 0 only if all pass)

import Foundation
import PMTiles
import PMTilesIO

/// Canonical JSON (`.kit/CONVENTIONS.md` §5). Decoded with JSONDecoder, which keeps
/// booleans and numbers apart identically on Apple platforms and Linux.
indirect enum JSON: Decodable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    subscript(key: String) -> JSON? { if case .object(let o) = self { o[key] } else { nil } }
    var string: String? { if case .string(let s) = self { s } else { nil } }
    var array: [JSON]? { if case .array(let a) = self { a } else { nil } }
    var number: Double? { if case .number(let n) = self { n } else { nil } }

    /// A u64 in canonical form: a number up to 2^53, or a decimal string beyond.
    var u64: UInt64? {
        switch self {
        case .number(let n): UInt64(exactly: n)
        case .string(let s): UInt64(s)
        default: nil
        }
    }

    static func u(_ n: UInt64) -> JSON { n <= 1 << 53 ? .number(Double(n)) : .string("\(n)") }

    func matches(_ other: JSON, tol: Double) -> Bool {
        switch (self, other) {
        case let (.number(a), .number(b)): abs(a - b) <= tol
        case let (.array(a), .array(b)): a.count == b.count && zip(a, b).allSatisfy { $0.matches($1, tol: tol) }
        case let (.object(a), .object(b)): Set(a.keys) == Set(b.keys) && a.allSatisfy { $0.value.matches(b[$0.key]!, tol: tol) }
        default: self == other
        }
    }

    var text: String {
        switch self {
        case .null: "null"
        case .bool(let b): "\(b)"
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? "\(Int64(n))" : "\(n)"
        case .string(let s): "\"\(s)\""
        case .array(let a): "[" + a.map(\.text).joined(separator: ",") + "]"
        case .object(let o): "{" + o.keys.sorted().map { "\"\($0)\":\(o[$0]!.text)" }.joined(separator: ",") + "}"
        }
    }
}

let manifestPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".spec/conformance/manifest.json"
let casesDir = URL(fileURLWithPath: manifestPath).deletingLastPathComponent().appendingPathComponent("cases")
guard let data = FileManager.default.contents(atPath: manifestPath),
      let manifest = try? JSONDecoder().decode(JSON.self, from: data),
      let cases = manifest["cases"]?.array else {
    FileHandle.standardError.write(Data("cannot read \(manifestPath)\n".utf8))
    exit(2)
}

// MARK: values to canonical JSON

let compressionNames = ["unknown", "none", "gzip", "brotli", "zstd"]
let tileTypeNames = ["unknown", "mvt", "png", "jpeg", "webp", "avif"]

func enumJSON(_ names: [String], _ raw: UInt8) -> JSON {
    Int(raw) < names.count ? .string(names[Int(raw)]) : .object(["unknown": .number(Double(raw))])
}

func headerJSON(_ h: Header) -> JSON {
    func opt(_ v: UInt64?) -> JSON { v.map(JSON.u) ?? .null }
    return .object([
        "spec_version": .number(Double(h.specVersion)),
        "root_directory_offset": .u(h.rootDirectoryOffset), "root_directory_length": .u(h.rootDirectoryLength),
        "metadata_offset": .u(h.metadataOffset), "metadata_length": .u(h.metadataLength),
        "leaf_directories_offset": .u(h.leafDirectoriesOffset), "leaf_directories_length": .u(h.leafDirectoriesLength),
        "tile_data_offset": .u(h.tileDataOffset), "tile_data_length": .u(h.tileDataLength),
        "addressed_tiles_count": opt(h.addressedTilesCount), "tile_entries_count": opt(h.tileEntriesCount),
        "tile_contents_count": opt(h.tileContentsCount),
        "clustered": .bool(h.clustered),
        "internal_compression": enumJSON(compressionNames, h.internalCompression.raw),
        "tile_compression": enumJSON(compressionNames, h.tileCompression.raw),
        "tile_type": enumJSON(tileTypeNames, h.tileType.raw),
        "min_zoom": .number(Double(h.minZoom)), "max_zoom": .number(Double(h.maxZoom)),
        "bounds": .object(["min_lon": .number(h.bounds.minLon), "min_lat": .number(h.bounds.minLat),
                           "max_lon": .number(h.bounds.maxLon), "max_lat": .number(h.bounds.maxLat)]),
        "center_zoom": .number(Double(h.centerZoom)),
        "center": .object(["lon": .number(h.center.lon), "lat": .number(h.center.lat)]),
    ])
}

func entryJSON(_ e: Entry) -> JSON {
    .object(["tile_id": .u(e.tileId), "offset": .u(e.offset),
             "length": .number(Double(e.length)), "run_length": .number(Double(e.runLength))])
}

func entry(_ v: JSON) -> Entry {
    Entry(tileId: v["tile_id"]!.u64!, offset: v["offset"]!.u64!,
          length: UInt32(v["length"]!.u64!), runLength: UInt32(v["run_length"]!.u64!))
}

func coord(_ v: JSON) -> TileCoord {
    TileCoord(z: UInt8(v["z"]!.u64!), x: UInt32(v["x"]!.u64!), y: UInt32(v["y"]!.u64!))
}

func inputBytes(_ input: JSON) -> [UInt8] {
    if let b = input["base64"]?.string { return [UInt8](Data(base64Encoded: b)!) }
    if let f = input["file"]?.string { return [UInt8](FileManager.default.contents(atPath: casesDir.appendingPathComponent(f).path)!) }
    return []
}

func limits(_ options: JSON?) -> Limits {
    var l = Limits()
    if let v = options?["max_directory_entries"]?.u64 { l.maxDirectoryEntries = v }
    if let v = options?["max_directory_bytes"]?.u64 { l.maxDirectoryBytes = v }
    if let v = options?["max_leaf_depth"]?.u64 { l.maxLeafDepth = UInt32(v) }
    if let v = options?["max_metadata_bytes"]?.u64 { l.maxMetadataBytes = v }
    return l
}

// MARK: run

func run(_ c: JSON) async -> Result<JSON, PMTilesError> {
    let input = c["input"]!
    let opts = limits(c["options"])
    do throws(PMTilesError) {
        switch c["op"]!.string! {
        case "decode_header":
            return .success(headerJSON(try decodeHeader(inputBytes(input))))
        case "decode_directory":
            return .success(.array(try decodeDirectory(inputBytes(input), limits: opts).map(entryJSON)))
        case "zxy_to_tile_id":
            return .success(.u(try zxyToTileId(coord(input["value"]!))))
        case "tile_id_to_zxy":
            let t = try tileIdToZxy(input["value"]!.u64!)
            return .success(.object(["z": .number(Double(t.z)), "x": .number(Double(t.x)), "y": .number(Double(t.y))]))
        case "find_entry":
            let v = input["value"]!
            let found = findEntry(v["entries"]!.array!.map(entry), tileId: v["tile_id"]!.u64!)
            return .success(found.map(entryJSON) ?? .null)
        case "get_tile":
            let tile = try await getTile(MemorySource(inputBytes(input)), coord(input["args"]!["coord"]!), limits: opts)
            return .success(tile.map { .string(Data($0).base64EncodedString()) } ?? .null)
        case "read_metadata":
            return .success(.string(try await readMetadata(MemorySource(inputBytes(input)), limits: opts)))
        default:
            return .failure(PMTilesError(.internal, "runner.unknown_op"))
        }
    } catch {
        return .failure(error)
    }
}

var passed = [String: Int](), totals = [String: Int]()
for c in cases {
    let id = c["id"]!.string!, level = c["level"]!.string!
    totals[level, default: 0] += 1
    let expect = c["expect"]!
    let tol = c["tolerance"]?.number ?? 0
    var why: String?
    switch await run(c) {
    case .failure(let e):
        if let want = expect["error"] {
            if want["kind"]?.string != e.kind.rawValue || want["code"]?.string != e.code {
                why = "expected \(want["kind"]!.text)/\(want["code"]!.text), got \(e.kind.rawValue)/\(e.code)"
            } else if let o = want["offset"]?.u64, e.offset != o {
                why = "expected offset \(o), got \(e.offset.map(String.init) ?? "none")"
            }
        } else {
            why = "unexpected error \(e.code) (\(e.kind.rawValue))"
        }
    case .success(let got):
        if expect["error"] != nil {
            why = "expected an error, got \(got.text)"
        } else {
            // `bytes` cases carry the expected bytes as {"base64": …}; the runner returns base64 too.
            let want = expect["value"] ?? expect["base64"] ?? .null
            if !got.matches(want, tol: tol) { why = "expected \(want.text), got \(got.text)" }
        }
    }
    if let why { print("FAIL \(id): \(why)") } else { passed[level, default: 0] += 1 }
}

let core = (passed["core"] ?? 0, totals["core"] ?? 0), io = (passed["io"] ?? 0, totals["io"] ?? 0)
let full = (core.0 + io.0, core.1 + io.1)
print("pmtiles swift (spec \(manifest["spec_version"]?.string ?? "?")): core \(core.0)/\(core.1), io \(io.0)/\(io.1), full \(full.0)/\(full.1)")
exit(full.0 == full.1 ? 0 : 1)

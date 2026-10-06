// Types from the pmtiles spec (`.spec/spec/capability.yaml`). Core never imports Foundation.

/// Error raised by every PMTiles operation. `kind` and `code` are the spec's
/// stable error kind and code (e.g. `pmtiles.bad_magic`); tests and callers
/// should match on those, never on message text.
public struct PMTilesError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable, Equatable {
        case invalidInput = "invalid_input"
        case unsupported
        case limitExceeded = "limit_exceeded"
        case notFound = "not_found"
        case io
        case `internal`
    }

    public let kind: Kind
    public let code: String
    /// Byte offset into the input, when the spec defines one.
    public let offset: UInt64?

    public init(_ kind: Kind, _ code: String, offset: UInt64? = nil) {
        self.kind = kind
        self.code = code
        self.offset = offset
    }

    public var description: String {
        "\(code) (\(kind.rawValue))" + (offset.map { " at byte \($0)" } ?? "")
    }
}

/// Limits on untrusted archives. Defaults match the spec.
public struct Limits: Sendable, Equatable {
    public var maxDirectoryEntries: UInt64 = 1_000_000
    public var maxDirectoryBytes: UInt64 = 16 * 1024 * 1024
    public var maxLeafDepth: UInt32 = 4
    public var maxMetadataBytes: UInt64 = 16 * 1024 * 1024

    public init(
        maxDirectoryEntries: UInt64 = 1_000_000,
        maxDirectoryBytes: UInt64 = 16 * 1024 * 1024,
        maxLeafDepth: UInt32 = 4,
        maxMetadataBytes: UInt64 = 16 * 1024 * 1024
    ) {
        self.maxDirectoryEntries = maxDirectoryEntries
        self.maxDirectoryBytes = maxDirectoryBytes
        self.maxLeafDepth = maxLeafDepth
        self.maxMetadataBytes = maxMetadataBytes
    }
}

/// Compression of the archive's internal data or of its tiles (open enum).
public enum Compression: Sendable, Equatable, Hashable {
    case unknown, none, gzip, brotli, zstd
    /// A raw value this version of the spec doesn't define, kept as-is.
    case other(UInt8)

    public init(raw: UInt8) {
        switch raw {
        case 0: self = .unknown
        case 1: self = .none
        case 2: self = .gzip
        case 3: self = .brotli
        case 4: self = .zstd
        default: self = .other(raw)
        }
    }

    public var raw: UInt8 {
        switch self {
        case .unknown: 0
        case .none: 1
        case .gzip: 2
        case .brotli: 3
        case .zstd: 4
        case .other(let r): r
        }
    }
}

/// Type of the archive's tiles (open enum).
public enum TileType: Sendable, Equatable, Hashable {
    case unknown, mvt, png, jpeg, webp, avif
    /// A raw value this version of the spec doesn't define, kept as-is.
    case other(UInt8)

    public init(raw: UInt8) {
        switch raw {
        case 0: self = .unknown
        case 1: self = .mvt
        case 2: self = .png
        case 3: self = .jpeg
        case 4: self = .webp
        case 5: self = .avif
        default: self = .other(raw)
        }
    }

    public var raw: UInt8 {
        switch self {
        case .unknown: 0
        case .mvt: 1
        case .png: 2
        case .jpeg: 3
        case .webp: 4
        case .avif: 5
        case .other(let r): r
        }
    }
}

/// A WGS84 coordinate in degrees, `(lon, lat)`.
public struct LonLat: Sendable, Equatable, Hashable {
    public var lon: Double
    public var lat: Double
    public init(lon: Double, lat: Double) { self.lon = lon; self.lat = lat }
}

/// A WGS84 bounding box in degrees.
public struct BBox: Sendable, Equatable, Hashable {
    public var minLon, minLat, maxLon, maxLat: Double
    public init(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
        self.minLon = minLon; self.minLat = minLat; self.maxLon = maxLon; self.maxLat = maxLat
    }
}

/// The fixed 127-byte archive header (spec §2).
public struct Header: Sendable, Equatable {
    public var specVersion: UInt8
    public var rootDirectoryOffset: UInt64
    public var rootDirectoryLength: UInt64
    public var metadataOffset: UInt64
    public var metadataLength: UInt64
    public var leafDirectoriesOffset: UInt64
    public var leafDirectoriesLength: UInt64
    public var tileDataOffset: UInt64
    public var tileDataLength: UInt64
    /// Absent when the archive stores 0 ("unknown").
    public var addressedTilesCount: UInt64?
    public var tileEntriesCount: UInt64?
    public var tileContentsCount: UInt64?
    public var clustered: Bool
    public var internalCompression: Compression
    public var tileCompression: Compression
    public var tileType: TileType
    public var minZoom: UInt8
    public var maxZoom: UInt8
    public var bounds: BBox
    public var centerZoom: UInt8
    public var center: LonLat
}

/// One directory entry. `runLength == 0` marks a leaf-directory pointer.
public struct Entry: Sendable, Equatable, Hashable {
    public var tileId: UInt64
    public var offset: UInt64
    public var length: UInt32
    public var runLength: UInt32
    public init(tileId: UInt64, offset: UInt64, length: UInt32, runLength: UInt32) {
        self.tileId = tileId; self.offset = offset; self.length = length; self.runLength = runLength
    }
}

/// A tile coordinate.
public struct TileCoord: Sendable, Equatable, Hashable {
    public var z: UInt8
    public var x: UInt32
    public var y: UInt32
    public init(z: UInt8, x: UInt32, y: UInt32) { self.z = z; self.x = x; self.y = y }
}

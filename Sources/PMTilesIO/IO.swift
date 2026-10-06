// io layer from the pmtiles spec §3: byte sources, decompression, get_tile and
// read_metadata. Format logic stays in the PMTiles core module.

@_exported import PMTiles

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Anything that can return a byte range: memory, a file, an HTTP server.
public protocol ByteSource: Sendable {
    /// Returns up to `length` bytes starting at `offset` (fewer only at end of source).
    /// Failures are `PMTilesError(.io, "pmtiles.source_failed")`.
    func read(offset: UInt64, length: UInt64) async throws(PMTilesError) -> [UInt8]
}

/// An archive already in memory.
public struct MemorySource: ByteSource {
    public let bytes: [UInt8]
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public func read(offset: UInt64, length: UInt64) async throws(PMTilesError) -> [UInt8] {
        slice(offset: offset, length: length)
    }

    @inline(__always) func slice(offset: UInt64, length: UInt64) -> [UInt8] {
        let start = Int(min(offset, UInt64(bytes.count)))
        let end = Int(min(offset.addingReportingOverflow(length).overflow ? UInt64.max : offset + length, UInt64(bytes.count)))
        return Array(bytes[start..<end])
    }
}

/// A local file, read with `pread` (no shared file position, so it's safe to share).
public final class FileSource: ByteSource {
    private let fd: Int32

    public init(path: String) throws(PMTilesError) {
        fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw PMTilesError(.io, "pmtiles.source_failed") }
    }

    deinit { close(fd) }

    public func read(offset: UInt64, length: UInt64) async throws(PMTilesError) -> [UInt8] {
        guard length <= UInt64(Int.max), offset <= UInt64(Int64.max) else {
            throw PMTilesError(.io, "pmtiles.source_failed")
        }
        let total = Int(length)
        var buf = [UInt8](repeating: 0, count: total)
        var done = 0
        while done < total {
            let n = buf.withUnsafeMutableBytes { p in
                pread(fd, p.baseAddress! + done, total - done, off_t(offset) + off_t(done))
            }
            if n < 0 { throw PMTilesError(.io, "pmtiles.source_failed") }
            if n == 0 { break }  // end of file
            done += n
        }
        buf.removeLast(buf.count - done)
        return buf
    }
}

// MARK: - Decompression

/// Decompresses internal data (directories, metadata). `none` and `gzip` are supported;
/// anything else is `pmtiles.unsupported_compression`. Output is capped at `limit` bytes,
/// and exceeding it is `limitCode`. A stream that doesn't decode (including a gzip CRC-32
/// or length mismatch) is `pmtiles.decompression_failed` (spec D-006).
func decompress(_ data: [UInt8], _ compression: Compression, limit: UInt64, limitCode: String) throws(PMTilesError) -> [UInt8] {
    switch compression {
    case .none:
        return data
    case .gzip:
        do {
            return try gunzip(data, maxOutput: Int(min(limit, UInt64(Int.max))))
        } catch .tooLarge {
            throw PMTilesError(.limitExceeded, limitCode)
        } catch {
            throw PMTilesError(.invalidInput, "pmtiles.decompression_failed")
        }
    default:
        throw PMTilesError(.unsupported, "pmtiles.unsupported_compression")
    }
}

// MARK: - get_tile, read_metadata

private func readHeader(_ source: some ByteSource) async throws(PMTilesError) -> Header {
    try decodeHeader(try await source.read(offset: 0, length: 127))
}

private func readDirectory(
    _ source: some ByteSource, _ header: Header, offset: UInt64, length: UInt64, limits: Limits
) async throws(PMTilesError) -> [Entry] {
    guard length <= limits.maxDirectoryBytes else { throw PMTilesError(.limitExceeded, "pmtiles.directory_too_large") }
    let raw = try await source.read(offset: offset, length: length)
    guard UInt64(raw.count) == length else { throw PMTilesError(.invalidInput, "pmtiles.truncated") }
    let bytes = try decompress(raw, header.internalCompression, limit: limits.maxDirectoryBytes, limitCode: "pmtiles.directory_too_large")
    return try decodeDirectory(bytes: bytes, limits: limits)
}

private func lookup(
    _ source: some ByteSource, _ header: Header, root: [Entry], tileId: UInt64, limits: Limits
) async throws(PMTilesError) -> [UInt8]? {
    var entries = root
    var depth: UInt32 = 0
    while true {
        guard let e = findEntry(entries, tileId: tileId) else { return nil }
        if e.runLength > 0 {
            let (start, overflow) = header.tileDataOffset.addingReportingOverflow(e.offset)
            guard !overflow else { throw PMTilesError(.invalidInput, "pmtiles.invalid_directory") }
            let tile = try await source.read(offset: start, length: UInt64(e.length))
            guard tile.count == Int(e.length) else { throw PMTilesError(.invalidInput, "pmtiles.truncated") }
            return tile
        }
        guard depth < limits.maxLeafDepth else { throw PMTilesError(.limitExceeded, "pmtiles.leaf_depth_exceeded") }
        depth += 1
        let (start, overflow) = header.leafDirectoriesOffset.addingReportingOverflow(e.offset)
        guard !overflow else { throw PMTilesError(.invalidInput, "pmtiles.invalid_directory") }
        entries = try await readDirectory(source, header, offset: start, length: UInt64(e.length), limits: limits)
    }
}

/// Spec operation `get_tile`: the tile's bytes, **still compressed** with the
/// archive's `tileCompression`, or `nil` when the archive has no such tile.
/// Stateless: reads the header and root directory on every call. To read many
/// tiles, open a `PMTilesReader`, which keeps them.
public func getTile(_ source: some ByteSource, _ coord: TileCoord, limits: Limits = Limits()) async throws(PMTilesError) -> [UInt8]? {
    let header = try await readHeader(source)
    let tileId = try zxyToTileId(coord)
    let root = try await readDirectory(source, header, offset: header.rootDirectoryOffset, length: header.rootDirectoryLength, limits: limits)
    return try await lookup(source, header, root: root, tileId: tileId, limits: limits)
}

/// Spec operation `read_metadata`: the archive's JSON metadata as text, unparsed. Metadata
/// that isn't well-formed UTF-8 is `pmtiles.invalid_metadata` (spec D-007), never repaired.
public func readMetadata(_ source: some ByteSource, limits: Limits = Limits()) async throws(PMTilesError) -> String {
    let header = try await readHeader(source)
    guard header.metadataLength <= limits.maxMetadataBytes else {
        throw PMTilesError(.limitExceeded, "pmtiles.metadata_too_large")
    }
    let raw = try await source.read(offset: header.metadataOffset, length: header.metadataLength)
    guard UInt64(raw.count) == header.metadataLength else { throw PMTilesError(.invalidInput, "pmtiles.truncated") }
    let bytes = try decompress(raw, header.internalCompression, limit: limits.maxMetadataBytes, limitCode: "pmtiles.metadata_too_large")
    // The standard library's UTF-8 decoder is strict (no overlong forms or encoded
    // surrogates), and this works on every supported OS, unlike String(validating:).
    let invalid = transcode(bytes.makeIterator(), from: UTF8.self, to: UTF8.self, stoppingOnError: true) { _ in }
    guard !invalid else { throw PMTilesError(.invalidInput, "pmtiles.invalid_metadata") }
    return String(decoding: bytes, as: UTF8.self)
}

/// A caller-owned reader that keeps the header and root directory after opening, for
/// reading many tiles. Leaf directories are read per lookup (no hidden cache).
public struct PMTilesReader<Source: ByteSource>: Sendable {
    public let source: Source
    public let header: Header
    public let limits: Limits
    private let root: [Entry]

    public init(_ source: Source, limits: Limits = Limits()) async throws(PMTilesError) {
        self.source = source
        self.limits = limits
        header = try await readHeader(source)
        root = try await readDirectory(source, header, offset: header.rootDirectoryOffset, length: header.rootDirectoryLength, limits: limits)
    }

    /// Same result as `getTile(source, coord)`, without re-reading the header and root.
    public func tile(_ coord: TileCoord) async throws(PMTilesError) -> [UInt8]? {
        try await lookup(source, header, root: root, tileId: try zxyToTileId(coord), limits: limits)
    }

    /// Same result as `readMetadata(source)`.
    public func metadata() async throws(PMTilesError) -> String {
        try await readMetadata(source, limits: limits)
    }
}

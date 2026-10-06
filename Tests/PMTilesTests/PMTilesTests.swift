import Foundation
import Testing
@testable import PMTiles
@testable import PMTilesIO

let small = [UInt8](FileManager.default.contents(atPath: ".spec/conformance/cases/archives/small.pmtiles")!)
let leaves = [UInt8](FileManager.default.contents(atPath: ".spec/conformance/cases/archives/leaves.pmtiles")!)

@Test func publishedTileIdVectors() throws {
    let vectors: [(UInt8, UInt32, UInt32, UInt64)] = [
        (0, 0, 0, 0), (1, 0, 0, 1), (1, 0, 1, 2), (1, 1, 1, 3), (1, 1, 0, 4), (2, 0, 0, 5), (3, 0, 0, 21), (12, 3423, 1763, 19_078_479),
    ]
    for (z, x, y, id) in vectors {
        #expect(try zxyToTileId(TileCoord(z: z, x: x, y: y)) == id)
        #expect(try tileIdToZxy(id) == TileCoord(z: z, x: x, y: y))
    }
    #expect(try tileIdToZxy(maxTileId).z == 31)
    #expect(throws: PMTilesError(.invalidInput, "pmtiles.invalid_zoom")) { try tileIdToZxy(maxTileId + 1) }
}

@Test func headerOfOracleArchive() throws {
    let h = try decodeHeader(small)
    #expect(h.internalCompression == .gzip && h.tileType == .unknown && h.clustered)
    #expect(h.minZoom == 0 && h.maxZoom == 3)
    #expect(abs(h.bounds.minLon - -74.259) < 1e-9)
}

@Test func unknownEnumsAreKept() throws {
    var b = Array(small.prefix(127))
    b[98] = 9
    b[99] = 42
    let h = try decodeHeader(b)
    #expect(h.tileCompression == .other(9) && h.tileType == .other(42))
    #expect(h.tileCompression.raw == 9)
}

@Test func leafDirectoriesAreFollowed() async throws {
    let reader = try await PMTilesReader(MemorySource(leaves))
    #expect(reader.header.leafDirectoriesLength > 0)
    let stateless = try await getTile(MemorySource(leaves), TileCoord(z: 7, x: 127, y: 127))
    #expect(stateless != nil)
    #expect(try await reader.tile(TileCoord(z: 7, x: 127, y: 127)) == stateless)
}

@Test func leafDepthIsBounded() async throws {
    // max_leaf_depth 0: following even one leaf pointer is an error.
    await #expect(throws: PMTilesError(.limitExceeded, "pmtiles.leaf_depth_exceeded")) {
        try await getTile(MemorySource(leaves), TileCoord(z: 0, x: 0, y: 0), limits: Limits(maxLeafDepth: 0))
    }
}

@Test(arguments: gzipVectors.map(\.name))
func gunzipRealDeflate(name: String) throws {
    let v = gzipVectors.first { $0.name == name }!
    let out = try gunzip([UInt8](Data(base64Encoded: v.gz)!), maxOutput: 1 << 24)
    #expect(out.count == v.count)
    #expect(crc32(out) == v.crc)
}

@Test func gunzipStopsAtTheLimit() throws {
    let bomb = [UInt8](Data(base64Encoded: gzipBomb)!)
    #expect(throws: InflateError.tooLarge) { try gunzip(bomb, maxOutput: 1 << 20) }
}

@Test func gunzipRejectsCorruption() throws {
    var gz = [UInt8](Data(base64Encoded: gzipVectors[0].gz)!)
    gz[gz.count - 9] ^= 0xFF  // last deflate byte
    #expect(throws: InflateError.self) { try gunzip(gz, maxOutput: 1 << 24) }
    var badCRC = [UInt8](Data(base64Encoded: gzipVectors[0].gz)!)
    badCRC[badCRC.count - 8] ^= 1
    #expect(throws: InflateError.corrupt) { try gunzip(badCRC, maxOutput: 1 << 24) }
}

@Test func metadataIsReturnedUnparsed() async throws {
    let json = try await readMetadata(MemorySource(small))
    #expect(json.contains("\"name\": \"small\""))
}

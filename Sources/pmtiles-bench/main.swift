// Benchmark per `.spec/bench/README.md`: load bench.pmtiles into a memory source; one
// pass = get_tile for all 10,000 coordinates in coords.txt; 3 warm-up + 15 timed passes;
// report median and min. The checksum (total returned bytes) must match the spec's.
//
//   swift run -c release pmtiles-bench [bench-dir]     (default .spec/bench)
//
// Measures both the stateless `getTile` and the caching `PMTilesReader`, which (like the
// Rust reference) keeps the header and root directory after opening.

import Foundation
import PMTilesIO

let dir = CommandLine.arguments.dropFirst().first ?? ".spec/bench"
let checksum = 998_434
guard let archive = FileManager.default.contents(atPath: "\(dir)/bench.pmtiles"),
      let coordsText = try? String(contentsOfFile: "\(dir)/coords.txt", encoding: .utf8) else {
    print("cannot read \(dir)/bench.pmtiles and coords.txt")
    exit(2)
}
let coords = coordsText.split(separator: "\n").map { line -> TileCoord in
    let p = line.split(separator: "/").map { UInt32($0)! }
    return TileCoord(z: UInt8(p[0]), x: p[1], y: p[2])
}
let source = MemorySource([UInt8](archive))

func measure(_ name: String, _ pass: () async throws -> Int) async throws {
    var ms = [Double]()
    for run in 0..<18 {
        let start = DispatchTime.now().uptimeNanoseconds
        let total = try await pass()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        precondition(total == checksum, "checksum \(total) != \(checksum): wrong bytes returned")
        if run >= 3 { ms.append(elapsed) }
    }
    ms.sort()
    print("pmtiles swift \(name) (\(coords.count) lookups): get_tile pass median "
        + String(format: "%.3f ms (min %.3f), checksum %d ok", ms[7], ms[0], checksum))
}

try await measure("stateless getTile") {
    var total = 0
    for c in coords { total += try await getTile(source, c)?.count ?? 0 }
    return total
}
let reader = try await PMTilesReader(source)
try await measure("PMTilesReader") {
    var total = 0
    for c in coords { total += try await reader.tile(c)?.count ?? 0 }
    return total
}

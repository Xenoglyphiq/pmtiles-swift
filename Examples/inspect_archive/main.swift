// Canonical example `inspect_archive`: decode a local archive's header and print it.
// Usage: swift run inspect_archive [path]
import Foundation
import PMTiles

let path = CommandLine.arguments.dropFirst().first ?? ".spec/conformance/cases/archives/small.pmtiles"
guard let file = FileHandle(forReadingAtPath: path) else {
    print("cannot open \(path)")
    exit(1)
}
let first127 = [UInt8](file.readData(ofLength: 127))
do {
    let h = try decodeHeader(first127)
    print("zooms \(h.minZoom)-\(h.maxZoom), tile type \(h.tileType), tile compression \(h.tileCompression)")
    print("bounds lon \(h.bounds.minLon)...\(h.bounds.maxLon), lat \(h.bounds.minLat)...\(h.bounds.maxLat)")
    print("center (\(h.center.lon), \(h.center.lat)) at zoom \(h.centerZoom)")
} catch {
    print("not a PMTiles v3 archive: \(error)")
    exit(1)
}

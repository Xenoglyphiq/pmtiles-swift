// Canonical example `fetch_one_tile`: read one tile by z/x/y from a local archive.
// Usage: swift run fetch_one_tile [path] [z/x/y]
import PMTilesIO

let args = Array(CommandLine.arguments.dropFirst())
let path = args.first ?? ".spec/conformance/cases/archives/small.pmtiles"
let parts = (args.count > 1 ? args[1] : "2/1/3").split(separator: "/").compactMap { UInt32($0) }
let coord = TileCoord(z: UInt8(parts[0]), x: parts[1], y: parts[2])

do {
    let source = try FileSource(path: path)
    if let tile = try await getTile(source, coord) {
        print("\(coord.z)/\(coord.x)/\(coord.y): \(tile.count) bytes")
    } else {
        print("\(coord.z)/\(coord.x)/\(coord.y): not found")
    }
} catch {
    print("error: \(error)")
}

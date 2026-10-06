// Canonical example `remote_metadata`: read an archive's metadata over HTTP range requests.
// Usage: swift run remote_metadata [url]
import Foundation
import PMTilesIO

let url = URL(string: CommandLine.arguments.dropFirst().first ?? "https://pmtiles.io/protomaps(vector)ODbL_firenze.pmtiles")!
do {
    print(try await readMetadata(HTTPSource(url: url)))
} catch {
    print("error: \(error)")
}

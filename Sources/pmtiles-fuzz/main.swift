// Mutation fuzzer for every decoder of untrusted input: decodeHeader, decodeDirectory,
// gunzip, and getTile / readMetadata over a mutated archive. Shared design: corpus = the
// conformance inputs and archives; 1-4 random mutations per iteration; time-boxed.
//
//   FUZZ_SECONDS=600 swift run -c release pmtiles-fuzz
//   FUZZ_SEED=<n> reproduces a run; FUZZ_TRACE=<path> writes each input before running it,
//   so after a crash the file holds the input that caused it.
//
// Optimized Swift builds keep overflow and bounds checks, so a missing guard traps.
// Invariants beyond "no trap": decoded directories have strictly increasing ids, and
// tiles returned by getTile are never longer than the archive.

import Foundation
import PMTiles
import PMTilesIO

let seconds = Double(ProcessInfo.processInfo.environment["FUZZ_SECONDS"] ?? "10") ?? 10
let seed = UInt64(ProcessInfo.processInfo.environment["FUZZ_SEED"] ?? "") ?? UInt64(Date().timeIntervalSince1970 * 1000)
let tracePath = ProcessInfo.processInfo.environment["FUZZ_TRACE"]
print("fuzz: seed \(seed), \(seconds) s")

/// SplitMix64: small, fast, reproducible.
struct Rng {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
}
var rng = Rng(state: seed)

// Corpus: conformance inputs plus the archives and their internal pieces.
let casesDir = ".spec/conformance/cases"
func file(_ p: String) -> [UInt8] { [UInt8](FileManager.default.contents(atPath: "\(casesDir)/\(p)") ?? Data()) }
let archives = ["archives/small.pmtiles", "archives/leaves.pmtiles", "archives/small-uncompressed.pmtiles"].map(file)
var corpus: [[UInt8]] = archives + [file("header/small.bin"), file("directory/leaf0.bin")]
for a in archives {
    if let h = try? decodeHeader(a) {
        let root = Array(a[Int(h.rootDirectoryOffset)..<Int(h.rootDirectoryOffset + h.rootDirectoryLength)])
        corpus.append(root)
        if let raw = try? gunzip(root, maxOutput: 1 << 24) { corpus.append(raw) }
    }
}
precondition(corpus.allSatisfy { !$0.isEmpty }, "run from the repo root: corpus files not found")

func mutate(_ input: [UInt8], _ rng: inout Rng) -> [UInt8] {
    var s = input
    for _ in 0...rng.below(4) {
        switch rng.below(6) {
        case 0 where !s.isEmpty: s[rng.below(s.count)] ^= UInt8(1 + rng.below(255))
        case 1: s.insert(rng.below(2) == 0 ? UInt8(rng.below(128)) : UInt8(rng.below(256)), at: rng.below(s.count + 1))
        case 2 where !s.isEmpty: s.remove(at: rng.below(s.count))
        case 3 where !s.isEmpty:
            let a = rng.below(s.count), b = min(s.count, a + 1 + rng.below(64))
            s.append(contentsOf: s[a..<b])
        case 4 where !s.isEmpty: s.removeLast(rng.below(s.count))
        default: s.append(contentsOf: repeatElement(0xFF, count: 1 + rng.below(16)))
        }
        if s.count > 300_000 { s.removeLast(s.count - 300_000) }
    }
    return s
}

let small = Limits(maxDirectoryEntries: 100_000, maxDirectoryBytes: 1 << 22, maxMetadataBytes: 1 << 22)
let deadline = Date().addingTimeInterval(seconds)
var iterations = 0
while Date() < deadline {
    for _ in 0..<256 {
        let input = mutate(corpus[rng.below(corpus.count)], &rng)
        if let tracePath { FileManager.default.createFile(atPath: tracePath, contents: Data(input)) }
        iterations += 1

        _ = try? decodeHeader(input)
        if let entries = try? decodeDirectory(input, limits: small) {
            precondition(zip(entries, entries.dropFirst()).allSatisfy { $0.tileId < $1.tileId }, "ids not increasing")
        }
        _ = try? gunzip(input, maxOutput: 1 << 22)
        let z = UInt8(rng.below(9))
        let size = 1 << Int(z)
        let coord = TileCoord(z: z, x: UInt32(rng.below(size)), y: UInt32(rng.below(size)))
        if let tile = try? await getTile(MemorySource(input), coord, limits: small) {
            precondition(tile.count <= input.count, "tile longer than the archive")
        }
        _ = try? await readMetadata(MemorySource(input), limits: small)
    }
}
print("fuzz: \(iterations) iterations in \(seconds) s, clean")

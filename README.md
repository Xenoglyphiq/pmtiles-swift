# PMTiles for Swift

Read [PMTiles v3](https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md) single-file tile archives: header, directories, tile lookup and tile bytes, from memory, a file, or HTTP range requests. Implements the pmtiles spec · Spec v0.1.0 · Conformance: **core ✓ io ✓ full ✓** (68/68)

Swift tools 6.0 · iOS 16 / macOS 13 / Linux. **No dependencies.** gzip is decoded by a small built-in inflate, so io works the same on Apple platforms and Linux.

## Install

> **Not released yet.** Until the first release, depend on `main`:
> `.package(url: "https://github.com/Xenoglyphiq/pmtiles-swift", branch: "main")`

Once released:

```swift
.package(url: "https://github.com/Xenoglyphiq/pmtiles-swift", from: "0.1.0")
```

Then add `PMTiles` (core) and/or `PMTilesIO` (sources, `getTile`, `readMetadata`) to your target.

## Quick start

```swift
import PMTilesIO

let source = try FileSource(path: "nyc.pmtiles")
if let tile = try await getTile(source, TileCoord(z: 14, x: 4825, y: 6156)) {
    // tile bytes, still compressed with the archive's tileCompression
}
```

To read many tiles, open a `PMTilesReader`, which keeps the header and root directory:

```swift
let reader = try await PMTilesReader(source)
let tile = try await reader.tile(TileCoord(z: 14, x: 4825, y: 6156))
```

## Examples

Each runs with `swift run <name>`.

### 1. Print an archive's header (`Examples/inspect_archive`)
```swift
let h = try decodeHeader(first127Bytes)
print("zooms \(h.minZoom)-\(h.maxZoom), tile type \(h.tileType)")
```

### 2. Fetch one tile by z/x/y (`Examples/fetch_one_tile`)
```swift
let source = try FileSource(path: path)
if let tile = try await getTile(source, coord) { print("\(tile.count) bytes") } else { print("not found") }
```

### 3. Read metadata over HTTP (`Examples/remote_metadata`)
```swift
print(try await readMetadata(HTTPSource(url: url)))
```

## Limits and errors

| Limit | Default | Option |
|---|---|---|
| Directory entries | 1,000,000 | `Limits.maxDirectoryEntries` |
| One directory's bytes (compressed and decompressed) | 16 MiB | `Limits.maxDirectoryBytes` |
| Leaf-directory depth | 4 | `Limits.maxLeafDepth` |
| Metadata bytes | 16 MiB | `Limits.maxMetadataBytes` |

Errors are `PMTilesError` (typed throws) with a `kind` (`invalidInput`, `unsupported`, `limitExceeded`, `io`, …) and a stable `code` such as `pmtiles.bad_magic`. Full list: spec §3.

**Compression:** internal `none` and `gzip` are supported; `brotli` and `zstd` are `pmtiles.unsupported_compression`. Tile bytes are returned as stored; decompressing or decoding tiles is up to you.

**HTTP:** `HTTPSource` sends `Accept-Encoding: identity`. Some servers otherwise apply the range to a gzip-encoded copy of the file, which returns the wrong bytes.

## Modules

| Product | Layer | Needs |
|---|---|---|
| `PMTiles` | core | nothing: no Foundation |
| `PMTilesIO` | io | Foundation (FoundationNetworking on Linux) for `HTTPSource` only |

## Development

| Command | What |
|---|---|
| `swift test` | Unit tests, including real-deflate gzip vectors |
| `swift run pmtiles-conformance` | Every case in `.spec/conformance/manifest.json` |
| `FUZZ_SECONDS=60 swift run -c release pmtiles-fuzz` | Mutation-fuzz every decoder (`FUZZ_SEED` reproduces a run) |
| `swift run -c release pmtiles-bench` | Timings on `.spec/bench/` (method in `.spec/bench/README.md`) |

## Performance

| Benchmark | Reference | This port | Ratio |
|---|---|---|---|
| get_tile, 10,000 lookups | Rust `pmtiles` | — | — |

Recorded before v0.1.0.

## License

MIT OR Apache-2.0

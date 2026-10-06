// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PMTiles",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        // Core: decode headers and directories, tile ids, lookup. No Foundation.
        .library(name: "PMTiles", targets: ["PMTiles"]),
        // io: byte sources (memory, file, HTTP range), gzip, get_tile, read_metadata.
        .library(name: "PMTilesIO", targets: ["PMTilesIO"]),
    ],
    targets: [
        .target(name: "PMTiles"),
        .target(name: "PMTilesIO", dependencies: ["PMTiles"]),
        .testTarget(name: "PMTilesTests", dependencies: ["PMTiles", "PMTilesIO"]),

        // Tooling: conformance runner, mutation fuzzer, benchmark, canonical examples.
        .executableTarget(name: "pmtiles-conformance", dependencies: ["PMTiles", "PMTilesIO"]),
        .executableTarget(name: "pmtiles-fuzz", dependencies: ["PMTiles", "PMTilesIO"]),
        .executableTarget(name: "pmtiles-bench", dependencies: ["PMTiles", "PMTilesIO"]),
        .executableTarget(name: "inspect_archive", dependencies: ["PMTiles"], path: "Examples/inspect_archive"),
        .executableTarget(name: "fetch_one_tile", dependencies: ["PMTiles", "PMTilesIO"], path: "Examples/fetch_one_tile"),
        .executableTarget(name: "remote_metadata", dependencies: ["PMTilesIO"], path: "Examples/remote_metadata"),
    ]
)

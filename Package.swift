// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Nexus",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "NexusCore", targets: ["NexusCore"]),
        .library(name: "NexusModel", targets: ["NexusModel"]),
        .library(name: "NexusPersistence", targets: ["NexusPersistence"]),
        .library(name: "NexusGraph", targets: ["NexusGraph"]),
        .library(name: "NexusSearch", targets: ["NexusSearch"]),
        .library(name: "NexusProjects", targets: ["NexusProjects"]),
        .library(name: "ControlsPLC", targets: ["ControlsPLC"]),
    ],
    targets: [
        .target(name: "NexusCore"),
        .target(name: "NexusModel", dependencies: ["NexusCore"]),
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]
        ),
        .target(name: "NexusPersistence", dependencies: ["NexusCore", "NexusModel", "CSQLite"]),
        .target(name: "NexusGraph", dependencies: ["NexusCore", "NexusModel", "NexusPersistence"]),
        .target(name: "NexusSearch", dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusGraph"]),
        .target(name: "NexusProjects", dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusGraph"]),
        // Deterministic PLC engine, ported from the Controls Tech Trainer core.
        .target(name: "ControlsPLC"),
        .testTarget(name: "NexusCoreTests", dependencies: ["NexusCore"]),
        .testTarget(name: "NexusModelTests", dependencies: ["NexusModel"]),
        .testTarget(name: "NexusPersistenceTests", dependencies: ["NexusPersistence"]),
        .testTarget(name: "NexusGraphTests", dependencies: ["NexusGraph"]),
        .testTarget(name: "NexusSearchTests", dependencies: ["NexusSearch"]),
        .testTarget(name: "NexusProjectsTests", dependencies: ["NexusProjects", "NexusSearch"]),
        .testTarget(name: "ControlsPLCTests", dependencies: ["ControlsPLC"]),
    ]
)

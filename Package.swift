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
        .library(name: "NexusSimulation", targets: ["NexusSimulation"]),
        .library(name: "NexusInvestigation", targets: ["NexusInvestigation"]),
        .library(name: "NexusPermissions", targets: ["NexusPermissions"]),
        .library(name: "NexusAI", targets: ["NexusAI"]),
        .library(name: "NexusAgents", targets: ["NexusAgents"]),
        .library(name: "ControlsPLC", targets: ["ControlsPLC"]),
        .library(name: "ControlsReasoning", targets: ["ControlsReasoning"]),
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
        .target(name: "NexusPermissions", dependencies: ["NexusCore", "NexusModel"]),
        .target(name: "NexusProjects", dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusGraph", "NexusPermissions"]),
        .target(name: "NexusAI", dependencies: ["NexusCore", "NexusModel", "NexusPermissions"]),
        .target(
            name: "NexusAgents",
            dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusGraph", "NexusSearch", "NexusPermissions", "NexusAI", "NexusInvestigation"]
        ),
        .target(name: "NexusSimulation", dependencies: ["NexusCore", "NexusModel"]),
        .target(name: "NexusInvestigation", dependencies: ["NexusCore", "NexusModel", "NexusPersistence"]),
        // Deterministic PLC engine, ported from the Controls Tech Trainer core.
        .target(name: "ControlsPLC"),
        // Headless diagnostic reasoning, extracted from the trainer's UI target.
        .target(name: "ControlsReasoning", dependencies: ["ControlsPLC"]),
        .testTarget(name: "NexusCoreTests", dependencies: ["NexusCore"]),
        .testTarget(name: "NexusModelTests", dependencies: ["NexusModel"]),
        .testTarget(name: "NexusPersistenceTests", dependencies: ["NexusPersistence"]),
        .testTarget(name: "NexusGraphTests", dependencies: ["NexusGraph"]),
        .testTarget(name: "NexusSearchTests", dependencies: ["NexusSearch"]),
        .testTarget(name: "NexusProjectsTests", dependencies: ["NexusProjects", "NexusSearch"]),
        .testTarget(name: "NexusSimulationTests", dependencies: ["NexusSimulation"]),
        .testTarget(name: "NexusPermissionsTests", dependencies: ["NexusPermissions"]),
        .testTarget(name: "NexusAITests", dependencies: ["NexusAI"]),
        .testTarget(name: "NexusAgentsTests", dependencies: ["NexusAgents", "NexusInvestigation"]),
        .testTarget(name: "NexusInvestigationTests", dependencies: ["NexusInvestigation"]),
        // End-to-end Golden Vertical Slice (docs/BUILD_PLAN.md §D).
        .testTarget(
            name: "GoldenSliceTests",
            dependencies: ["NexusInvestigation", "NexusSimulation", "NexusProjects", "NexusSearch", "NexusGraph"]
        ),
        .testTarget(name: "ControlsPLCTests", dependencies: ["ControlsPLC"]),
        .testTarget(name: "ControlsReasoningTests", dependencies: ["ControlsReasoning", "ControlsPLC"]),
    ]
)

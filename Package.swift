// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Nexus",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
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
        .library(name: "NexusEngineering", targets: ["NexusEngineering"]),
        .library(name: "NexusLearning", targets: ["NexusLearning"]),
        .library(name: "NexusReality", targets: ["NexusReality"]),
        .library(name: "NexusDemo", targets: ["NexusDemo"]),
        .library(name: "NexusUI", targets: ["NexusUI"]),
        .library(name: "NexusMeetings", targets: ["NexusMeetings"]),
        .library(name: "NexusAppleIntelligence", targets: ["NexusAppleIntelligence"]),
        .library(name: "NexusRealityKit", targets: ["NexusRealityKit"]),
        .library(name: "ControlsPLC", targets: ["ControlsPLC"]),
        .library(name: "ControlsReasoning", targets: ["ControlsReasoning"]),
        .library(name: "ControlsSimulation", targets: ["ControlsSimulation"]),
        .library(name: "ControlsTraining", targets: ["ControlsTraining"]),
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
        .target(name: "NexusPermissions", dependencies: ["NexusCore", "NexusModel", "NexusPersistence"]),
        .target(name: "NexusProjects", dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusGraph", "NexusPermissions"]),
        .target(name: "NexusAI", dependencies: ["NexusCore", "NexusModel", "NexusPermissions"]),
        .target(
            name: "NexusAgents",
            dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusGraph", "NexusSearch", "NexusPermissions", "NexusAI", "NexusInvestigation"]
        ),
        .target(name: "NexusSimulation", dependencies: ["NexusCore", "NexusModel"]),
        .target(name: "NexusInvestigation", dependencies: ["NexusCore", "NexusModel", "NexusPersistence"]),
        .target(
            name: "NexusEngineering",
            dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusInvestigation", "ControlsPLC", "ControlsReasoning"]
        ),
        .target(
            name: "NexusLearning",
            dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusInvestigation", "NexusSimulation"]
        ),
        .target(name: "NexusReality", dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusGraph", "NexusSimulation"]),
        .target(
            name: "NexusDemo",
            dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusGraph", "NexusProjects", "NexusInvestigation", "NexusSimulation"]
        ),
        // Apple-only: empty on Linux, verify in Xcode.
        .target(name: "NexusRealityKit", dependencies: ["NexusCore", "NexusReality"]),
        .target(name: "NexusMeetings", dependencies: ["NexusCore", "NexusModel", "NexusPersistence"]),
        // Apple-only SwiftUI app layer: empty on Linux, compiled by the macOS CI job.
        .target(
            name: "NexusUI",
            dependencies: [
                "NexusCore", "NexusModel", "NexusPersistence", "NexusGraph", "NexusSearch", "NexusProjects", "NexusPermissions",
                "NexusInvestigation", "NexusSimulation", "NexusReality", "NexusRealityKit", "NexusAgents", "NexusDemo",
            ]
        ),
        // Apple-only: Siri/Shortcuts, Spotlight, Visual Intelligence, speech, Live Activities, Foundation Models.
        .target(
            name: "NexusAppleIntelligence",
            dependencies: [
                "NexusCore", "NexusModel", "NexusPersistence", "NexusSearch", "NexusProjects", "NexusPermissions",
                "NexusInvestigation", "NexusMeetings", "NexusAgents", "NexusAI", "NexusUI",
            ]
        ),
        // Deterministic PLC engine, ported from the Controls Tech Trainer core.
        .target(name: "ControlsPLC"),
        // Headless diagnostic reasoning, extracted from the trainer's UI target.
        .target(name: "ControlsReasoning", dependencies: ["ControlsPLC"]),
        // Plant, machine and electrical simulation, ported verbatim from the trainer.
        .target(name: "ControlsSimulation", dependencies: ["ControlsPLC"]),
        // Headless curriculum, scenario, campaign, certification and lab logic from the trainer's UI target.
        .target(name: "ControlsTraining", dependencies: ["ControlsPLC", "ControlsSimulation"]),
        .testTarget(name: "NexusCoreTests", dependencies: ["NexusCore"]),
        .testTarget(name: "NexusModelTests", dependencies: ["NexusModel"]),
        .testTarget(name: "NexusPersistenceTests", dependencies: ["NexusPersistence"]),
        .testTarget(name: "NexusGraphTests", dependencies: ["NexusGraph"]),
        .testTarget(name: "NexusSearchTests", dependencies: ["NexusSearch"]),
        .testTarget(name: "NexusProjectsTests", dependencies: ["NexusProjects", "NexusSearch"]),
        .testTarget(name: "NexusSimulationTests", dependencies: ["NexusSimulation"]),
        .testTarget(name: "NexusPermissionsTests", dependencies: ["NexusPermissions", "NexusPersistence"]),
        .testTarget(name: "NexusAITests", dependencies: ["NexusAI"]),
        .testTarget(name: "NexusAgentsTests", dependencies: ["NexusAgents", "NexusInvestigation"]),
        .testTarget(name: "NexusEngineeringTests", dependencies: ["NexusEngineering", "ControlsReasoning", "ControlsPLC"]),
        .testTarget(name: "NexusLearningTests", dependencies: ["NexusLearning"]),
        .testTarget(name: "NexusRealityTests", dependencies: ["NexusReality", "NexusProjects"]),
        .testTarget(name: "NexusDemoTests", dependencies: ["NexusDemo", "NexusSearch"]),
        .testTarget(name: "NexusMeetingsTests", dependencies: ["NexusMeetings"]),
        .testTarget(name: "NexusInvestigationTests", dependencies: ["NexusInvestigation"]),
        // End-to-end Golden Vertical Slice (docs/BUILD_PLAN.md §D).
        .testTarget(
            name: "GoldenSliceTests",
            dependencies: ["NexusInvestigation", "NexusSimulation", "NexusProjects", "NexusSearch", "NexusGraph", "NexusLearning", "NexusReality"]
        ),
        .testTarget(name: "ControlsPLCTests", dependencies: ["ControlsPLC"]),
        .testTarget(name: "ControlsReasoningTests", dependencies: ["ControlsReasoning", "ControlsPLC"]),
        .testTarget(name: "ControlsSimulationTests", dependencies: ["ControlsSimulation", "ControlsPLC"]),
        .testTarget(
            name: "ControlsTrainingTests",
            dependencies: ["ControlsTraining", "ControlsReasoning", "ControlsSimulation", "ControlsPLC"]
        ),
    ]
)

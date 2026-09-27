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
        .library(name: "NexusCloudProviders", targets: ["NexusCloudProviders"]),
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
        .library(name: "NexusModelRegistry", targets: ["NexusModelRegistry"]),
        .library(name: "NexusTrainingData", targets: ["NexusTrainingData"]),
        .executable(name: "NexusDatasetGen", targets: ["NexusDatasetGen"]),
        .library(name: "NexusTasks", targets: ["NexusTasks"]),
        .library(name: "NexusDocuments", targets: ["NexusDocuments"]),
        .library(name: "NexusMeasurement", targets: ["NexusMeasurement"]),
    ],
    targets: [
        .target(name: "NexusCore"),
        .target(name: "NexusModel", dependencies: ["NexusCore"]),
        // No pkgConfig: the module map links the platform's own libsqlite3
        // (Apple SDKs, Ubuntu's libsqlite3-dev). pkg-config on a Mac finds
        // Homebrew's single-architecture build and breaks simulator links.
        .systemLibrary(name: "CSQLite"),
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
        // Optional cloud models (L4). Plain HTTP, so it builds and tests on Linux.
        .target(name: "NexusCloudProviders", dependencies: ["NexusAI", "NexusCore", "NexusModel"]),
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
        .target(name: "NexusTasks", dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusGraph"]),
        .target(name: "NexusDocuments", dependencies: ["NexusCore", "NexusModel", "NexusPersistence"]),
        // Units, uncertainty and instruments, with adapters for the trainer's evidence types.
        .target(name: "NexusMeasurement", dependencies: ["NexusCore", "NexusModel", "ControlsPLC", "ControlsReasoning"]),
        // Large-graph timings (docs/PERFORMANCE.md). Not part of `swift test`: `swift run -c release NexusBenchmarks`.
        .executableTarget(name: "NexusBenchmarks", dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusGraph"]),
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
        .testTarget(name: "NexusCloudProvidersTests", dependencies: ["NexusCloudProviders", "NexusAI"]),
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
        // Versioned manifest of trained adapters/weights and the eval promotion gate (§F3).
        .target(name: "NexusModelRegistry", dependencies: ["NexusCore", "NexusAI"]),
        // Seeded training-data generation and evaluation for the local models (§F3).
        .target(
            name: "NexusTrainingData",
            dependencies: [
                "NexusCore", "NexusModel", "NexusPersistence", "NexusGraph", "NexusSearch", "NexusSimulation", "NexusInvestigation",
                "NexusAgents", "NexusModelRegistry", "ControlsPLC", "ControlsReasoning",
            ]
        ),
        .executableTarget(name: "NexusDatasetGen", dependencies: ["NexusTrainingData"]),
        .testTarget(name: "NexusModelRegistryTests", dependencies: ["NexusModelRegistry"]),
        .testTarget(
            name: "NexusTrainingDataTests",
            dependencies: ["NexusTrainingData", "NexusModelRegistry", "NexusAgents", "NexusAI", "NexusPermissions", "NexusSimulation"]
        ),
        .testTarget(name: "NexusTasksTests", dependencies: ["NexusTasks"]),
        .testTarget(name: "NexusDocumentsTests", dependencies: ["NexusDocuments"]),
        .testTarget(name: "NexusMeasurementTests", dependencies: ["NexusMeasurement", "ControlsReasoning", "ControlsPLC"]),
    ]
)

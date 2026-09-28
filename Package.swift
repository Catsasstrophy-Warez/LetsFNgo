// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Nexus",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
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
        .library(name: "NexusVisualization", targets: ["NexusVisualization"]),
        .library(name: "NexusTelemetry", targets: ["NexusTelemetry"]),
        .library(name: "NexusResearch", targets: ["NexusResearch"]),
        .library(name: "NexusActions", targets: ["NexusActions"]),
        .library(name: "NexusAutomotive", targets: ["NexusAutomotive"]),
        .library(name: "NexusAutomation", targets: ["NexusAutomation"]),
        .library(name: "NexusFinance", targets: ["NexusFinance"]),
        .library(name: "NexusSync", targets: ["NexusSync"]),
        .library(name: "NexusCommunications", targets: ["NexusCommunications"]),
    ],
    dependencies: [
        // AES-GCM for sync payloads off Apple platforms; Apple platforms use CryptoKit.
        // Held below 3.10: from 3.10 its BoringSSL is C++, and on Linux a C++ link
        // fails against Swift 6.2's libswiftObservation (undefined
        // swift::threading::fatal), which ControlsReasoning and NexusProjects import.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.9.0"..<"3.10.0")
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
            dependencies: [
                "NexusCore", "NexusModel", "NexusPersistence", "NexusGraph", "NexusSearch", "NexusPermissions", "NexusAI", "NexusInvestigation",
                "NexusTasks", "NexusDocuments", "NexusMeetings", "NexusResearch",
            ]
        ),
        // Optional cloud models (L4). Plain HTTP, so it builds and tests on Linux.
        .target(name: "NexusCloudProviders", dependencies: ["NexusAI", "NexusCore", "NexusModel"]),
        // ControlsSimulation supplies trainer physics wrapped as solvers (TrainerSolvers.swift).
        .target(name: "NexusSimulation", dependencies: ["NexusCore", "NexusModel", "ControlsSimulation"]),
        .target(name: "NexusInvestigation", dependencies: ["NexusCore", "NexusModel", "NexusPersistence"]),
        .target(
            name: "NexusEngineering",
            dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusInvestigation", "ControlsPLC", "ControlsReasoning"]
        ),
        .target(
            name: "NexusLearning",
            dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusInvestigation", "NexusSimulation", "NexusAutomotive"]
        ),
        .target(name: "NexusReality", dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusGraph", "NexusSimulation"]),
        .target(
            name: "NexusDemo",
            dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusGraph", "NexusProjects", "NexusInvestigation", "NexusSimulation"]
        ),
        // Apple-only: empty on Linux, verify in Xcode.
        .target(name: "NexusRealityKit", dependencies: ["NexusCore", "NexusModel", "NexusReality"]),
        .target(name: "NexusMeetings", dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusTasks"]),
        // Apple-only SwiftUI app layer: empty on Linux, compiled by the macOS CI job.
        .target(
            name: "NexusUI",
            dependencies: [
                "NexusCore", "NexusModel", "NexusPersistence", "NexusGraph", "NexusSearch", "NexusProjects", "NexusPermissions",
                "NexusInvestigation", "NexusSimulation", "NexusReality", "NexusRealityKit", "NexusAI", "NexusAgents", "NexusDemo",
                "NexusTasks", "NexusDocuments", "NexusMeetings", "NexusActions", "NexusResearch", "NexusLearning",
                "NexusVisualization", "NexusTelemetry", "NexusMeasurement", "NexusAutomotive",
                "NexusAutomation", "NexusFinance", "NexusCommunications",
            ]
        ),
        // Apple-only: Siri/Shortcuts, Spotlight, Visual Intelligence, speech, Live Activities, Foundation Models.
        .target(
            name: "NexusAppleIntelligence",
            dependencies: [
                "NexusCore", "NexusModel", "NexusPersistence", "NexusSearch", "NexusProjects", "NexusPermissions",
                "NexusInvestigation", "NexusMeetings", "NexusAgents", "NexusAI", "NexusCloudProviders", "NexusUI",
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
        // Automation runtime: rules as `automation` objects, change-feed triggers, schedules and conditional tasks.
        .target(
            name: "NexusAutomation",
            dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusPermissions", "NexusProjects", "NexusTasks", "NexusActions"]
        ),
        // Units, uncertainty and instruments, with adapters for the trainer's evidence types.
        .target(name: "NexusMeasurement", dependencies: ["NexusCore", "NexusModel", "ControlsPLC", "ControlsReasoning"]),
        // Executes every command in NexusProjects/Commands.swift against the store and runtimes.
        .target(
            name: "NexusActions",
            dependencies: [
                "NexusCore", "NexusModel", "NexusPersistence", "NexusGraph", "NexusSearch", "NexusProjects", "NexusPermissions",
                "NexusInvestigation", "NexusTasks", "NexusDocuments", "NexusMeasurement", "NexusSimulation", "NexusLearning",
            ]
        ),
        // Large-graph timings (docs/PERFORMANCE.md). Not part of `swift test`: `swift run -c release NexusBenchmarks`.
        .executableTarget(name: "NexusBenchmarks", dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusGraph"]),
        .testTarget(name: "NexusCoreTests", dependencies: ["NexusCore"]),
        .testTarget(name: "NexusModelTests", dependencies: ["NexusModel"]),
        .testTarget(name: "NexusPersistenceTests", dependencies: ["NexusPersistence", "NexusCore", "NexusModel"]),
        .testTarget(name: "NexusGraphTests", dependencies: ["NexusGraph"]),
        .testTarget(name: "NexusSearchTests", dependencies: ["NexusSearch", "NexusCore", "NexusModel", "NexusPersistence", "NexusGraph"]),
        .testTarget(name: "NexusProjectsTests", dependencies: ["NexusProjects", "NexusSearch"]),
        .testTarget(name: "NexusSimulationTests", dependencies: ["NexusSimulation", "ControlsSimulation"]),
        .testTarget(name: "NexusPermissionsTests", dependencies: ["NexusPermissions", "NexusPersistence"]),
        .testTarget(name: "NexusAITests", dependencies: ["NexusAI"]),
        .testTarget(
            name: "NexusAgentsTests",
            dependencies: ["NexusAgents", "NexusInvestigation", "NexusTasks", "NexusDocuments", "NexusMeetings", "NexusResearch"]
        ),
        .testTarget(name: "NexusCloudProvidersTests", dependencies: ["NexusCloudProviders", "NexusAI"]),
        .testTarget(name: "NexusEngineeringTests", dependencies: ["NexusEngineering", "ControlsReasoning", "ControlsPLC"]),
        .testTarget(
            name: "NexusLearningTests",
            dependencies: [
                "NexusLearning", "NexusCore", "NexusModel", "NexusPersistence", "NexusInvestigation", "NexusSimulation", "NexusAutomotive",
            ]
        ),
        .testTarget(name: "NexusRealityTests", dependencies: ["NexusReality", "NexusProjects"]),
        .testTarget(
            name: "NexusDemoTests",
            dependencies: ["NexusDemo", "NexusSearch", "NexusActions", "NexusInvestigation", "NexusModel", "NexusPersistence", "NexusCore"]
        ),
        .testTarget(name: "NexusMeetingsTests", dependencies: ["NexusMeetings", "NexusTasks"]),
        .testTarget(name: "NexusInvestigationTests", dependencies: ["NexusInvestigation"]),
        // End-to-end Golden Vertical Slice (docs/BUILD_PLAN.md §D).
        .testTarget(
            name: "GoldenSliceTests",
            dependencies: [
                "NexusInvestigation", "NexusSimulation", "NexusProjects", "NexusSearch", "NexusGraph", "NexusLearning", "NexusReality",
                "NexusActions", "NexusDocuments", "NexusMeasurement", "NexusTasks",
            ]
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
                "NexusAgents", "NexusModelRegistry", "NexusAutomotive", "ControlsPLC", "ControlsReasoning",
            ]
        ),
        .executableTarget(name: "NexusDatasetGen", dependencies: ["NexusTrainingData"]),
        .testTarget(name: "NexusModelRegistryTests", dependencies: ["NexusModelRegistry"]),
        .testTarget(
            name: "NexusTrainingDataTests",
            dependencies: ["NexusTrainingData", "NexusModelRegistry", "NexusAgents", "NexusAI", "NexusPermissions", "NexusSimulation"]
        ),
        .testTarget(name: "NexusTasksTests", dependencies: ["NexusTasks"]),
        .testTarget(
            name: "NexusAutomationTests",
            dependencies: [
                "NexusAutomation", "NexusActions", "NexusCore", "NexusInvestigation", "NexusModel", "NexusPermissions", "NexusPersistence",
                "NexusProjects", "NexusTasks",
            ]
        ),
        .testTarget(name: "NexusDocumentsTests", dependencies: ["NexusDocuments"]),
        // Research over local sources: plan, discovery, classification, claims, contradictions, applicability, synthesis.
        .target(
            name: "NexusResearch",
            dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusAI", "NexusDocuments", "NexusInvestigation"]
        ),
        .testTarget(name: "NexusResearchTests", dependencies: ["NexusResearch", "NexusDocuments", "NexusAI", "NexusInvestigation"]),
        .testTarget(name: "NexusMeasurementTests", dependencies: ["NexusMeasurement", "ControlsReasoning", "ControlsPLC"]),
        // Visualization models and transforms; no UI, so it tests on Linux.
        .target(name: "NexusVisualization", dependencies: ["NexusCore"]),
        // Time-series storage on the canonical store (migration 5).
        .target(
            name: "NexusTelemetry",
            dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusSimulation", "NexusVisualization"]
        ),
        .testTarget(name: "NexusVisualizationTests", dependencies: ["NexusVisualization"]),
        .testTarget(
            name: "NexusTelemetryTests",
            dependencies: ["NexusTelemetry", "NexusPersistence", "NexusSimulation", "NexusVisualization", "NexusModel"]
        ),
        .testTarget(
            name: "NexusActionsTests",
            dependencies: [
                "NexusActions", "NexusDocuments", "NexusInvestigation", "NexusLearning", "NexusMeasurement", "NexusProjects", "NexusSimulation",
                "NexusTasks", "NexusAutomotive", "NexusCore", "NexusModel", "NexusPersistence",
            ]
        ),
        // Second domain (docs/decisions/0002-second-domain.md): garage, OBD-II/CAN, DTCs and the charging-system solver.
        .target(
            name: "NexusAutomotive",
            dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusSimulation", "NexusInvestigation"]
        ),
        .testTarget(
            name: "NexusAutomotiveTests",
            dependencies: ["NexusAutomotive", "NexusInvestigation", "NexusSimulation", "NexusPersistence", "NexusGraph"]
        ),
        // Finance domain (docs/FINANCE.md): accounts, statement import, categories, budgets, cash flow, scenarios, investments.
        .target(name: "NexusFinance", dependencies: ["NexusCore", "NexusModel", "NexusPersistence"]),
        .testTarget(name: "NexusFinanceTests", dependencies: ["NexusFinance", "NexusCore", "NexusModel", "NexusPersistence"]),
        // Transport-independent sync (docs/decisions/0001-sync-backup-encryption.md): engine, transports, payload encryption.
        .target(
            name: "NexusSync",
            dependencies: [
                "NexusCore", "NexusModel", "NexusPersistence",
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .android, .windows])),
            ]
        ),
        .testTarget(name: "NexusSyncTests", dependencies: ["NexusSync", "NexusPersistence", "NexusModel", "NexusCore"]),
        // Email and message threads as objects (docs/COMMUNICATIONS.md): .eml/.mbox import, mention links, sent records.
        .target(name: "NexusCommunications", dependencies: ["NexusCore", "NexusModel", "NexusPersistence", "NexusGraph", "NexusSearch"]),
        .testTarget(name: "NexusCommunicationsTests", dependencies: ["NexusCommunications", "NexusCore", "NexusModel", "NexusPersistence"]),
    ],
    // Swift 6 language mode everywhere: complete data-race checking.
    swiftLanguageModes: [.v6]
)

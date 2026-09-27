# Implementation Roadmap

## Foundation packages
- NexusCore
- NexusModel
- NexusPersistence
- NexusGraph
- NexusSearch
- NexusAI
- NexusAgents
- NexusAutomation
- NexusProjects
- NexusDocuments
- NexusResearch
- NexusTasks
- NexusVisualization
- NexusSimulation
- NexusReality
- NexusTelemetry
- NexusEngineering
- NexusAutomotive
- NexusFinance
- NexusTravel
- NexusLearning
- NexusCreative
- NexusUI
- NexusApp

Dependencies flow inward. Domain modules may not create private canonical truth stores.

## Phase 1 - Foundation
1. Stable ObjectID and canonical object protocol.
2. SQLite schema and migrations.
3. First-class relationship graph.
4. Event model and provenance.
5. Revision/version model.
6. Project runtime.
7. Exact + FTS search.
8. Context and selection runtime.

## Phase 2 - Experience shell
9. 18-screen SwiftUI shell.
10. Universal command system.
11. Desktop/iPad/iPhone adaptive navigation.
12. Inspector and object detail grammar.
13. List/collection system and contextual multi-selection.
14. Empty/error/progress state components.
15. Accessibility baseline.

## Phase 3 - Knowledge and research
16. Document/source model.
17. Claim/evidence ledger.
18. Research runtime.
19. Hybrid retrieval hooks (semantic retrieval remains modular).
20. Citation/provenance inspection.

## Phase 4 - Work and agents
21. Task/workflow runtime.
22. Agent runtime and orchestrator.
23. Permission framework.
24. Agent activity ledger.
25. Automation runtime.

## Phase 5 - Engineering core
26. Measurement engine.
27. Visualization engine.
28. Investigation/hypothesis engine.
29. Simulation clock/world state/subsystem interfaces.
30. RealityKit ObjectID bridge.
31. Metal telemetry renderer interfaces.

## Golden Vertical Slice
Diagnose an instrument-loop failure:
Home -> Project -> Equipment Object -> Source Research -> 3D View -> Investigation -> Measurement -> Hypothesis -> Simulation -> First Divergence -> Repair Procedure -> Verification -> Report -> Training Scenario -> Persistent Knowledge -> Save/Reload.

The slice must exercise documents, claims, provenance, object graph, tasks, agents, permissions, measurement, telemetry, investigation, simulation, RealityKit, report artifacts, learning, timeline, and persistence.

## Expansion after slice
- Email/meetings/calendar
- Personal finance/investment research
- Automotive diagnostics/tuning
- Travel/food/life planning
- Career/learning
- Creative image/video/audio/web/3D
- Commerce/CRM
- Broader engineering and digital-twin libraries

## Performance principles
- Local-first startup and core browsing.
- Lazy load heavy artifacts and 3D.
- Entity/model caches for RealityKit.
- Mesh instancing/material reuse/LOD/hysteresis for large spatial scenes.
- Metal only for data volumes SwiftUI/Swift Charts cannot efficiently handle.
- Simulation and rendering decoupled through snapshots.

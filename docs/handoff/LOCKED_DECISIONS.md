# Locked Decisions

## Product identity
Nexus is a unified AI operating environment, not a chatbot bundle and not a launcher for 36 separate mini-apps.

## Canonical organizing model
**Project -> Object -> Relationship -> Event -> Evidence -> Action**

- Objects own context.
- Projects organize objects.
- Agents act on objects.
- Artifacts communicate about objects.
- Conversations are one interface onto the model, never the canonical database.

## Truth model
Never silently collapse these:
- Recorded Truth: direct trusted external-system record.
- Observed Truth: measurement or human observation.
- Modeled Truth: simulation result.
- Claimed Truth: assertion by a source.
- Derived Truth: calculation/transformation.
- Display Truth: value shown by a device/UI.
- Agent Interpretation: AI conclusion.

## Provenance
Meaningful values support origin, timestamp, source, method, author/agent, confidence, transformation, dependencies, and revision.

## Platform
Apple-first native: iPhone, iPad, macOS. SwiftUI for primary UI; RealityKit for spatial/digital twin; Metal for high-throughput rendering only.

## Persistence
Local-first/offline-capable. SQLite canonical persistence, FTS5 for text retrieval. Graph relationships remain explicit structured records. Vector retrieval is modular, not the primary data model.

## UX
18 canonical screen families. Desktop uses Navigation + Context + Workspace + Intelligence. iPad is workspace-first with collapsible panels. iPhone is object/task-centric.

## Agents
Agents are capability bundles over the same world model. They do not own separate truth. Every execution follows Goal -> Plan -> Context -> Permission -> Tool -> Observation -> Replan -> Output -> Verification -> Provenance.

## Permissions
At minimum: Observe, Analyze, Create Draft, Modify Internal State, External Action, Sensitive/Irreversible. Policies can vary by agent, project, object type, action, data source, and external service.

## Engineering / simulation
One simulation clock and runtime. Subsystem solvers update modeled state. Measurements are observations of nodes/test points, not arbitrary scripted answers. RealityKit renders state. AI interprets state.

## Golden Vertical Slice
Do not fan out into every domain until the instrument-loop diagnostic slice works end-to-end and survives persistence/reload.

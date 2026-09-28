# NEXUS - Master Product Specification

## Vision
Nexus is an Apple-first native AI operating environment that unifies knowledge, projects, agents, engineering, finance, life planning, creativity, simulation, and automation around one canonical world model.

It is not a collection of 36 mini-apps. It is one environment capable of expressing 36 kinds of work.

## Six capability families
### Understand
Research, documents, knowledge, search.
### Organize
Projects, tasks, calendar, meetings, SOPs.
### Analyze
Finance, investments, engineering, data.
### Simulate
Digital twins, electrical, automotive, systems.
### Create
Writing, images, video, audio, web, 3D.
### Act
Agents, automations, communications, external tools.

## Core organizing model
Project -> Object -> Relationship -> Event -> Evidence -> Action.

## World model
Representative object classes include people, organizations, projects, goals, tasks, events, documents, sources, claims, decisions, messages, assets, media, locations, accounts, transactions, investments, vehicles, equipment, components, sensors, measurements, faults, procedures, simulations, experiments, models, agents, and workflows.

## Projects
Projects are bounded context over the global graph. A project can include mission, objectives, objects, people, knowledge, sources, work, events, decisions, agents, automations, artifacts, and outputs. Objects may participate in multiple projects without duplication.

## Context model
Context follows the selected object. Opening Documents, Diagnostics, Simulation, Research, or AI while viewing a component preserves the component identity automatically. The object becomes the navigation anchor.

## Truth and provenance
Recorded, observed, modeled, claimed, derived, display, and agent-interpreted truth remain distinct. Values support provenance and revision history.

## Experience architecture
18 canonical screen families: Command Center, Project, Search, Object Detail, Collection/List, Document, Research, Conversation, Meeting, Timeline, Task/Workflow, Calendar, Investigation/Diagnostics, Telemetry/Visualization, Simulation/Digital Twin, Creative Workspace, Agent Activity, Settings/Permissions.

## Interaction grammar
Find -> Select -> Inspect -> Understand -> Act -> Verify -> Preserve.

## Universal command surface
A global command system supports opening objects, searching, creating, analyzing, running simulations, starting investigations, delegating agents, generating artifacts, and invoking domain actions.

## AI
The assistant is contextual. It receives the active project/object/artifact selection. It may answer, generate an artifact, invoke an agent, propose an action, or manipulate the active medium subject to permission.

## Agents
Agents are specialized capability bundles over the shared model. Candidate specialists include Research, Document, Coding, Engineering, Diagnostic, Automotive, Finance, Investment, Career, Tutor, Project, Scheduling, Travel, Food, Writing, Design, Image, Video, Audio, 3D, Web, Commerce.

## Research
Question -> plan -> source discovery -> source classification -> evidence extraction -> claims -> contradiction detection -> configuration matching -> synthesis -> citation. Sources are classified by evidence quality and claims preserve applicability and counterevidence.

## Meetings
Meeting audio/transcript/notes can yield structured participants, statements, claims, decisions, commitments, tasks, and related objects. These are promoted into canonical objects rather than remaining trapped in prose.

## Scheduling
Support fixed events, flexible work, and conditional tasks tied to future system states.

## Engineering and troubleshooting
The diagnostic workspace distinguishes System Truth, Display Truth, Evidence, Hypotheses, and Next Test. Hypothesis-driven diagnosis selects discriminating tests rather than following only static trees. First Divergence is a first-class concept.

## Measurement
A shared measurement/acquisition framework supports electrical/process/automotive/experimental observations with instrument, node/test point, units, accuracy, uncertainty, sampling, timestamp, and provenance.

## Automotive
Garage + maintenance + service documentation + OBD/CAN + DTC + live telemetry + performance analysis + calibration/log analysis + vehicle digital twin. UI supports Guided, Technician, Expert depth.

## Finance
Accounts, transactions, budgets, cash flow, investments, research, and scenarios. Recorded financial data remains separate from interpretations and forecasts.

## Creative
Artifacts preserve lineage across writing, images, audio, video, websites, social, campaigns, and 3D. AI operates on selected objects inside the creative medium and all agent edits are versioned.

## Visualization
A universal visualization layer supports values, gauges, tables, timelines, charts, scopes, spectra, heatmaps, maps, networks, Sankey diagrams, state graphs, and 3D overlays.

## Spatial/digital twin
RealityKit entities are projections of canonical objects. Digital twins combine identity, geometry, topology, state, physics, signals, telemetry, history, documents, procedures, faults, and evidence.

## Platform UX
Mac: Navigation + Context + Workspace + Intelligence.
iPad: workspace-first with collapsible context/intelligence.
iPhone: object/task-centric full-screen surfaces with contextual bottom actions.

## Storage/search
SQLite canonical persistence; FTS5 full-text retrieval; structured graph traversal; semantic retrieval modular; temporal and structured filtering; binary artifacts referenced from the database.

## Versioning
Mutable artifacts and agent edits preserve revisions, diffs where practical, authorship, instruction, and rollback.

## Swift package direction
NexusCore, NexusModel, NexusPersistence, NexusGraph, NexusSearch, NexusAI, NexusAgents, NexusAutomation, NexusProjects, NexusDocuments, NexusResearch, NexusTasks, NexusVisualization, NexusSimulation, NexusReality, NexusTelemetry, NexusEngineering, NexusAutomotive, NexusFinance, NexusTravel, NexusLearning, NexusCreative, NexusUI, NexusApp.

## Golden Vertical Slice
Diagnose an instrument-loop failure from Home -> Project -> Equipment -> Documents/Research -> 3D -> Investigation -> Measurement -> Hypothesis -> Simulation -> First Divergence -> Repair -> Verification -> Report -> Training -> Knowledge -> Save/Reload.

## Definition of success
The user experiences one coherent environment even when moving among radically different domains. Context persists. Identity persists. Evidence remains traceable. Agents remain accountable. Simulations remain separate from observations. Mobile feels native. The architecture can expand without creating parallel truth paths.

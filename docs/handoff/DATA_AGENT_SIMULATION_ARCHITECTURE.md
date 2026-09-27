# Data, Agent, Engineering, and Simulation Architecture

## Canonical object protocol
Every meaningful entity has stable identity, type, title, metadata, relationships, provenance, revisions, and lifecycle state.

Representative object types:
Person, Organization, Project, Objective, Task, Event, Message, Meeting, Document, Source, Claim, Decision, Artifact, Account, Transaction, Investment, Location, Trip, Reservation, Vehicle, Equipment, Component, Sensor, Signal, Measurement, Fault, Procedure, Investigation, Hypothesis, Experiment, Simulation, Model, Media, Image, Video, Audio, Scene, Website, Agent, Workflow, Automation, Action.

## Relationship model
Relationships are first-class and can carry metadata, provenance, validity interval, confidence, and revision. Examples: contains, belongsTo, produced, supports, contradicts, testedBy, confirms, attended, created, blocks, dependsOn, measuredAt, derivedFrom, represents.

## Events
Events reconstruct temporal reality. Equipment state transitions, measurements, messages, meetings, agent actions, user edits, repairs, approvals, and simulation events should be representable in a common event timeline.

## Claim/evidence ledger
Claim fields: statement, source(s), evidence passage/data, source class, configuration applicability, confidence, counterevidence, research date, dependencies, uses.

Source classes: Primary, Secondary, Tertiary, Community, Unknown.

## Measurement engine
One framework supports DMM, clamp meter, oscilloscope, calibrator, HART, OBD/CAN, process sensors, experimental data, and generic numeric observations. Engineering measurements include unit, accuracy, resolution, uncertainty, sample rate, range, test point, instrument, loading, timestamp, and provenance.

## Investigation engine
Symptom -> observations -> candidate causes -> hypotheses -> expected observations -> discriminating tests -> measurements -> logical/probabilistic update -> first divergence -> confirmed cause -> repair -> verification.

Hypotheses explicitly store supporting observations, contradictions, required observations, discriminating tests, safety constraints, and state (candidate/confirmed/rejected/unknown).

## Visualization engine
Value, Gauge, Line, Area, Bar, Scatter, Histogram, Heatmap, Scope, Spectrum, Table, Timeline, Map, Network, Sankey, StateGraph, 3DOverlay.

Swift Charts for ordinary charts. Metal for high-frequency telemetry, huge time series, scopes, spectrograms, dense heatmaps, and specialized overlays.

## Simulation runtime
SimulationClock -> WorldState -> Subsystem Solvers -> Events -> Measurements -> Snapshot.

Potential solvers: Electrical, Mechanical, Thermal, Process, Control, Vehicle, Economic, Environment. Simulation output is Modeled Truth and must never silently overwrite observed/recorded truth.

## Digital twin
Identity + Geometry + Topology + State + Physics + Signals + Telemetry + History + Documents + Procedures + Faults + Evidence.

RealityKit entities map to stable ObjectIDs. Selecting an entity selects the canonical object globally. 3D is a view of the model, not a separate database.

## Agent runtime
Orchestrator plus specialist capability bundles: Research, Document, Code, Engineering, Diagnostic, Automotive, Finance, Investment, Career, Tutor, Project, Scheduling, Travel, Food, Writing, Design, Image, Video, Audio, 3D, Web, Commerce.

Execution envelope:
Goal -> Plan -> Context Resolution -> Permission Check -> Tool Execution -> Observation -> Replan -> Output -> Verification -> Provenance.

Agent activity must remain inspectable. Store goal, plan, inputs, tools/actions, evidence, outputs, errors, approvals, revisions, and costs/usage where available.

## Permission levels
P0 Observe
P1 Analyze
P2 Create Draft
P3 Modify Internal State
P4 External Action
P5 Sensitive/Irreversible

Policies can be always allow, ask once/session/project/every time, or never, scoped by agent/project/object/action/data source/service.

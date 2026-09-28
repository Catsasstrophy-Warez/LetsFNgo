# Feature audit: spec vs. code (2026-09-27)

## Update: after the build-out (same day)

Everything below this section is the original audit. This section records what the recommended order (1–9) changed. Linux items are tested in CI. Apple UI items compile in the macOS CI job and are covered by the iPhone UI tests. None has run on a device.

| Area | Now |
|---|---|
| Commands | **Built.** `NexusActions.ActionExecutor` performs every command. The UI runs them through `CommandRunner`, which gives a form for missing input, navigation to the result, classified errors and exports. |
| Measurement entry | **Built.** Unit validation, instrument accuracy turned into uncertainty, observed or display truth, and assessment against the investigation. |
| Investigation in the app | **Built.** Record reading, confirm or reject, system vs display truth, repair task, close, report and training scenario. |
| Event timeline | **Built.** The store logs edits, measurements, lifecycle changes and restores; investigations log confirm, reject, close, repair and verification; the simulation logs faults, thresholds and divergence. |
| Diff and restore | **Built.** Attribute-level diffs keep the truth class of each value. Restore writes a new revision and respects `TruthPolicy`. The Object Detail screen shows both. |
| Backup restore | **Built.** Validated, and blobs are included. |
| Store performance | **Built.** Statement cache, encoding once and pragmas give object inserts −39 % and lookups −18 %. FTS rank-before-join was measured slower and not applied. Background `perform` exists. |
| Screens | **Built.** All 18 families route to a real screen. Task, Calendar, Project, Document, Meeting, Research, Conversation and Creative are new; Command Center gained Now, Today and Watching. |
| Twin | **Built.** Components registered, input targets, links and truth-labelled overlays in 3D, follows the focus, simulation off the main thread. |
| Ask | **Built.** Streams text and steps, can be stopped, bounded by a privacy tier. Opt-in Claude with a Keychain key works on OS 26; Apple models on 27. |
| Agents | **Partial.** Seven specialists plus an orchestrator and `delegate` sub-runs. Also tools for tasks, documents, meetings and research; all permission scopes filled; grounding check (`unverified` status); structured output (`HypothesisDraft`); latency and cost. The spec's other 15 specialists (finance, travel, …) wait for their domains. |
| Research | **Built (local).** `NexusResearch` covers plan, discovery, classification, cited claims, contradictions, applicability and synthesis. Web sources are only a `SourceFetcher` protocol. |
| Documents | **Built.** PDF text via PDFKit, stored as its own blob so claims quote exact bytes; import and cite from the UI. |
| Meetings | **Built.** Participants as people, commitments with owners, tasks through `TaskRuntime`; recording and on-device transcription in the Meeting screen. Extraction is still keyword-based. |
| Visualization | **Built (model), partial (UI).** `NexusVisualization` models all 17 kinds, each with a table equivalent, plus LTTB, histogram, FFT spectrum, heatmap, scope trigger, Sankey, network layout, state graph and density modes. The UI draws line, gauge, histogram, spectrum and table. |
| Telemetry | **Built.** `NexusTelemetry` (migration 5) stores chunked time series, 1M samples in under 1 s. Modeled samples can't enter observed channels. |
| Errors and progress | **Built.** `ClassifiedError` (5 categories: what happened, what survived, next actions) is used across the UI. `WorkProgress` exists, and agent steps show live. |
| Simulation | **Partial.** Thermal and mechanical solvers, induction motor and contactor coil adapted from the trainer, events and async runs added. Economic, environment and vehicle-dynamics solvers are missing. |
| Second domain | **Built (core).** `NexusAutomotive` covers VIN, OBD-II Mode 01/03/07/09, ELM327, CAN/DBC, 48 DTCs, a charging-system solver and an end-to-end diagnosis. It has no UI yet. |
| Learning | **Built (headless).** Scenarios replay any domain through `ScenarioSimulator`: instrument loop, the automotive charging system (severity fitted to the case's readings) and a generic `SimulationRuntime` with solvers and faults. `generateTrainingScenario` takes the generic path when there is no loop. A Socratic `Tutor` hints in three levels (question, discriminating test, expected readings), is graded on the expert path, keeps the answer locked until three attempts, and writes only agent interpretation. SM-2 `reviewCard`s come from confirmed causes and their evidence, cited claims, procedure steps and DTC meanings, with due queues per project. A learner record keeps mastery per topic and recommends what to practise next. There's no UI yet, and the trainer's chapter-based spaced mastery isn't used, because it schedules by chapter rather than by date. |
| Finance | **Built (core).** `NexusFinance` covers `Money` (Decimal and currency; mixing currencies throws), CSV and OFX/QFX import (SGML and XML) as recorded truth pointing at the stored file, and dedup by FITID or hash. It also has rule-derived, model-interpreted and person-recorded categories, budgets with variance, cash flow and recurring detection. Scenarios produce modeled forecasts that never reach a recorded balance. Investments cover FIFO and average cost, gains from recorded prices, and allocation. It has no UI yet. |
| Own model | **Partial.** MLX LoRA pipeline (`Training/`), the evaluator, a registry `register` step behind the gate, and the gate proven in CI (`Training/smoke.sh`). No model has been trained; that needs an Apple silicon Mac. |
| Automation | **Built (runtime), no UI.** `NexusAutomation` stores rules as `automation` objects with triggers on events, measurement thresholds (hysteresis; observed and recorded only by default, never modeled), task status, attributes and schedules. Actions run commands, create tasks, queue agent goals as `agentRequest` objects and notify. Rules follow the change feed with a saved cursor per rule, so they don't fire twice after a reload. Each firing is one batch that rolls back on failure, logged as an `automationRun` event. There is a loop depth limit and a rate limit. P3 actions need a policy grant; P4 and P5 need a grant that names the automation and the action, and otherwise wait for a person to approve. Conditional tasks ("starts when TB-4 voltage > 20 V") start when their condition holds, and `TaskRuntime.conditions(for:)` gives the text. Schedules run from `tick(now:)`. The app doesn't start the runtime or a timer yet, and the Calendar doesn't show conditions yet. |
| Apple surfaces | **Built.** The Live Activity follows agent runs, speech transcribes in Meetings, nameplate photos search, Writing Tools are on in notes, meetings and artifacts. |

### Still unbuilt

- **Semantic search:** now **built** and tested on Linux. `VectorSemanticIndex` embeds each object's title and text attributes, including document passages, with `HashingEmbedder`. It hashes words, word pairs, character trigrams and a field-engineering synonym table, so "xmtr" finds a transmitter and "power supply" finds a PSU. Vectors are stored in migration 6 with a content hash, so a reload doesn't re-embed. The index follows the change feed in the background and drops deleted objects. It ranks by brute-force cosine with type and scope filters, and `SearchEngine.withVectors` fuses it with FTS. At 100k × 256 a query takes under 20 ms (release). Still left: `NLEmbeddingEmbedder` (Apple's sentence model) compiles but hasn't run on a device. Nothing in the app calls `withVectors` yet, and there's no ANN index beyond about 1M objects.
- **Automation in the app:** `NexusAutomation` is built, but the app doesn't start it or tick its schedules. There's no rule editor, the Calendar doesn't show start conditions, and nothing runs queued `agentRequest` goals.
- **Communications:** no EventKit, email or messages.
- **Rendering:** no Metal renderer, and no large-scale LOD or instancing in 3D.
- **Input methods:** no iPad Pencil markup and no iPhone swipe gestures. There's no high-contrast or reduced-motion work and no device accessibility audit.
- **Data safety:** no sync, no encryption at rest on macOS, and no revision history for relationships.
- **Domains:** finance is built as a core with no UI (`NexusFinance`, see `docs/FINANCE.md`): OFX/CSV import with dedup, rules and model categorisation, budgets, cash flow, recurring detection, modeled scenarios and investments. It still has no UI, no OFX investment statements and no finance agent. There are no travel, career, CRM, social or architecture domains. Creative has one text workflow, not media.
- **Automotive:** no UI, and no hardware OBD/CAN acquisition.
- **Own model:** a model trained on a Mac, and Core AI once `coreai-models` builds for the simulator.

---

This compares every feature in `docs/handoff/` with what the code actually does. Each item was checked in `Sources/` and `Tests/`, not taken from the roadmap. Status key:

- **Built:** works and is tested.
- **Partial:** part of it exists; the note says what's missing.
- **Library only:** built and tested, but nothing in the app, agents or intents uses it.
- **Stub:** declared or placeholder only.
- **Missing:** no code.

Apple-side code compiles in macOS CI, and one iPhone UI test runs in the simulator. None of it has run on a device.

## Summary

The foundation is solid. That covers:
- identity, truth and provenance
- the store, graph and search
- permissions and the agent envelope
- the investigation engine
- the headless Golden Slice

What's missing is mostly above that foundation:
- **Commands don't do anything.** Every palette and selection command only switches screens.
- **Six of the 18 screen families have no screen.**
- **No domain module exists** beyond the instrument loop.
- **Several finished libraries are never called:** tasks, documents, measurement, speech, OCR, the Live Activity and the Claude provider.
- **Our own model has a dataset and evaluator,** but no training scripts, no trained model and no local runtime.

## 1. World and truth (data layer)

| Feature | Status | Notes |
|---|---|---|
| UUIDv7 ObjectID | Built | |
| Canonical object (type, title, attributes, lifecycle, provenance, revision) | Built | One struct with an open `type` string. No lifecycle transition API and no hard delete. |
| Seven truth classes plus `TruthPolicy` | Built | Enforced on objects and attributes. Relationships and events are only partly guarded. |
| Provenance fields | Built | No separate `source` field; the source travels inside `Origin`. |
| Relationships (kinds, validity interval, confidence) | Built | All 14 kinds exist. Relationships have no revision history, and kinds carry no meaning (a `contradicts` link doesn't update a claim's counterevidence). |
| Object types | Partial | 24 declared, about 12 with behaviour. Person, Organization, Artifact, Fault, Simulation, Agent and Workflow are declared but unused. About 20 spec types are undeclared: Objective, Message, Account, Transaction, Investment, Location, Trip, Reservation, Vehicle, Experiment, Model, Media, Image, Video, Audio, Scene, Website, Automation, Action. |
| Event timeline | Partial | Only tasks, agents and investigations write events. Measurements, user edits, meetings, repairs, approvals and simulations don't. |
| Claim/evidence ledger | Partial | Has statement, sources, passages, source class, applicability, counterevidence and confidence. Missing: "uses", a supersede/revise flow, and a research date beyond the timestamp. |
| Revisions | Built | A full snapshot with author and instruction on every write. |
| Diffs and rollback/restore | Missing | |
| SQLite, WAL, migrations 1–4 (tested), FTS5, blobs, backup | Built | Missing: restore from backup, blob garbage collection, and a database reference from objects to blobs. |
| Graph traversal and shortest path | Built | One query per node; no recursive SQL. |
| Search: exact, full-text, structured, temporal, scope | Built | The temporal filter uses `updatedAt` only. |
| Semantic search | Stub | Protocol only; no embeddings anywhere. |
| Projects as bounded context | Built | Mission and objectives are plain strings. |
| Context follows selection | Built | |
| Selection-driven command lists | Built | The right commands appear for 0, 1 and many items and for domain selections. |
| Command execution | Stub | Every command only changes screen. Nothing is created, linked, compared, grouped, exported, measured or simulated. |
| Sync | Missing | Decision 0001 is still open. |
| Encryption at rest | Partial | iOS file protection only; nothing on macOS, and no SQLCipher. |
| Store performance | Partial | Benchmarked (100k objects: 20 ms FTS, 38 ms depth-6 traversal). The six proposed optimisations are unapplied, the store is synchronous, and UI writes run on the main actor. |

## 2. Experience (UI)

| Feature | Status | Notes |
|---|---|---|
| 1 Command Center | Partial | Has Continue and Recently changed. Missing Now, Watching, Today, and the Ask/Create/Analyze/Run actions. |
| 2 Project | Stub | Reuses the flat Collection list. No mission, objectives, people, decisions or outputs. |
| 3 Search | Partial | Free text plus a truth filter. The engine's type, date and scope filters aren't exposed in the UI. |
| 4 Object Detail | Partial | Has attributes with truth badges, relationships, revisions, events and notes. Missing state, domain views, an intelligence section and actions. |
| 5 Collection/List | Partial | List with multi-select. Command chips are plain text, not buttons. No table, cards, board, map, hierarchy or gallery views. |
| 6 Document | Missing | Routes to Object Detail. |
| 7 Research | Missing | Routes to Object Detail. |
| 8 Conversation | Missing | Placeholder. |
| 9 Meeting | Missing | Placeholder. The backend exists (NotePromotion, SpeechNotes). |
| 10 Timeline | Partial | Plain list, no filtering. |
| 11 Task/Workflow | Missing | Placeholder. `NexusTasks` exists. |
| 12 Calendar | Missing | Placeholder. |
| 13 Investigation | Partial | The strongest screen: next test first, hypotheses, confirm, evidence. Missing measurement entry, observations, and a system-truth vs display-truth view. Falls back to demo tests. |
| 14 Telemetry | Partial | Three depths, one line chart plus a table. Demo data only. The simulation runs on the main thread. |
| 15 Digital Twin | Partial | Grey boxes, and overlays only in the side list. Tapping in 3D is likely broken: `registerComponents()` is never called and entities have no `InputTargetComponent`. No links, LOD or instancing. Demo only. |
| 16 Creative | Missing | Placeholder. |
| 17 Agent Activity | Partial | Steps and output after the run. No live progress, plan, tools, errors or approval history. |
| 18 Settings/Permissions | Partial | Edits agent, action, level and grant rules. Errors are swallowed. No model, privacy or data settings. |
| Mac four columns | Built | |
| iPad workspace-first, Pencil | Partial / Missing | Shares the Mac layout; no Pencil support. |
| iPhone bottom bar | Partial | "+" opens Search rather than creating. No swipe-up Intelligence or sideways related objects. |
| Keyboard | Partial | Four shortcuts: ⌘K, ⌥⌘I, ⌘[, ⌘]. |
| Empty states that teach | Built | |
| Classified errors (5 categories) | Missing | Most errors are dropped with `try?`. |
| Inspectable progress | Missing | Only "Working…". |
| Accessibility | Partial | Has non-colour status, labels and a chart table. Missing high contrast, reduced motion, large targets, captions, and any device audit. |
| Visualization engine | Missing | No `NexusVisualization`. Only Line and Table exist of the 17 types. No Metal. |
| iPhone UI test | Partial | Read-only navigation of seeded data. It can't cover the field workflow because there's no measurement entry. |

## 3. Intelligence (AI, agents, our own model)

| Feature | Status | Notes |
|---|---|---|
| Execution envelope and ledger | Built | Goal, context, plan, permission, tool, output and provenance are all recorded. |
| Replan | Partial | Implicit in the model loop; there is no plan object. |
| Verification | Partial | Checks the provenance of produced objects only; answers aren't checked for grounding at runtime. |
| Usage and cost | Partial | Tokens only, and Foundation Models reports zero. No money or latency. |
| Cancellation, context budget | Built | Nothing counts real tokens; it uses a character heuristic. |
| Permissions P0–P5, grant modes, persistence | Built | |
| Permission scopes | Partial | The engine matches all seven scopes, but the runtime only fills agent, action, level and project. |
| Agent gates (external action, rollback, inspectable) | Built | Tested. |
| Draft vs external-action states | Partial | `send_message` only writes an outbox event. |
| Specialist agents | Stub | 1 of 22: Diagnostician. |
| Orchestrator and delegation | Missing | |
| Agent tools | Partial | Seven tools: search, get, related, measurements, propose hypothesis, annotate, send message (stub). None for tasks, documents, meetings, calendar or web. |
| Model router | Built | Local-first, privacy-bounded. |
| Apple on-device and PCC providers | Built | Untested. **Gated on OS 27 while the app targets 26,** so Ask is disabled on 26. |
| Claude provider | Library only | Tested but never registered in the app. |
| Local open-weights model (Core AI/MLX) | Missing | Blocked on `coreai-models` (issue #49). |
| Streaming | Partial | Supported by the runtime; no provider streams and the UI doesn't show deltas. |
| Structured output (`@Generable`) | Missing | Hypotheses arrive only as tool arguments. |
| Foundation Models tool bridge | Partial | String and number arguments only. Each turn builds a new session. Untested. |
| Dataset generator, trainer scenarios, held-out evaluator | Built | Covers instrument loops and ladder logic only. |
| Model registry | Partial | Manifest and checksum only. No download or loading, and nothing uses it at runtime. |
| Promotion gate | Partial | The CLI exists; it isn't in CI. |
| Training scripts (MLX), trained model | Missing | |

## 4. Work (tasks, documents, meetings, research)

| Feature | Status | Notes |
|---|---|---|
| Tasks and workflow | Library only | Status, dependencies, gates, success condition, owner, draft for agents. The intent and meeting promotion bypass it and create raw objects. |
| Documents | Library only | Text/Markdown import, blobs, passages, cited claims. No PDF text extraction (no PDFKit). No UI or agent tool reaches it. |
| Meetings | Partial | Keyword-based extraction into decisions, tasks, claims and questions. No participants, commitments or owners, and no model-driven extraction. No UI. |
| Research runtime | Missing | No `NexusResearch`, no web access, no contradiction detection or synthesis. |
| Automation (triggers, conditional tasks) | Missing | No `NexusAutomation`. |
| Calendar and scheduling | Missing | No EventKit, and no flexible or conditional time. |
| Email and messages | Stub | Outbox event only. |

## 5. Engineering and simulation

| Feature | Status | Notes |
|---|---|---|
| Measurement record fields | Built | Accuracy lives on the instrument model, not on the record. |
| Units and uncertainty propagation (`NexusMeasurement`) | Library only | Nothing imports it. Units cover electrical, pressure, time and temperature only. The store doesn't validate units. |
| Instrument types (DMM, scope, HART, OBD/CAN…) | Stub | One generic accuracy spec. |
| Live acquisition from hardware | Missing | |
| Investigation engine | Built | Generic runtime, tested on the loop. Missing: probabilistic updating (it's logical only), generating candidate causes, a repair API, and structured safety constraints. |
| Simulation runtime | Partial | Clock, world state, solvers and snapshots. It emits no events and snapshots aren't persisted. |
| Solvers | Partial | Loop, tank, AI card, PI controller and valve only. Mechanical, thermal, vehicle, economic and environment are missing. The trainer's physics isn't adapted to the solver protocol. |
| Modeled truth can't overwrite observed | Built | Tested. |
| Digital twin model | Partial | Identity, topology, state, faults and evidence. No real geometry or assets, and no persisted telemetry. |
| Telemetry store and Metal renderer (`NexusTelemetry`) | Missing | |
| Learning: scenario, replay, grading | Built | Hard-wired to `InstrumentLoop`. The trainer's tutor and spaced-mastery code aren't connected. |
| PLC diagnosis import | Built | |
| Trainer ports | Partial | ControlsPLC and ControlsReasoning are used. ControlsSimulation and ControlsTraining (about 16k lines) are ported but unused by Nexus, and ControlsTraining keeps its own persistence. All trainer UI was left behind. |

## 6. Golden Slice acceptance

| Step | Headless test | In the app |
|---|---|---|
| 1 Project, 2 Topology | Strong | Seeded demo only; no create UI |
| 3 Document and cited claim | Weak: plain object, not `NexusDocuments` | No |
| 4 Same identity across views | Partial: RealityKit and investigation views not checked | Twin tap likely broken |
| 5 Fault, 6 Truth classes, 7 Hypotheses, 8 Discriminating test, 9 First divergence | Strong | Viewable. No measurement entry, no investigation start |
| 10 Repair procedure and task | Weak: plain objects, not `NexusTasks` | No |
| 11 Verify, 12 Report, 13 Training, 14 Save/reload | Strong | Report and training scenario not shown in the UI |

Spec requirements the slice doesn't exercise at all: agents, permissions, the tasks, documents and measurement modules, telemetry, and RealityKit.

**Result:** the headless slice passes, but the gate "iPhone supports complete Golden Slice field workflow" is not met.

## 7. Apple Intelligence surfaces

| Surface | Status |
|---|---|
| App Intents and entities, App Shortcuts | Built and wired. Measure and Run Simulation are not in App Shortcuts. |
| Spotlight | Built and wired |
| Writing Tools | Built on the notes editor only |
| Control widget | Built. It may throw "still starting" when run from the extension process. |
| Live Activity | Stub: never started |
| Speech notes | Library only: no recording UI |
| Nameplate OCR and Visual Intelligence | Library only: nothing calls it, and there's no camera UI |

## 8. Domains after the slice

All **Missing**:
- NexusAutomotive
- NexusFinance
- NexusTravel (including food and meals)
- NexusCreative
- NexusResearch
- NexusAutomation
- NexusTelemetry
- NexusVisualization
- Career, CRM/commerce, email, social, architecture and interiors

This follows `LOCKED_DECISIONS.md`: no fan-out until the slice works end to end.

## Recommended order

These close the Golden Slice in the app, which the locked decisions put before any new domain:

1. **Make commands real.** Start Investigation, Record Measurement (a new entry form with instrument, test point and uncertainty, recorded as observed), Link, Create, and Confirm/Reject. Emit events for measurements, edits and approvals.
2. **Fix the twin.** Register the component, add input targets, draw overlays and links in 3D, and follow the focused object instead of the demo.
3. **Get Ask working on OS 26.** Register the Claude provider as an opt-in fallback, stream deltas into the panel, show progress, and use `@Generable` hypotheses on OS 27.
4. **Wire in the unused libraries:**
   - `TaskRuntime` for repair tasks and intents
   - `DocumentLibrary` with PDFKit, plus agent tools for it
   - `NexusMeasurement` for units and uncertainty on entry
   - Speech into a Meeting screen
   - nameplate OCR into search
   - the Live Activity on agent runs
5. **Move work off the main thread.** Run simulation and telemetry in the background, then apply the store optimisations.
6. **Extend the Golden Slice test and the iPhone UI test** to cover the full field workflow with agents, permissions, tasks and documents.
7. **Then add the missing screens,** in this order: Task, Document, Research, Meeting, Project.
8. **Then the layers the slice depends on:** a classified error model, inspectable progress, and the visualization module.
9. **Then pick the second domain** (automotive recommended), and the research runtime and orchestrator with it.

Our own model continues in parallel: training scripts on a Mac, then a trained model, then the promotion gate in CI, then Core AI once it builds.

# Roadmap: the 50 steps after the Golden Slice

Corrected after the spec audit. See `FEATURE_AUDIT.md` for every spec feature and what's unbuilt.

Status as of 2026-09-27. ✅ done · 🟡 partly done (the note says what's missing) · ⏳ blocked or waiting on a decision.
"Linux-tested" means covered by `swift test` in the Linux CI job. "macOS CI" means it compiles in the `apple` job (Xcode 27) but has not run on a device.

## A. Housekeeping
| # | Step | Status |
|---|---|---|
| 1 | Pull request to `main` | ✅ Draft PR #1 |
| 2 | Session-start hook that installs Swift | ✅ `.claude/hooks/session-start.sh` |
| 3 | Persisted permission rules and approvals | ✅ Migration 3, `PermissionEngine(store:)` |
| 4 | Store change feed | ✅ `changes(after:)`, `observeChanges`, delivered after the outermost commit |

## B. The app
| # | Step | Status |
|---|---|---|
| 5 | macOS CI job | ✅ `apple` job: package build and tests, app for iOS Simulator and macOS, UI tests |
| 6 | RealityKit adapter first build | ✅ Compiles in macOS CI |
| 7 | One Xcode project for iPhone, iPad, Mac | ✅ XcodeGen `project.yml` |
| 8 | App startup | ✅ `NexusEnvironment.live()` (file protection on iOS), `-demo` for tests |
| 9 | Mac layout | ✅ `RegularRoot` split view plus Intelligence inspector |
| 10 | iPad layout | 🟡 Shares `RegularRoot`; no iPad-specific workspace-first tuning yet |
| 11 | iPhone layout and bottom bar | ✅ `CompactRoot` |
| 12 | Command palette (⌘K) | 🟡 Lists the right commands for the selection, but every command only switches screen; none performs its action |
| 13 | Object detail | ✅ Truth badges, relationships, revisions, notes with Writing Tools |
| 14 | List with multi-select | ✅ |
| 15 | Search | ✅ |
| 16 | Investigation screen | ✅ Ranked next test shown first, above the hypotheses |
| 17 | Digital twin | 🟡 `RealityView` of primitives. Tapping in 3D is likely broken (component never registered, no input target); selection works from the list |
| 18 | Telemetry with three depths | ✅ Charts plus a Table |
| 19 | Timeline and agent activity | ✅ |
| 20 | Permissions settings | ✅ |
| 21 | Accessibility pass | 🟡 Text truth badges, chart tables, combined row labels. A VoiceOver and Dynamic Type audit on a device is still to do |
| 22 | iPhone UI test of the diagnosis | 🟡 `GoldenSliceUITests` passes in macOS CI, but only navigates seeded data. The app has no measurement entry, so the full field workflow can't be tested yet |

## C. Local AI
| # | Step | Status |
|---|---|---|
| 23 | Apple on-device model provider | 🟡 `FoundationModelsProvider` with tools bridged through `BridgedTool`. Missing structured (`@Generable`) hypotheses and tests. Gated on OS 27 while the app targets 26, so Ask is disabled on 26 |
| 24 | Verify iOS 27 custom-model support | ✅ See `APPLE_PLATFORM_NOTES.md`; one provider type now covers every `LanguageModel` |
| 25 | Local open-weights model | ⏳ Waiting on `apple/coreai-models` building for the simulator (issue #49). Plugs in as one more provider |
| 26 | Private Cloud Compute tier | ✅ `PrivateCloudComputeLanguageModel`, needs the entitlement to run |
| 27 | Claude provider (opt-in) | 🟡 `AnthropicProvider` is Linux-tested, but the app never registers it |
| 28 | Streaming and cancellation | 🟡 The runtime supports both (tested). No provider streams, and the Ask panel doesn't show deltas |
| 29 | Context budget | ✅ `ContextBudget`, Linux-tested |
| 30 | Agent eval harness | ✅ Linux-tested |

## D. Our own model
| # | Step | Status |
|---|---|---|
| 31 | More loop faults | ✅ 8 `LoopFault` kinds, including intermittent |
| 32 | Dataset generator | ✅ `NexusTrainingData`, `nexus-dataset-gen` |
| 33 | Trainer scenarios and ladder logic in the dataset | ✅ `DiagnosisExamples`, `LadderExamples` |
| 34 | Held-out evaluation | ✅ `Evaluator`: root cause, next-test agreement, invented values, truth discipline |
| 35 | Adapter for Apple's on-device model | ⏳ Apple no longer documents system-model adapters. Dropped unless that returns |
| 36 | Fine-tune an open model | ⏳ Pipeline in `TRAINING_DATA.md`; needs an Apple silicon Mac and a licence check on the base model |
| 37 | Model registry | ✅ `NexusModelRegistry` |
| 38 | Ship-only-if-better gate | 🟡 `ModelRegistry.canPromote` is written and tested; wired into CI once there is a trained model to compare |

## E. Apple Intelligence surfaces (compiled in macOS CI, not yet run on a device)
| # | Step | Status |
|---|---|---|
| 39 | Objects as App Entities | ✅ `NexusObjectEntity`, query backed by `NexusSearch` |
| 40 | Siri and Shortcuts actions | ✅ Open, Ask, Measure, Start Investigation, Run Simulation, Create Task |
| 41 | Spotlight from the change feed | ✅ `SpotlightIndexer` |
| 42 | Visual Intelligence nameplates | 🟡 OCR, matcher and value query are built, but nothing in the app calls them and there's no camera UI |
| 43 | Speech notes into decisions, tasks, claims | 🟡 `SpeechNotes` and keyword-based `NexusMeetings` are built; there's no recording UI or Meeting screen |
| 44 | Writing Tools, Live Activity, widgets, controls | 🟡 Writing Tools (notes editor) and the Control widget work. The Live Activity is never started |

## F. Core
| # | Step | Status |
|---|---|---|
| 45 | Tasks and workflow module | 🟡 `NexusTasks` is built and tested, but no UI, agent or intent uses it |
| 46 | Documents module | 🟡 `NexusDocuments` is built and tested. No PDF text extraction, and no UI or agent uses it |
| 47 | Measurement module | 🟡 `NexusMeasurement` is built and tested, but nothing imports it |
| 48 | Performance | 🟡 Benchmarks in `NexusBenchmarks`, results in `PERFORMANCE.md`. Proposed store optimisations are not applied yet |
| 49 | Sync, backup, encryption | ⏳ Owner's decision; recommendation in `decisions/0001-sync-backup-encryption.md` |
| 50 | Second domain | ⏳ Recommendation (automotive) in `decisions/0002-second-domain.md`; the gate is the diagnosis passing on a real device |

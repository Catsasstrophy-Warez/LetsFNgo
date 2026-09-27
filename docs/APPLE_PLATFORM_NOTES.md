# Apple platform notes (verified 2026-09-27)

These notes record what Apple's current documentation actually says, because it
changes parts of `BUILD_PLAN.md` §F. Sources are Apple's DocC JSON under
`developer.apple.com/tutorials/data/documentation/…`, which is the same content
as developer.apple.com/documentation.

## Foundation Models (iOS/macOS 27)

| Claim in the original plan | Verified status | Source |
|---|---|---|
| Any model can sit behind the Foundation Models session API | **True.** `protocol LanguageModel: Sendable` (iOS 27) with `LanguageModelExecutor`. `SystemLanguageModel`, `PrivateCloudComputeLanguageModel` and custom models all conform, and `LanguageModelSession(model:tools:instructions:)` accepts any of them. | `foundationmodels/languagemodel`, `…/languagemodelsession` |
| Private Cloud Compute tier | **True.** `PrivateCloudComputeLanguageModel()` (iOS 27): 32K context, stronger reasoning, `ContextOptions(reasoningLevel: .light/.moderate/.deep)`, a daily quota (`quotaUsage`, `quotaLimitReached`), and the `com.apple.developer.private-cloud-compute` entitlement. It needs a network; fall back to on-device. | `…/adding-server-side-intelligence-with-private-cloud-compute` |
| Custom LoRA adapters for the system model | **No longer documented.** The adapter page returns 404 and `SystemLanguageModel` lists no adapter initializer. The only model-specific options are `init(useCase:guardrails:)`. | `foundationmodels/systemlanguagemodel` |
| Our own fine-tuned model through MLX | **Better path available.** Apple's open-source `coreai-models` package exports Hugging Face models to Core AI (`.aimodel`) and ships `CoreAILanguageModel: LanguageModel`, so the model drops straight into `LanguageModelSession`. `mlx-swift-lm` is also listed as integrating with the framework. | `…/running-a-core-ai-model-in-a-foundation-models-session`, `updates/foundationmodels` |
| Tool calling | The framework **executes tools itself** inside a session (`Tool.call(arguments:)`). `GenerationOptions.toolCallingMode` is `.allowed/.disallowed/.required` only; there is no "return the call to me" mode. | `…/tool`, `…/generationoptions/toolcallingmode-swift.struct` |
| Multimodal + Vision tools | `Attachment`/`ImageAttachmentContent` prompts; `OCRTool` and `BarcodeReaderTool` from Vision. | `updates/foundationmodels` |
| Dynamic Profiles | `LanguageModelSession.DynamicProfile` / `DynamicInstructions` swap instructions and tools at runtime. | `…/languagemodelsession` |

## What changed in the build as a result

- **Tool loop ownership.** Because Foundation Models runs tools itself, `LanguageModelProvider` gains `respond(to:toolHandler:)`. A provider that owns the loop calls back into `AgentRuntime` for every tool call, so permissions, per-call rollback and the ledger still apply to every call. Providers that return tool calls (scripted models, the Messages API) keep the existing path.
- **Model tiers.**
  - L1: `SystemLanguageModel` (on device).
  - L2: our fine-tuned open model, exported with Core AI (`CoreAILanguageModel`) and trained with MLX / `mlx-lm` on a Mac.
  - L3: `PrivateCloudComputeLanguageModel`.
  - L4: third-party cloud, opt-in, P4.
  
  All four sit behind one `LanguageModelSession` on Apple platforms.
- **Training (roadmap 35–36).** Drop the system-model adapter track unless Apple restores it. Put the dataset work (`NexusTrainingData`) into fine-tuning an open base model, then export it via `coreai.llm.export` per platform. Pick the base model from the Core AI registry (`uv run coreai.model.registry --list-models`), checking its licence.
- **Deployment target.** The package now declares iOS/macOS 26. `PrivateCloudComputeLanguageModel`, `LanguageModel` and `toolCallingMode` are guarded with `#available(iOS 27, macOS 27, *)`.

## Other Apple surfaces in use

- **App Intents:** an App Entity keyed by ObjectID, intents, App Shortcuts, and `AppIntentsPackage` from the Swift package into the app.
- **Core Spotlight:** indexing driven by the store's change feed, with `CSSearchableItemActionType` hand-off back into the app.
- **Vision:** `RecognizeTextRequest` for nameplates. Visual Intelligence uses an `IntentValueQuery` over `SemanticContentDescriptor.labels`.
- **Speech:** `SFSpeechRecognizer` with on-device recognition when supported. `SpeechAnalyzer` is the newer API to evaluate.
- **ActivityKit and WidgetKit:** a Live Activity for agent runs and a `ControlWidget`.
- **RealityKit:** `RealityView` with a `CanonicalObjectComponent` on each entity.

None of this can be compiled in the Linux cloud session. The `apple` job in `.github/workflows/ci.yml` (Xcode 27 runner) is the compile and UI-test gate.

## Core AI package status (checked 2026-09-27)

`apple/coreai-models` currently has two problems:
- It fails to compile for the iOS Simulator (issue #49, "no such module 'CoreAI'").
- It has no release tagged for Xcode 27 (issue #293).

Its stock `CoreAILanguageModel` adapter also doesn't support tool calling; the community `coreai-kit` adds it.

So Nexus does not depend on the package yet. `FoundationModelsProvider` is generic over any `FoundationModels.LanguageModel`, so a Core AI model becomes one more provider in `ModelProviders.install` once the package builds for the simulator. Only a model with tool calling can run agent tools.

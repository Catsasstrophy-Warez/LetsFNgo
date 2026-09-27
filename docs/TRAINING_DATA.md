# Training data and evaluation (roadmap steps 31–34, 37, 38)

This is the headless data factory and eval gate from `docs/BUILD_PLAN.md` §F3. The deterministic simulators know the true root cause, the causal chain and the best next measurement. That makes them a source of supervised examples for Nexus's local models (the L1 Apple adapter and the L2 MLX model). The same answer keys let us score a model, and a model version ships only if it beats the previous version on every metric.

| Piece | Where |
|---|---|
| Loop fault physics | `Sources/NexusSimulation/InstrumentLoop.swift`, `LoopFaults.swift` (`LoopFaultKind`) |
| Seeded PRNG | `Sources/NexusSimulation/SeededRandom.swift` (`SplitMix64`) |
| Generator, evaluator, baseline, CLI logic | `Sources/NexusTrainingData` |
| Command line | `Sources/NexusDatasetGen/main.swift` |
| Model registry and promotion gate | `Sources/NexusModelRegistry` |

## Command line

```sh
swift run NexusDatasetGen --count 1000 --seed 42 --out train.jsonl                 # --split train is the default
swift run NexusDatasetGen --count 200 --seed 42 --split eval --out eval.jsonl
swift run NexusDatasetGen baseline --train train.jsonl --examples eval.jsonl --out baseline.jsonl
swift run NexusDatasetGen evaluate --examples eval.jsonl --predictions baseline.jsonl --out baseline.json
swift run NexusDatasetGen gate --candidate candidate.json --current baseline.json   # exit 0 pass, 1 refuse
```

`generate` is the default subcommand. A usage or input error exits with code 2. In a debug build the generator makes about 5 examples a second, so 1,000 examples take about 3 minutes; add `-c release` for large runs.

## Determinism and splits

- Example `i` of a run with `--seed S` uses scenario seed `base(split) + ((S << 20) + i) mod 2^40`. The base is 0 for `train` and 2^40 for `eval`, so **the splits draw from disjoint seed ranges** whatever the arguments. Within a split, consecutive `--seed` values address non-overlapping blocks of 2^20 examples. `--count` is capped at 2^20.
- All randomness comes from `SplitMix64`; nothing uses Foundation randomness. Object IDs, names, fault draws and the intermittent-contact schedule all derive from the scenario seed. Stores run on a `ManualClock`. The same arguments give byte-identical JSONL: keys are sorted, one example per line.
- Kinds rotate with the index: `i % 4` of 0 or 1 is `diagnosis`, 2 is `toolTranscript`, 3 is `ladderWhy`. So 200 examples are 100/50/50.

## Loop fault kinds (step 31)

Each fault is a set of parameter overrides (`InstrumentLoop.faults(_:severity:seed:)`). The solvers turn those overrides into physics, and the new parameters have healthy defaults. Severity `s` ∈ [0, 1]; generated scenarios draw `s` from [0.25, 1].

| Kind | Overrides | Physics |
|---|---|---|
| `contactResistance` | `contactOhms` = 700 + 1300·s Ω | I_max = (V_supply − V_liftoff) / R_total; above it the transmitter pins at lift-off |
| `openWire` | `openCircuit` = 1 | loop current 0 mA, transmitter terminals 0 V, card underrange (< 3.6 mA), reads −25 % |
| `transmitterDrift` | `outputGain` = 1 − 0.3·s, `outputOffset` = −0.8·s mA | requested I = I_ideal + (I_ideal − 4)(gain − 1) + offset |
| `cardChannelStuck` | `channelStuck` = 1, `channelStuckMilliamps` = 20 − 4·s | card reports a fixed current; receiver voltage still follows the loop |
| `cardReadsLow` | `channelGain` = 1 − 0.4·s | card reports gain × true current |
| `wrongScaling` | card `rangeHigh` = 100 + 40·s % | card scales 4–20 mA over 0–rangeHigh while the transmitter spans 0–100 % |
| `supplySag` | `supplyVolts` = 16 − 6·s V | less headroom above lift-off; below 12 V no current flows |
| `intermittentContact` | `intermittentOhms` = 1000 + 3000·s Ω, `intermittentSeed` | adds that resistance during "open" 2 s windows (35 % duty) drawn by `IntermittentContact.isOpen(seed:window:duty:)` |

`Tests/NexusSimulationTests/LoopFaultTests.swift` checks each kind against a hand calculation.

## Example kinds (steps 32, 33)

### `diagnosis`

A seeded loop with names such as `LT-391` and `TB-8 terminals 23/24`, a fault kind, a severity and an operating point (setpoint 60/75/90 %, initial level 40/60 %). The run lasts 600 s at dt = 0.5 s next to a healthy twin. The plant's access factors scale test costs, and half of the tanks have no sight glass. A fault that shows no symptom is redrawn.

- `prompt`: the operator's symptom (HMI value, setpoint, valve, alarms, trend jumps, sight-glass complaint).
- `observations`: what is known before any test. HMI values are `display`; the setpoint, alarms and card diagnostics are `recorded`; healthy-twin values are `modeled`.
- `tests`: the measurements the technician may take, with cost (minutes) and safety. `busVoltage` is hazardous and is never recommended.
- `hypotheses`: one per `LoopFaultKind`, with an interval prediction per test. Predictions are **simulated**, not hand-written. Each kind runs across a severity grid (and eight schedules for the intermittent contact) at the scenario's operating point, and each interval is padded by the instrument's tolerance. Overlapping intervals merge into one outcome. A cause whose interval spans two outcomes makes no prediction for that test.
- `answer.nextTest`: the first recommendation of `InvestigationRuntime.rankTests` (`TestSelector`) over those hypotheses in an in-memory `NexusStore`. `answer.ranking` holds the full ranking with information gain, score and outcome groups.
- `answer.expertPath`: follows the top-ranked test, stores the field reading as an `observed` (or `recorded`) measurement and calls `assess`. It repeats until one cause survives. Each step lists the surviving causes.
- `answer.firstDivergence`: `DivergenceDetector.firstDivergence` between the healthy twin and the field along terminal voltage → loop current → card reading → measured level → controller output → level. The field value is `observed` under the training-world convention and the twin value is `modeled`.
- `answer.cause`: the `LoopFaultKind` raw value. `answer.text` is a reference answer in which every figure carries its truth class.
- `scenario`: the hidden setup (fault, severity, overrides, operating point).

### `toolTranscript`

The same kind of case, worked as a conversation. A coin drawn from the seed picks one of two goals:

- "What should I measure next?", asked before any reading.
- "What is the most likely cause?", asked after the expert path's readings are stored.

The assistant calls `search_objects` → `related_objects` → `get_measurements`, using the WorldTools names and arguments from `Sources/NexusAgents/WorldTools.swift`. Tool results come from the same public store, graph and search calls the tools make, over a store that holds the case's objects and readings. A test runs the real tools through `AgentRuntime` and requires identical output. The final answer cites every value with its truth class, and for the cause goal it notes that a technician must confirm.

### `ladderWhy`

"Why isn't X on?" over a generated ladder routine. The routine has zero to two intermediate permissive rungs (series `XIC`/`XIO` contacts driving an `OTE`) and a final rung driving the output. Inputs are drawn so the output is off. The routine runs two scans on `ControlsPLC`, and the trainer's `CausalJournal` answers the question: `explainWhy` gives the trail and `diagnose` gives the blockers and the next check. `answer.cause` is the root-condition input tag.

## Example schema

Every line is a `TrainingExample` (`Sources/NexusTrainingData/TrainingExample.swift`). Sections that don't apply to a kind are omitted.

| Field | Type | Notes |
|---|---|---|
| `id` | string | `<split>-<scenarioSeed>-<kind>` |
| `kind` | `diagnosis` \| `toolTranscript` \| `ladderWhy` | |
| `split`, `seed` | string, integer | scenario seed; `DatasetSplit.containing(seed)` gives the split back |
| `prompt` | string | symptom, user goal or question |
| `observations[]` | `{name, object, value, unit, truth, source}` | `truth` is a `TruthClass` raw value |
| `tests[]` | `{title, object, quantity, unit, cost, safety}` | loop kinds only |
| `hypotheses[]` | `{cause, statement, predictions[{test, quantity, unit, low, high}]}` | loop kinds only |
| `scenario` | `{fault, severity, overrides[{object, parameter, value}], setpoint, initialLevel, runSeconds}` | hidden setup |
| `messages[]` | `{role, content, toolCalls?[{id, name, arguments}], toolCallID?}` | transcripts; roles `system`, `user`, `assistant`, `tool` |
| `ladder` | `{routine, rungs[{number, text}], target}` | ladder kind |
| `answer` | `{cause, nextTest?, text, ranking?, expertPath?, firstDivergence?, trail?, blockers?}` | the answer key |

### Samples

Diagnosis and transcript lines are trimmed: arrays are cut to their first entries and a transcript keeps its first four and last messages. The ladder line is complete.

```json
{"answer": {"cause": "openWire", "expertPath": [{"remaining": ["cardChannelStuck", "cardReadsLow", "contactResistance", "intermittentContact", "openWire", "transmitterDrift", "wrongScaling"], "test": "Measure loop supply voltage at the card", "truth": "observed", "unit": "V", "value": 24}, {"remaining": ["cardChannelStuck", "cardReadsLow", "contactResistance", "intermittentContact", "openWire", "transmitterDrift"], "test": "Read the AI channel range from the controller", "truth": "recorded", "unit": "%", "value": 100}, {"remaining": ["cardChannelStuck", "intermittentContact", "openWire"], "test": "Clamp meter on the loop current", "truth": "observed", "unit": "mA", "value": 0}, {"remaining": ["cardChannelStuck", "openWire"], "test": "Trend terminal voltage for 60 s", "truth": "observed", "unit": "V", "value": 0}, {"remaining": ["openWire"], "test": "Source 12 mA into the card with a loop calibrator", "truth": "observed", "unit": "%", "value": 50}], "firstDivergence": {"actual": 0, "expected": 21.19, "object": "TB-8 terminals 23/24", "quantity": "terminalVoltage", "seconds": 0, "tick": 0, "unit": "V"}, "nextTest": "Measure loop supply voltage at the card", "ranking": [{"informationGain": 0.544, "outcomes": [["supplySag"], ["cardChannelStuck", "cardReadsLow", "contactResistance", "intermittentContact", "openWire", "transmitterDrift", "wrongScaling"]], "score": 0.181, "title": "Measure loop supply voltage at the card"}], "text": "Next test: Measure loop supply voltage at the card. TestSelector ranks it first with 0.54 bits of expected information for 3 min. Expert path: Measure loop supply voltage at the card: 24 V (observed); Read the AI channel range from the controller: 100 % (recorded); Clamp meter on the loop current: 0 mA (observed); Trend terminal voltage for 60 s: 0 V (observed); Source 12 mA into the card with a loop calibrator: 50 % (observed). Cause: Open circuit in the loop wiring: no loop current flows [openWire]. First divergence from the healthy twin: terminalVoltage at TB-8 terminals 23/24, t = 0 s, 0 V (observed) where the model expects 21.19 V (modeled)."}, "hypotheses": [{"cause": "contactResistance", "predictions": [{"high": 100.05, "low": 99.95, "quantity": "configuredRangeHigh", "test": "Read the AI channel range from the controller", "unit": "%"}, {"high": 24.1, "low": 23.9, "quantity": "supplyVolts", "test": "Measure loop supply voltage at the card", "unit": "V"}], "statement": "Corroded or loose terminal adds series resistance and starves the transmitter of compliance voltage"}, {"cause": "openWire", "predictions": [{"high": 100.05, "low": 99.95, "quantity": "configuredRangeHigh", "test": "Read the AI channel range from the controller", "unit": "%"}, {"high": 24.1, "low": 23.9, "quantity": "supplyVolts", "test": "Measure loop supply voltage at the card", "unit": "V"}], "statement": "Open circuit in the loop wiring: no loop current flows"}], "id": "eval-1099555667968-diagnosis", "kind": "diagnosis", "observations": [{"name": "measuredLevel", "object": "AI card slot 7 ch 3", "source": "HMI", "truth": "display", "unit": "%", "value": -25}, {"name": "setpoint", "object": "LIC-391 level controller", "source": "controller", "truth": "recorded", "unit": "%", "value": 90}], "prompt": "LT-391 reads -25 % on the HMI against a 90 % setpoint; LV-391 is 100 % open. High-level switch LSH-391 is in alarm and the tank is overflowing. The AI card reports an underrange diagnostic on the channel.", "scenario": {"fault": "openWire", "initialLevel": 40, "overrides": [{"object": "TB-8 terminals 23/24", "parameter": "openCircuit", "value": 1}], "runSeconds": 600, "setpoint": 90, "severity": 1}, "seed": 1099555667968, "split": "eval", "tests": [{"cost": 5, "object": "AI card slot 7 ch 3", "quantity": "configuredRangeHigh", "safety": "routine", "title": "Read the AI channel range from the controller", "unit": "%"}, {"cost": 3, "object": "AI card slot 7 ch 3", "quantity": "supplyVolts", "safety": "routine", "title": "Measure loop supply voltage at the card", "unit": "V"}]}
{"answer": {"cause": "contactResistance", "nextTest": "Compare the sight glass with the HMI", "ranking": [{"informationGain": 1.701, "outcomes": [["openWire"], ["contactResistance"], ["cardReadsLow", "transmitterDrift"], ["wrongScaling"], ["cardChannelStuck"]], "score": 0.189, "title": "Compare the sight glass with the HMI"}], "text": "LT-698 shows 17.39 % (display) against a 60 % (recorded) setpoint. The healthy twin expects 20.33 V (modeled) and 13.6 mA (modeled) at TB-7 terminals 13/14. Nothing has been measured in the field yet, so no candidate cause is ruled out. Next test: Compare the sight glass with the HMI. TestSelector ranks it first with 1.7 bits of expected information for 9 min."}, "hypotheses": [{"cause": "contactResistance", "predictions": [{"high": -66.08, "low": -92.97, "quantity": "levelError", "test": "Compare the sight glass with the HMI", "unit": "%"}, {"high": 100.05, "low": 99.95, "quantity": "configuredRangeHigh", "test": "Read the AI channel range from the controller", "unit": "%"}], "statement": "Corroded or loose terminal adds series resistance and starves the transmitter of compliance voltage"}, {"cause": "openWire", "predictions": [{"high": -124, "low": -126, "quantity": "levelError", "test": "Compare the sight glass with the HMI", "unit": "%"}, {"high": 100.05, "low": 99.95, "quantity": "configuredRangeHigh", "test": "Read the AI channel range from the controller", "unit": "%"}], "statement": "Open circuit in the loop wiring: no loop current flows"}], "id": "eval-1099555667970-toolTranscript", "kind": "toolTranscript", "messages": [{"content": "LT-698 reads 17.39 % on the HMI against a 60 % setpoint; LV-698 is 100 % open. High-level switch LSH-698 is in alarm and the tank is overflowing. What should I measure next?", "role": "user"}, {"content": "", "role": "assistant", "toolCalls": [{"arguments": {"query": "LT-698"}, "id": "call-1", "name": "search_objects"}]}, {"content": "38a45ea7-90d5-4998-a8f7-c47a879239fd [sensor] LT-698 level transmitter", "role": "tool", "toolCallID": "call-1"}, {"content": "", "role": "assistant", "toolCalls": [{"arguments": {"id": "38a45ea7-90d5-4998-a8f7-c47a879239fd"}, "id": "call-2", "name": "related_objects"}]}, {"content": "LT-698 shows 17.39 % (display) against a 60 % (recorded) setpoint. The healthy twin expects 20.33 V (modeled) and 13.6 mA (modeled) at TB-7 terminals 13/14. Nothing has been measured in the field yet, so no candidate cause is ruled out. Next test: Compare the sight glass with the HMI. TestSelector ranks it first with 1.7 bits of expected information for 9 min.", "role": "assistant"}], "observations": [{"name": "setpoint", "object": "LIC-698 level controller", "source": "controller", "truth": "recorded", "unit": "%", "value": 60}, {"name": "measuredLevel", "object": "AI card slot 1 ch 2", "source": "HMI", "truth": "display", "unit": "%", "value": 17.39}], "prompt": "LT-698 reads 17.39 % on the HMI against a 60 % setpoint; LV-698 is 100 % open. High-level switch LSH-698 is in alarm and the tank is overflowing. What should I measure next?", "scenario": {"fault": "contactResistance", "initialLevel": 60, "overrides": [{"object": "TB-7 terminals 13/14", "parameter": "contactOhms", "value": 1499.245}], "runSeconds": 600, "setpoint": 60, "severity": 0.615}, "seed": 1099555667970, "split": "eval", "tests": [{"cost": 9, "object": "Tank T-2", "quantity": "levelError", "safety": "routine", "title": "Compare the sight glass with the HMI", "unit": "%"}, {"cost": 10, "object": "AI card slot 1 ch 2", "quantity": "configuredRangeHigh", "safety": "routine", "title": "Read the AI channel range from the controller", "unit": "%"}]}
{"answer": {"blockers": ["Low_Air"], "cause": "Low_Air", "text": "Pump_Start is off. OTE Pump_Start was the transition path, but its rung was blocked → XIO Low_Air blocked the path → Low_Air remained TRUE. Root condition: Low_Air (recorded from the controller). Next check: Verify Low_Air at its physical or upstream source.", "trail": [{"headline": "Why isn't Pump_Start ON?", "kind": "symptom", "target": "Pump_Start"}, {"headline": "OTE Pump_Start was the transition path, but its rung was blocked", "kind": "blockedTransition", "target": "Pump_Start"}, {"headline": "XIO Low_Air blocked the path", "kind": "upstreamBlocker", "target": "Low_Air"}, {"headline": "Low_Air remained TRUE", "kind": "rootCondition", "target": "Low_Air"}]}, "id": "eval-1099555667971-ladderWhy", "kind": "ladderWhy", "ladder": {"routine": "PumpStartLogic", "rungs": [{"number": 0, "text": "XIC(VFD_Ready) XIO(Low_Air) OTE(Pump_Start)"}], "target": "Pump_Start"}, "observations": [{"name": "Low_Air", "object": "PumpStartLogic", "source": "controller tag table", "truth": "recorded", "unit": "bool", "value": 1}, {"name": "VFD_Ready", "object": "PumpStartLogic", "source": "controller tag table", "truth": "recorded", "unit": "bool", "value": 1}], "prompt": "Why isn't Pump_Start on?\nRoutine PumpStartLogic:\nRung 0: XIC(VFD_Ready) XIO(Low_Air) OTE(Pump_Start)\nInput tags (recorded from the controller): Low_Air = TRUE, VFD_Ready = TRUE", "seed": 1099555667971, "split": "eval"}
```

## Predictions and evaluation (step 34)

A model's predictions file is JSONL with the same ids. Every field except `id` is optional.

```json
{"answer":"measuredLevel = -25 % (display). Most likely cause: intermittentContact.","id":"eval-1099555667968-diagnosis","predictedCause":"intermittentContact","predictedNextTest":"Clamp meter on the loop current"}
{"answer":"measuredLevel = -25 % (display). Most likely cause: intermittentContact.","id":"eval-1099555667969-diagnosis","predictedCause":"intermittentContact","predictedNextTest":"Clamp meter on the loop current"}
```

`toolCalls` (`[{id, name, arguments}]`, same shape as in transcripts) is also accepted.

`Evaluator` computes the following metrics:

| Metric | Definition | Better |
|---|---|---|
| `rootCauseAccuracy` | predicted cause equals `answer.cause` (case and whitespace normalized); a missing prediction counts as wrong | higher |
| `nextTestAgreement` | predicted next test equals `answer.nextTest`, TestSelector's first choice (examples that have one) | higher |
| `hallucinatedValueRate` | share of answers containing a number that is not within tolerance (max(0.05, 1 %)) of any number in the example: observations, tool results, tests, predictions, rankings and answer-key readings | lower |
| `truthClassDiscipline` | of the numbers that cite a truth-labeled value (same value within tolerance and followed by that value's unit), the share followed by one of that value's truth classes before the next number (within 48 characters) | higher |
| `toolCallValidity` | predicted calls that name a WorldTools tool, carry its required arguments, and pass parseable IDs | higher |

Numbers are words made of an optional sign, digits, an optional decimal part and at most a three-letter glued unit (`12.03`, `-25`, `20mA`). Digits inside identifiers (`LT-101`, `TB-4`, UUIDs) are not numbers. Integers 0–10 are treated as counts and skipped. A metric with nothing to score is omitted (`null` is never written). The report also carries counts and `accuracyByKind`.

**Baseline** (`BaselinePredictor`): the most common training cause and next test per kind, plus an answer that cites the first observation with its label. On 200 eval examples (seed 42), trained on 200 train examples (seed 42):

```json
{"accuracyByKind": {"diagnosis": 0.15, "ladderWhy": 0.08, "toolTranscript": 0.1}, "answersScored": 200, "causesScored": 200, "citedValues": 150, "correctlyLabeledValues": 150, "examples": 200, "hallucinatedAnswers": 0, "hallucinatedValueRate": 0, "missingPredictions": 0, "nextTestAgreement": 0.35833333333333334, "nextTestsScored": 120, "numbersChecked": 150, "predictions": 200, "rootCauseAccuracy": 0.12, "toolCallsScored": 0, "truthClassDiscipline": 1, "ungroundedNumbers": 0, "unmatchedPredictions": 0}
```

Every reference answer in that eval set scores `hallucinatedValueRate` 0 and `truthClassDiscipline` 1 when it is fed back as a prediction.

## Model registry and gate (steps 37, 38)

`NexusModelRegistry` holds `ModelRegistry`, a JSON manifest (`format: 1`, sorted keys, ISO-8601 dates) of `ModelEntry` values:

```json
{"entries":[{"baseModel":{"identifier":"apple.system","version":"27.0"},"createdAt":"2026-09-27T00:00:00Z","id":"nexus-fm-2026.09.1","kind":"appleAdapter","metrics":{"hallucinatedValueRate":0,"nextTestAgreement":0.62,"rootCauseAccuracy":0.81,"truthClassDiscipline":0.97},"sha256":"<64 lowercase hex>","sizeBytes":12582912}],"format":1}
```

- `compatibleEntry(for: BaseModel, kind:)` returns the newest entry trained for exactly that base identifier and version. A nil result means "use the base model with tools".
- `ModelRegistry.canPromote(candidate:over:)` passes only if the candidate is at least as good as the current model on every metric the current model has (lower is better for the hallucination rate) and strictly better on at least one. A metric the candidate dropped fails the gate. A metric only the candidate has is reported but not compared. With no current model, the candidate passes.
- `NexusDatasetGen gate` reads two evaluator reports (or bare metrics JSON), prints one line per metric and exits non-zero when promotion is refused:

```
rootCauseAccuracy: better 0.1200 → 1.0000
nextTestAgreement: better 0.3583 → 1.0000
hallucinatedValueRate: tied 0.0000
truthClassDiscipline: tied 1.0000
PASS: candidate may be promoted
```

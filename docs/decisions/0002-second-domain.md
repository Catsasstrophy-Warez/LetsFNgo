# 0002 — Expansion review: the second domain

Status: **proposed**. Take this up once the Golden Slice UI test passes on a real device, per the locked decision "Golden Vertical Slice before domain fan-out".

## Gate
The expansion gate is met when:
- [x] Headless Golden Slice covers all 14 acceptance steps (`Tests/GoldenSliceTests`).
- [ ] App builds for iOS and macOS in CI (`apple` job).
- [ ] Golden Slice UI test passes on the iPhone simulator in CI.
- [ ] One end-to-end run on a physical iPhone and a Mac, including a Foundation Models agent run.

## Candidates, scored on reuse of what exists
| Domain | Reuses | New work | Fit |
|---|---|---|---|
| **Automotive diagnostics** | Measurement engine, investigation/hypotheses/first divergence, simulation runtime (vehicle subsystems as solvers), digital twin, telemetry screens, training scenarios, nameplate/VIN matching | OBD-II/CAN acquisition (hardware adapters), DTC library, vehicle solvers | **Highest.** Same diagnose-with-evidence loop as the Golden Slice. |
| Maintenance / CMMS | Tasks (step 45), procedures, investigations, equipment graph | Schedules, work orders, parts | High. Mostly workflow on existing objects. |
| Research / documents | Documents (step 46), claims, search, reports | PDF extraction on Apple, citation UI | High. Broadly useful, and the agent reads through it. |
| Personal finance | Store, truth classes (recorded vs interpretation) | Accounts, transactions, bank import | Medium. A different audience. |

## Recommendation
Do **automotive diagnostics** as the second vertical slice. It exercises the same architecture with new sensors and a new twin, which is the strongest test of "one model, many domains".

In parallel, finish **maintenance** (tasks and procedures), since the Golden Slice already produces repair tasks.

Define an automotive Golden Slice first. For example:
- misfire on cylinder 3
- DTC P0303 (recorded) and live O2/fuel trim data (observed), against an engine model (modeled)
- hypotheses (plug, coil, injector, vacuum leak) ranked by discriminating tests
- repair, then verification
- the case becomes a training scenario

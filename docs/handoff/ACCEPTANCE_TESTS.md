# Acceptance Gates

## Architectural invariants
- Every canonical object has a stable ObjectID.
- No domain module stores an independent duplicate of canonical object state.
- Relationships survive save/reload.
- Provenance survives transformations and artifact generation.
- Truth classes remain distinguishable.
- Agent edits are attributable and revisioned.
- Simulation state cannot silently overwrite observed/recorded truth.
- RealityKit selection round-trips through ObjectID.

## Golden workflow tests
1. Create project.
2. Add equipment and component topology.
3. Attach source document and create cited claim.
4. Open same object from project, search, 3D, and investigation views; identity must remain identical.
5. Create simulated fault.
6. Capture modeled and observed measurements without conflating truth classes.
7. Create multiple hypotheses.
8. Choose/run discriminating test.
9. Mark first divergence.
10. Create repair procedure and task.
11. Verify repair.
12. Generate report with source/evidence lineage.
13. Generate training scenario from case.
14. Save/reload and verify graph, events, claims, measurements, revisions, and timeline.

## UX gates
- Mac supports keyboard-first operation without hiding visual controls.
- iPad adapts without desktop compression.
- iPhone supports complete Golden Slice field workflow.
- Status is never encoded by color alone.
- Empty states teach next action.
- Errors explain cause, preserved state, and recovery.
- Long-running work exposes meaningful progress.

## Agent gates
- No external action without appropriate permission.
- Agent goal/plan/actions/tools/evidence/output/errors/approvals are inspectable.
- Failed actions preserve prior valid state.
- Draft and external-action states are distinct.

## Performance gates
- Core object/project browsing works offline.
- Large telemetry datasets do not block UI thread.
- 3D rendering is decoupled from canonical simulation state.
- Persistence migrations are tested.

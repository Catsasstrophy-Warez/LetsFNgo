# Nexus (LetsFNgo)

Read `docs/handoff/LOCKED_DECISIONS.md` and `docs/BUILD_PLAN.md` before changing architecture.

## Build and test
- Swift 6.2 SwiftPM package. `swift build` / `swift test`.
- Linux needs `libsqlite3-dev` (with FTS5, which Ubuntu's build includes).
- Cloud sessions have no Swift preinstalled. Install it with:
  `curl -sSfL https://download.swift.org/swift-6.2-release/ubuntu2404/swift-6.2-RELEASE/swift-6.2-RELEASE-ubuntu24.04.tar.gz | tar xz -C /opt`
  then `export PATH=/opt/swift-6.2-RELEASE-ubuntu24.04/usr/bin:$PATH`.

## Rules
- Everything outside Apple-only targets must build and test on Linux. Apple frameworks (SwiftUI, RealityKit, FoundationModels, AppIntents, CoreSpotlight) go only in Apple-only targets, behind `#if canImport(...)`.
- Domain modules never keep their own canonical store; all state goes through `NexusPersistence`.
- Every stored value keeps its `TruthClass` and `Provenance`. Recorded/observed values are protected by `TruthPolicy`.
- Migrations are append-only (`Sources/NexusPersistence/Migrations.swift`); never edit a shipped one.
- Tests use Swift Testing (`import Testing`).

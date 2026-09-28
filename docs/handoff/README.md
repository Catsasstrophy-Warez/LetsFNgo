# Nexus AI Operating Environment - AI Handoff Package

This package transfers the complete product concept developed in the conversation: a unified Apple-first AI operating environment combining 36 application categories into one object-centric world model.

## Start here
1. Read `START_HERE_PROMPT.txt`.
2. Read `MASTER_PRODUCT_SPEC.md`.
3. Read `LOCKED_DECISIONS.md` before changing architecture.
4. Read `UX_18_SCREEN_SYSTEM.md` before implementing UI.
5. Read `DATA_AGENT_SIMULATION_ARCHITECTURE.md` before implementing persistence, agents, engineering, telemetry, or digital twins.
6. Follow `IMPLEMENTATION_ROADMAP.md` in order.

## Core principle
Do NOT build 36 disconnected mini-apps and do NOT make chat history the database.

Build one canonical world model:

Project -> Object -> Relationship -> Event -> Evidence -> Action

Objects own context. Projects organize objects. Agents act on objects. Artifacts communicate about objects. Every important value has provenance.

## Target platforms
- iPhone
- iPad
- macOS

Apple-first native stack:
- Swift 6+
- SwiftUI
- SQLite + FTS5
- RealityKit for spatial/digital-twin UI
- Metal only where high-throughput visualization justifies it

## Package contents
- START_HERE_PROMPT.txt - prompt to give another coding AI
- MASTER_PRODUCT_SPEC.md - complete product definition
- LOCKED_DECISIONS.md - non-negotiable architectural decisions
- UX_18_SCREEN_SYSTEM.md - canonical UX architecture
- DATA_AGENT_SIMULATION_ARCHITECTURE.md - world model, provenance, agents, permissions, simulation
- COMPETITIVE_RESEARCH_SYNTHESIS.md - findings from the 900-app / 36-category research program
- IMPLEMENTATION_ROADMAP.md - build sequence and Golden Vertical Slice
- ACCEPTANCE_TESTS.md - architectural and product acceptance gates
- conversation_requirements.md - consolidated requirements derived from the conversation
- manifest.json - machine-readable package map
- Nexus_Master_Handoff.docx - portable human-readable master handoff


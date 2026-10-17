# Changelog

All notable changes to GT500 Companion, newest first. Research notes for each round live in
`research_notes/Shelby GT500 2020 to 2022/`.

## Round 14 — direction audit, Spanish data, native CI, field-test kit
- Direction-sign audit of all 9 OSM start/finish lines: signs re-derived independently and confirmed correct (no data change), with a table-driven loop-drive test per gate (laps forward, none in reverse).
- Lap timer: one-tap **Flip direction** / **Either direction** for sourced lines, remembered per line on the device.
- Spanish overlay for sourced spec labels and notes (`src/data/es.ts`), with English fallback, a visible "traducido" marker and a key-existence test.
- Manual-only native workflow: unsigned Android debug APK artifact (Capacitor + Gradle) and an iOS `cap sync` check on macOS.
- Opt-in, local-only Diagnostics page (Settings → Advanced) logging anonymized GPS, lap and OBD timings, with JSON export.
- Fixes: `BUS INIT: ...OK` treated as an OBD error; BLE connection leak on setup failure and slow failure on drop; OBD transport left open after a failed init; near-zero red lights reloading as perfect lights; "1/4 mile" in Ask; duplicate track-day and packing ids.

## Round 13 — OBD-II, trainers and planning
- OBD-II live gauges over Web Bluetooth (BLE ELM327), with supported-PID detection, boost from MAP − baro, session CSV and an attach-to-log summary. Read-only by construction (no Mode 04). Demo mode clearly labelled.
- Read-only trouble-code viewer (Mode 03/07, P/C/B/U decoding; descriptions not included, generic lookup link).
- Drag tree trainer (sportsman .5 / pro .4, red lights, stats); offline "Ask the data" over sourced facts; track day planner with packing lists and `.ics`; backup schema v9.
- Competitor prices by model year from round 11 research; `dist/.preview-manifest.json` for tooling.
- Fixes: photo restore no longer wipes existing photos on a bad file and respects quotas; checklist item id collisions; the lap timer drops a sourced line when the track changes.

## Round 12 — track tools and OpenStreetMap lines
- Track map: GPS sessions drawn as an SVG map colored by speed, with sector table and theoretical best.
- Photo attachments on service, mods and track sessions (IndexedDB, size quotas); backup schema v8 with optional photos.
- Pre-track checklist built from the sourced track-use schedule; car-color accent theme.
- 9 OpenStreetMap start/finish lines for 8 tracks (unverified, derived gates) in `src/data/startFinishLines.ts`, under ODbL — see `LICENSE-DATA-OSM.md`.

## Round 11 — GPS lap timer
- GPS lap timer with on-site start/finish and sector lines, live delta, refused-lap rules; session analysis with CSV/GPX export.
- Opt-in weather auto-fill (Open-Meteo, location rounded to ~1 km); fuzzy, typo-tolerant search.
- 29-track list (facility points only), competitor base MSRPs, backup schema v7.

## Round 10 — data quality
- Data coverage page, JSON Schemas with `npm run validate:data` in CI, contribution guide and issue form.
- Weekly/manual source link checker; dead sources replaced with Wayback snapshots or flagged.
- Accessible charts (keyboard points, data tables), visual regression baselines recorded on the CI runner.

## Rounds 8–9 — ownership and editions
- Multi-car Garage, resale service-history report, `.ics` export, market values from auction data, achievements, full Spanish UI.
- Whole-repo security review (strict CSP, export escaping), Shelby American editions, Ford Performance parts, history timeline, help page, install prompt.

## Rounds 1–7 — foundation
- Sourced research report and app: specs, model years, colors and paint codes, pricing, performance, recalls with GT500 applicability, maintenance schedule and fluids, VIN decoder, Garage, track/drag/dyno/fuel logs, calculators, build planner, compare, media, trivia, settings, offline PWA, CI.

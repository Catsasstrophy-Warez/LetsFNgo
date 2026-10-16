# LetsFNgo — GT500 Companion

An unofficial, mobile-first PWA reference for the 2020–2022 Ford Mustang Shelby GT500: specs by system, model years and Shelby American editions, colors, packages and pricing, performance, a working VIN decoder, ownership/recalls, a local "Garage", mods, competitor comparison, embedded media, community links and a full source list.

Every fact carries a source URL and a confidence level (`confirmed` / `reported` / `unverified`). Conflicting figures (e.g. curb weight) are shown with every sourced value, and unknowns are `null` with a note — nothing is invented. Content comes from `reports/Shelby GT500 2020 to 2022.md` and `research_notes/` (rounds 1–3). The Compare spec-sheet table uses round-3 figures, each with its own source. Rows from low-quality or database-only sources (Redeye, Jailbreak) are unverified and hidden until you ask to see them.

## Run

Requires Node 20+ (react-router 7).

```sh
npm install
npm run dev        # local dev server
npm run build      # typecheck + production build to dist/
npm run preview    # serve the build
npm test           # Vitest: VIN decoder, data integrity, tool math, DA/fuel/quiz/units, backup validation & migration, SW update flow, page render tests
npm run typecheck
npm run lint
npm run e2e        # Playwright (Chromium) + axe-core: every route in dark and light themes, onboarding, timer, GPS meter (mocked geolocation), timeline, planner; needs `npm run build` first
```

CI (`.github/workflows/ci.yml`, Node 20) runs `npm ci`, typecheck, lint, unit tests and build on every push and pull request. Routing uses `react-router` 7 (`HashRouter`); `npm audit` reports 0 vulnerabilities.

## Layout

- `src/data/` — typed content (`types.ts`, `specs.ts`, `modelYears.ts`, `colors.ts`, `packages.ts`, `pricing.ts`, `production.ts`, `performance.ts`, `recalls.ts`, `maintenance.ts`, `vin.ts`, `mods.ts`, `competitors.ts`, `communities.ts`, `media.ts`; `index.ts` aggregates them)
- `src/lib/vin.ts` — NHTSA check-digit validation and GT500 pattern decoding
- `src/lib/gearing.ts` — mph per gear / rpm at speed from the sourced TR-9070 ratios, 3.73 final drive and 315/30R20 rear tire (custom inputs allowed)
- `src/lib/perf.ts` — Hale and Fox quarter-mile ET/trap **estimates** and power-to-weight
- `src/lib/laptime.ts` — `m:ss.sss` lap parsing, best/average/theoretical-best (sum of best sectors); `refLaps.ts` matches Laguna Seca / VIR to sourced reference laps
- `src/lib/planner.ts` — build-plan totals; sums only price ranges a source lists (`cost` on `ModStage`) and never combines horsepower
- `src/lib/garage.ts` — Garage, plans, track and reminder types, localStorage keys, due-soon/overdue logic
- `src/lib/backup.ts` — JSON export/import (`app: "gt500-companion"`, `schema: 3`; v1 files migrate with empty drag/fuel and default settings; v2 files gain `onboarding` marked done), 2 MB import cap, reset-all
- `src/lib/timer.ts` — pure stopwatch (start/pause/lap with a 1 s double-tap guard), laps written as Track-log text
- `src/lib/gps.ts` — GPS meter math: haversine, Doppler-or-derived speed, launch detection, interpolated 0–60 / 60–130 / ¼-mile timing, accuracy (±10 m) and gap (2.5 s) refusal; synthetic traces for tests
- `src/lib/compat.ts` — Build-planner compatibility rules derived only from sourced records (DCT clutch rating vs sourced wheel torque, E85 fuel parts each source lists, one blower/turbo replacement, race-fuel results) and order-of-ops by sourced stage
- `src/lib/timeline.ts` — combined chronological events from Garage service/mods, track, drag and fuel; filters and yearly counts/spend
- `src/lib/yearDiff.ts` — 2020/2021/2022 color, package and price presence generated from data; GT500-vs-rival head-to-head with sourced-only values
- `src/lib/onboarding.ts` — first-run intro state (`gt500.onboarding.v1`), Garage seeding
- `src/lib/validate.ts` — strict allow-list normalizers used by both import and every localStorage loader, so corrupt or legacy data falls back instead of crashing
- `src/lib/units.ts` — settings (`gt500.settings.v1`: units, theme incl. "match device"), imperial↔metric conversion; data is stored imperial and converted for display/entry
- `src/lib/drag.ts` — timeslips (`gt500.drag.v1`), density altitude (humidity → virtual temperature → density from station pressure → ISA altitude), DA-corrected ET **estimate**, best/consistency stats, sourced stock passes
- `src/lib/fuel.ts` — fill-ups (`gt500.fuel.v1`), full-to-full mpg, cost per mile, ownership cost (fuel + Garage service and mods costs)
- `src/lib/quiz.ts` — trivia generated only from confirmed/reported records (`gt500.quiz.v1` score); `src/lib/paint.ts` — color visualizer counts and rarity rank
- `src/lib/sw.ts` — service-worker "update ready" flow; `src/components/LineChart.tsx` — accessible inline-SVG trend chart
- `src/lib/shareCard.ts` — 1080×1080 canvas spec card (generic silhouette, no logos)
- `src/pages/` — screens; `public/` — manifest, icons, service worker

## Deploying under a subpath

`vite.config.ts` uses `base: './'` and the app uses `HashRouter`, so `dist/` works from any folder (e.g. `https://host/sub/`) without server rewrites. The service worker registers relative to the page, so its scope becomes that folder.

## Tools

- **Gear & Speed** (`/gearing`), **Performance Tools** (`/tools`), **Build Planner** (`/planner`), **Track Day Log** (`/track`, with a best-lap trend chart).
- **Drag Strip Log** (`/drag`): RT, 60 ft, 330 ft, ⅛ and ¼ ET/speed, DA, weather and a snapshot of Garage mods per pass; density-altitude calculator; a clearly labelled DA-corrected ET estimate; best and consistency stats; ET trend chart; comparison with sourced stock passes.
- **Fuel & Cost** (`/fuel`): fill-ups (93 / E85 / blend), mpg and cost-per-mile charts, ownership cost summary.
- **Color Visualizer** (`/visualizer`), **Trivia Quiz** (`/quiz`), **Print Spec Sheet** (`/print`, uses `@media print`).
- **Settings** (`/settings`): units, theme, and data management (export / import / reset all). Garage links there.
- **Garage** adds maintenance reminders (miles and/or months, due soon within 500 mi / 30 days). Default intervals are user-set placeholders — Ford's 2020–22 GT500 schedule is not sourced here. It also has the share-card PNG and backup/restore.
- **Session Timer** (`/timer`): big touch buttons, lap splits, Screen Wake Lock while running (falls back with a note where unsupported); saves laps straight into the Track log.
- **GPS Meter** (`/gps`, approximate): permission-gated, only starts when you tap **Arm GPS**; shows live accuracy and refuses to report when any fix in the run is worse than ±10 m or fixes are > 2.5 s apart; handles permission denied. Results save to the Drag log labelled "GPS estimate" and are excluded from strip stats. No CSP change is needed for geolocation.
- **Ownership Timeline** (`/timeline`): every dated entry from Garage service and mods, Track, Drag and Fuel logs with type/year filters and a yearly summary.
- **Year & Rival Compare** (`/diff`): 2020 vs 2021 vs 2022 colors, packages and prices (conflicts kept), and a GT500-vs-any-rival head-to-head using only sourced values; hidden unverified sheets stay hidden unless requested.
- **Build Planner** shows sourced compatibility warnings and a suggested order.
- **Welcome** (`/welcome`): a skippable 3-step first-run intro (year/color, optional VIN, units) that seeds the Garage; shown only when the intro was never completed and the Garage is empty; re-run from Settings.
- Accessibility: the e2e suite runs axe-core (WCAG 2.1 A/AA) on every route in both themes and requires 0 serious/critical violations. Fixes from the audit: dark-theme button/active-link contrast (`--accent-btn`), video placeholder accessible names, focusable scrollable tables.
- Home shows a Garage summary and the next maintenance due. All tools appear in the menu and in Search.
- Every route except Home is lazy-loaded. After the service worker registers, the app fetches each route chunk once so it is cached for offline use.
- The build stamps `dist/sw.js` with a per-build cache name and the list of emitted assets; old caches are deleted on activate. Only `ok`, same-origin, non-redirected responses are cached. A new version waits until you tap **Reload** in the "Update ready" banner (the page posts `SKIP_WAITING`, then reloads on `controllerchange`). An "Offline" banner shows when the connection drops, and a warning appears if the browser refuses to save data.
- `index.html` sets a Content-Security-Policy (self, Wikimedia images, youtube-nocookie and freesound frames). YouTube embeds are sandboxed and ids are validated.
- Ownership groups Mustang NHTSA recalls by GT500 applicability (applies / likely / depends on VIN / not applicable) from round-4 review of the recall documents, with build windows. Fluids added from a 2021 GT500 supplement are marked `reported`; its service-interval table is `unverified` because the PDF columns were misaligned.

Garage, plans (`gt500.plans.v1`), track sessions (`gt500.track.v1`), timeslips (incl. GPS estimates), fill-ups, settings, intro state and quiz score are kept only in the browser's `localStorage`. Videos are embedded from youtube-nocookie.com and load only on tap; no copyrighted images are re-hosted, and the car art is generic CSS/SVG.

## Disclaimer

This is an independent fan project. It is not affiliated with, endorsed by or sponsored by Ford Motor Company, Shelby American, Inc. or Carroll Shelby Licensing. "Ford", "Mustang", "Shelby", "GT500" and "Cobra" are trademarks of their respective owners and are used here only to identify the vehicle. No logos are used. Figures are compiled from third-party sources and may be wrong; verify with official Ford documents, NHTSA and your dealer. Nothing here is legal or mechanical advice.

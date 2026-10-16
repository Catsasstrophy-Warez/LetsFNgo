# LetsFNgo — GT500 Companion

An unofficial, mobile-first PWA reference for the 2020–2022 Ford Mustang Shelby GT500: specs by system, model years and Shelby American editions, colors, packages and pricing, performance, a working VIN decoder, ownership/recalls, a local "Garage", mods, competitor comparison, embedded media, community links and a full source list.

Every fact carries a source URL and a confidence level (`confirmed` / `reported` / `unverified`). Conflicting figures (e.g. curb weight) are shown with every sourced value, and unknowns are `null` with a note — nothing is invented. Content comes from `reports/Shelby GT500 2020 to 2022.md` and `research_notes/`.

## Run

Requires Node 18+.

```sh
npm install
npm run dev        # local dev server
npm run build      # typecheck + production build to dist/
npm run preview    # serve the build
npm test           # Vitest: VIN decoder, data integrity, tool math, backup validation, route render smoke tests
npm run typecheck
npm run lint
```

## Layout

- `src/data/` — typed content (`types.ts`, `specs.ts`, `modelYears.ts`, `colors.ts`, `packages.ts`, `pricing.ts`, `production.ts`, `performance.ts`, `recalls.ts`, `maintenance.ts`, `vin.ts`, `mods.ts`, `competitors.ts`, `communities.ts`, `media.ts`; `index.ts` aggregates them)
- `src/lib/vin.ts` — NHTSA check-digit validation and GT500 pattern decoding
- `src/lib/gearing.ts` — mph per gear / rpm at speed from the sourced TR-9070 ratios, 3.73 final drive and 315/30R20 rear tire (custom inputs allowed)
- `src/lib/perf.ts` — Hale and Fox quarter-mile ET/trap **estimates** and power-to-weight
- `src/lib/laptime.ts` — `m:ss.sss` lap parsing, best/average/theoretical-best (sum of best sectors); `refLaps.ts` matches Laguna Seca / VIR to sourced reference laps
- `src/lib/planner.ts` — build-plan totals; sums only price ranges a source lists (`cost` on `ModStage`) and never combines horsepower
- `src/lib/garage.ts` — Garage, plans, track and reminder types, localStorage keys, due-soon/overdue logic
- `src/lib/backup.ts` — JSON export/import (`app: "gt500-companion"`, `schema: 1`) with validation
- `src/lib/shareCard.ts` — 1080×1080 canvas spec card (generic silhouette, no logos)
- `src/pages/` — screens; `public/` — manifest, icons, service worker

## Tools

- **Gear & Speed** (`/gearing`), **Performance Tools** (`/tools`), **Build Planner** (`/planner`), **Track Day Log** (`/track`).
- **Garage** adds maintenance reminders (miles and/or months, due soon within 500 mi / 30 days). Default intervals are user-set placeholders — Ford's 2020–22 GT500 schedule is not sourced here. It also has the share-card PNG and backup/restore.
- Home shows a Garage summary and the next maintenance due. All tools appear in the menu and in Search.
- Every route except Home is lazy-loaded. After the service worker registers, the app fetches each route chunk once so it is cached for offline use.

Garage, plans (`gt500.plans.v1`) and track sessions (`gt500.track.v1`) are kept only in the browser's `localStorage`. Videos are embedded from youtube-nocookie.com and load only on tap; no copyrighted images are re-hosted, and the car art is generic CSS/SVG.

## Disclaimer

This is an independent fan project. It is not affiliated with, endorsed by or sponsored by Ford Motor Company, Shelby American, Inc. or Carroll Shelby Licensing. "Ford", "Mustang", "Shelby", "GT500" and "Cobra" are trademarks of their respective owners and are used here only to identify the vehicle. No logos are used. Figures are compiled from third-party sources and may be wrong; verify with official Ford documents, NHTSA and your dealer. Nothing here is legal or mechanical advice.

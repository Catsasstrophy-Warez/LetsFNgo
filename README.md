# LetsFNgo — GT500 Companion

An unofficial, mobile-first PWA reference for the 2020–2022 Ford Mustang Shelby GT500: specs by system, model years and Shelby American editions, colors, packages and pricing, performance, a working VIN decoder, ownership/recalls, a local "Garage", mods, competitor comparison, embedded media, community links and a full source list.

Every fact carries a source URL and a confidence level (`confirmed` / `reported` / `unverified`). Conflicting figures (e.g. curb weight) are shown with every sourced value, and unknowns are `null` with a note — nothing is invented. Content comes from `reports/Shelby GT500 2020 to 2022.md` and `research_notes/` (rounds 1–6; round 5 adds paint codes FA/HY/EB, the 2021 base MSRP, the re-extracted 2021 service schedule and stock dyno baselines; round 6 adds a few mod prices, Ford Performance part numbers and a forum-transcribed track alignment, all with low or reported confidence). The Compare spec-sheet table uses round-3 figures, each with its own source. Rows from low-quality or database-only sources (Redeye, Jailbreak) are unverified and hidden until you ask to see them.

## Run

Requires Node 20+ (react-router 7).

```sh
npm install
npm run dev        # local dev server
npm run build      # typecheck + production build to dist/
npm run preview    # serve the build
npm test           # Vitest: VIN decoder, round-7 review regressions, i18n, parts, guides, fact export, prefetch, data integrity, tool math, DA/fuel/quiz/units, backup validation & migration, SW update flow, page render tests
npm run typecheck
npm run lint
npm run lighthouse # Lighthouse mobile preset on the built app (needs Chromium; see below)
npm run e2e        # Playwright (Chromium) + axe-core: every route in dark and light themes, onboarding, timer, GPS meter (mocked geolocation), timeline, planner; needs `npm run build` first
```

CI (`.github/workflows/ci.yml`, Node 20) has two jobs on every push and pull request: `build` (`npm ci`, typecheck, lint, unit tests, build) and `e2e` (`npx playwright install --with-deps chromium` for the pinned @playwright/test version, build, then the Playwright + axe suite; the HTML report is uploaded as the `playwright-report` artifact on failure). Routing uses `react-router` 7 (`HashRouter`); `npm audit` reports 0 vulnerabilities.

## Native apps (Capacitor)

The PWA can be wrapped as iOS and Android apps with [Capacitor 7](https://capacitorjs.com/) (`capacitor.config.ts`, app id `io.github.catsasstrophywarez.gt500companion`, `webDir: 'dist'`). The generated `ios/` and `android/` projects are git-ignored, so create them locally:

```sh
npm run cap:add      # once: npx cap add ios && npx cap add android (iOS needs macOS + Xcode + CocoaPods; Android needs Android Studio)
npm run cap:sync     # build the web app and copy dist/ into both native projects; run after every change
npm run cap:ios      # open Xcode
npm run cap:android  # open Android Studio
```

The app already works inside the WebView: `HashRouter` keeps every route after `#`, and Vite's `base: './'` makes every asset URL relative, so `capacitor://localhost` (iOS) and `https://localhost` (Android) need no rewrites. In the native wrapper (`window.Capacitor.isNativePlatform()`), `src/lib/platform.ts` skips the service worker and the offline warm-up, because the assets ship inside the app and iOS WKWebView does not support service workers. Maintenance notifications use the web Notification API and fall back to the in-app explanation where the WebView lacks it. No native plugins are used yet.

## Performance

Route chunks are prefetched when you hover, focus or touch a link, and when a link scrolls into view once the browser is idle (skipped with Data Saver on) (`src/lib/prefetch.ts`). The offline warm-up of every chunk now runs only after a service worker has registered. Run Lighthouse on the production build with `npm run build && npm run lighthouse [-- /route …]`. It uses `npx lighthouse@12` with the mobile preset and Chromium from `CHROME_PATH`, defaulting to `/opt/pw-browsers/chromium-1194/chrome-linux/chrome`, and writes JSON reports to `.lighthouse/`.

Last run (mobile preset, local `vite preview`):

| Route | Performance | Accessibility | Best practices | SEO |
|---|---|---|---|---|
| `/` | 100 | 100 | 100 | 100 |
| `/specs` | 99 | 100 | 100 | 100 |
| `/parts` | 99 | 100 | 100 | 100 |
| `/guides/track-service` | 99 | 100 | 100 | 100 |
| `/sources` | 98 | 100 | 100 | 100 |
| `/settings` | 98 | 100 | 100 | 100 |

Fixes made after the first run:
- Layout shift: the lazy-route loading placeholder now reserves the viewport height, so the footer no longer jumps. CLS went from 0.10 to 0.
- Touch targets: Sources page links now meet the 24 px target size.
- SEO: added `robots.txt`.

## Layout

- `src/data/` — typed content (`types.ts`, `specs.ts`, `modelYears.ts`, `colors.ts`, `packages.ts`, `pricing.ts`, `production.ts`, `performance.ts`, `recalls.ts`, `maintenance.ts`, `vin.ts`, `mods.ts`, `competitors.ts`, `communities.ts`, `media.ts`; `index.ts` aggregates them)
- `src/lib/vin.ts` — NHTSA check-digit validation and GT500 pattern decoding
- `src/lib/gearing.ts` — mph per gear / rpm at speed from the sourced TR-9070 ratios, 3.73 final drive and 315/30R20 rear tire (custom inputs allowed)
- `src/lib/perf.ts` — Hale and Fox quarter-mile ET/trap **estimates** and power-to-weight
- `src/lib/laptime.ts` — `m:ss.sss` lap parsing, best/average/theoretical-best (sum of best sectors); `refLaps.ts` matches Laguna Seca / VIR to sourced reference laps
- `src/lib/planner.ts` — build-plan totals; sums only price ranges a source lists (`cost` on `ModStage`) and never combines horsepower
- `src/lib/garage.ts` — Garage, plans, track and reminder types, localStorage keys, due-soon/overdue logic
- `src/lib/backup.ts` — JSON export/import (`app: "gt500-companion"`, `schema: 4`; v1 files migrate with empty drag/fuel and default settings; v2 files gain `onboarding` marked done; v3 files gain empty `dyno`, notifications off and the default Home layout), 2 MB import cap, reset-all
- `src/lib/dyno.ts` — dyno pulls (`gt500.dyno.v1`), SAE J1349 and STD (J607) correction factors from dry-air pressure and temperature, conversion between them, curve parsing (≤ 400 points); `src/data/dyno.ts` — sourced stock baselines (`dynoBaselines`) with a dyno-type/correction caveat
- `src/lib/share.ts` — versioned base64url share links (`#/share/<payload>`, ≤ 2,000 chars, strict allow-list decode; never includes a VIN)
- `src/lib/notify.ts` — opt-in local maintenance notifications (`gt500.notify.v1`) via `ServiceWorkerRegistration.showNotification`, checked on app open, one alert per due point
- `src/lib/tires.ts` — tire diameter, revs/mile, speedometer error, effective final drive and speed per gear (uses `gearing.ts`)
- `src/lib/roi.ts` — cost per wheel-hp from a sourced `cost` and sourced `gain` only; `src/lib/dashboard.ts` — Home card order/visibility (`gt500.home.v1`)
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
- `src/data/parts.ts` — `partNumbers` (typed `PartNumber`: number, brand, category, `kind` part/spec/avoid, links to `maintenance` ids and default Garage reminder ids). Seeded only from numbers already cited in `maintenance.ts` (FL-2087, SP-581, XT-14-L, VC-13DL-G, the Ford WSS fluid specs, XT-11-QDC marked "do not use") plus the round-6 part numbers M-6766-A52 and M-16601-MCF (reported) and FL-500-S (unverified, with a fitment caveat). Items with no sourced number (air/cabin filters, pads, wipers…) are listed as empty slots.
- `src/data/guides.ts` — typed `Guide`s: steps (each with its own source and confidence), warnings, tools (empty when none are sourced), related parts, and `status: 'planned'` slots with no steps. Ready guides: track-day maintenance (2021 supplement), DCT fluid, and track alignment (forum transcription, unverified). Break-in is a planned slot: the only text found is from the 2014 supplement, so it is not presented as 2020–22 guidance. A guide's confidence is never higher than its weakest step (tested).
- `src/lib/i18n.ts` — dependency-free typed i18n: `en` is the complete dictionary (`MsgKey`), and `es` covers navigation, the app chrome and Settings, falling back to English per key. `useT()` reads the language from settings (`settings.lang`; no schema bump because it lives inside `settings`). Sourced facts stay in English.
- `src/lib/factExport.ts` — every sourced fact flattened to rows (collection, id, path, label, value, source, confidence, note). Nested citations such as conflicts and guide steps get their own rows. CSV output uses RFC 4180 quoting with formula-injection guarding; JSON is also available.
- `src/lib/checklist.ts` — guide ticks in `sessionStorage` (`gt500.guide.<id>`), kept for the browser session only and not backed up. `src/lib/parts.ts` — dash-insensitive part search, clipboard copy with a fallback. `src/lib/wakelock.ts` — Screen Wake Lock controller with an overlapping-request guard. `src/lib/platform.ts` — Capacitor detection.
- `src/pages/` — screens; `public/` — manifest, icons, service worker

## Deploying under a subpath

`vite.config.ts` uses `base: './'` and the app uses `HashRouter`, so `dist/` works from any folder (e.g. `https://host/sub/`) without server rewrites. The service worker registers relative to the page, so its scope becomes that folder.

## Tools

- **Gear & Speed** (`/gearing`), **Performance Tools** (`/tools`), **Build Planner** (`/planner`), **Track Day Log** (`/track`, with a best-lap trend chart).
- **Drag Strip Log** (`/drag`): RT, 60 ft, 330 ft, ⅛ and ¼ ET/speed, DA, weather and a snapshot of Garage mods per pass; density-altitude calculator; a clearly labelled DA-corrected ET estimate; best and consistency stats; ET trend chart; comparison with sourced stock passes.
- **Fuel & Cost** (`/fuel`): fill-ups (93 / E85 / blend), mpg and cost-per-mile charts, ownership cost summary.
- **Color Visualizer** (`/visualizer`), **Trivia Quiz** (`/quiz`), **Print Spec Sheet** (`/print`, uses `@media print`).
- **Settings** (`/settings`): units, theme, and data management (export / import / reset all). Garage links there.
- **Garage** adds maintenance reminders (miles and/or months, due soon within 500 mi / 30 days). Default intervals come from the 2021 GT500 owner-manual supplement (reported; 2020/2022 unconfirmed) and remain editable. It also has the share-card PNG and backup/restore.
- **Session Timer** (`/timer`): big touch buttons, lap splits, Screen Wake Lock while running (falls back with a note where unsupported); saves laps straight into the Track log.
- **GPS Meter** (`/gps`, approximate): permission-gated, only starts when you tap **Arm GPS**; shows live accuracy and refuses to report when any fix in the run is worse than ±10 m or fixes are > 2.5 s apart; handles permission denied. Results save to the Drag log labelled "GPS estimate" and are excluded from strip stats. No CSP change is needed for geolocation.
- **Ownership Timeline** (`/timeline`): every dated entry from Garage service and mods, Track, Drag and Fuel logs with type/year filters and a yearly summary.
- **Year & Rival Compare** (`/diff`): 2020 vs 2021 vs 2022 colors, packages and prices (conflicts kept), and a GT500-vs-any-rival head-to-head using only sourced values; hidden unverified sheets stay hidden unless requested.
- **Build Planner** shows sourced compatibility warnings and a suggested order, a cost-per-hp view ("insufficient data" unless a mod has both a sourced price and a sourced gain; the only example is the JLT intake, whose gain is an unverified manufacturer claim), and a share-as-link button.
- **Dyno Log** (`/dyno`): whp/wtq, dyno type, correction, weather, Garage mods snapshot, optional curve points drawn as an SVG overlay of up to 5 pulls; SAE ↔ STD converter; sourced stock baselines (664–723 whp across sources).
- **Tire & Wheel Calc** (`/tires`): stock vs alternate size.
- **Shared links** (`#/share/…`): read-only plan or car view with Import to Build Planner / Garage. Create them from the Planner or Garage.
- **Notifications** (Settings): permission-gated; falls back to an explanation where unsupported or blocked. There is no push server, so alerts only appear when the app is opened.
- **Home** can be customized (reorder / hide cards), saved on the device.
- **Year & Rival Compare** tables become stacked cards under 600 px.
- **Welcome** (`/welcome`): a skippable 3-step first-run intro (year/color, optional VIN, units) that seeds the Garage; shown only when the intro was never completed and the Garage is empty; re-run from Settings.
- Accessibility: the e2e suite runs axe-core (WCAG 2.1 A/AA) on every route in both themes and requires 0 serious/critical violations. Fixes from the audit: dark-theme button/active-link contrast (`--accent-btn`), video placeholder accessible names, focusable scrollable tables.
- **Parts & Fluids** (`/parts`): searchable (`?q=`, e.g. `fl2087`), copy-to-clipboard, confidence badges, related maintenance facts; Garage reminders link to their parts (e.g. oil → FL-2087).
- **How-to Guides** (`/guides`, `/guides/:id`): step-by-step pages with tickable checklists (kept for the session), per-step citations, warnings, tools and parts.
- **Language** (Settings): English or Español for menus, navigation and Settings; `<html lang>` follows.
- **Sources** has **Download CSV / JSON** of all sourced facts with source and confidence, for researchers.
- **Round-6 mods**: JLT Big Air intake ($399; +25–30 rwhp is a manufacturer claim with no dyno sheet, unverified) is now the one cost-per-hp example; VMP Stage 2 Pulley Pack ($1,399.99) and Predator EO Drag Pack ($2,339.99) have reported prices and no gain; the FordMuscle bolt-on build (674 → 828 rwhp, 561 → 666 lb-ft on E85) is one combined record with no per-part attribution. The VMP Odin kit is for the Coyote and F-150, not the GT500, and is not listed.
- Home shows a Garage summary and the next maintenance due. All tools appear in the menu and in Search.
- Every route except Home is lazy-loaded. After the service worker registers, the app fetches each route chunk once so it is cached for offline use.
- The build stamps `dist/sw.js` with a per-build cache name and the list of emitted assets; old caches are deleted on activate. Only `ok`, same-origin, non-redirected responses are cached. A new version waits until you tap **Reload** in the "Update ready" banner (the page posts `SKIP_WAITING`, then reloads on `controllerchange`). An "Offline" banner shows when the connection drops, and a warning appears if the browser refuses to save data.
- `index.html` sets a Content-Security-Policy (self, Wikimedia images, youtube-nocookie and freesound frames). YouTube embeds are sandboxed and ids are validated.
- Ownership groups Mustang NHTSA recalls by GT500 applicability (applies / likely / depends on VIN / not applicable) from round-4 review of the recall documents, with build windows. Fluids added from a 2021 GT500 supplement are marked `reported`; its service-interval table is `unverified` because the PDF columns were misaligned.

Garage, plans (`gt500.plans.v1`), track sessions (`gt500.track.v1`), timeslips (incl. GPS estimates), fill-ups, settings, intro state and quiz score are kept only in the browser's `localStorage`. Videos are embedded from youtube-nocookie.com and load only on tap; no copyrighted images are re-hosted, and the car art is generic CSS/SVG.

## Disclaimer

This is an independent fan project. It is not affiliated with, endorsed by or sponsored by Ford Motor Company, Shelby American, Inc. or Carroll Shelby Licensing. "Ford", "Mustang", "Shelby", "GT500" and "Cobra" are trademarks of their respective owners and are used here only to identify the vehicle. No logos are used. Figures are compiled from third-party sources and may be wrong; verify with official Ford documents, NHTSA and your dealer. Nothing here is legal or mechanical advice.

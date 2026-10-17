# LetsFNgo — GT500 Companion

An unofficial, mobile-first PWA reference for the 2020–2022 Ford Mustang Shelby GT500: specs by system, model years and Shelby American editions, colors, packages and pricing, performance, a working VIN decoder, ownership/recalls, a local "Garage", mods, competitor comparison, embedded media, community links and a full source list.

Every fact carries a source URL and a confidence level (`confirmed` / `reported` / `unverified`). Conflicting figures (e.g. curb weight) are shown with every sourced value, and unknowns are `null` with a note — nothing is invented. Content comes from `reports/Shelby GT500 2020 to 2022.md` and `research_notes/` (rounds 1–8; round 5 adds paint codes FA/HY/EB, the 2021 base MSRP, the re-extracted 2021 service schedule and stock dyno baselines; round 6 adds a few mod prices, Ford Performance part numbers and a forum-transcribed track alignment, all with low or reported confidence; round 7 adds auction results and market medians, and an unverified Wimbledon White code N4; round 8 adds Shelby American editions (Signature Edition, GT500KR, Code Red), 18 Ford Performance catalog items with current MSRP, owner events and press milestones — research levels high/medium/low are kept verbatim and badged confirmed/reported/unverified). The Compare spec-sheet table uses round-3 figures, each with its own source. Rows from low-quality or database-only sources (Redeye, Jailbreak) are unverified and hidden until you ask to see them.

## Run

Requires Node 20+ (react-router 7).

```sh
npm install
npm run dev        # local dev server
npm run build      # typecheck + production build to dist/
npm run preview    # serve the build
npm test           # Vitest (481 tests): security regressions (report CSP/escaping, ICS control chars, CSV formula guard, prototype keys, CSP/Capacitor/SW config, https-only sources), money helpers, round-8 data slots and filters, install prompt, Editions/History/Help/Ford Performance renders and empty states, multi-car Garage + v4→v5→v6→v7 migration, GPS lap timer (synthetic circuits, jitter, gaps, direction, sectors, ghost delta), Open-Meteo parser fixtures, fuzzy search, archived-source display, .ics (escaping/folding), service report, market data/filters, achievements, shortcuts, en/es key parity and Spanish render of every page, Pages workflow triggers, VIN decoder, round-7 review regressions, i18n, parts, guides, fact export, prefetch, data integrity, tool math, DA/fuel/quiz/units, backup validation & migration, SW update flow, page render tests
npm run typecheck
npm run lint
npm run lighthouse # Lighthouse mobile preset on the built app (needs Chromium; see below)
npm run e2e        # Playwright (Chromium) + axe-core: every route in dark and light themes × English and Spanish, multi-car add/switch/delete with legacy migration, report download + print media, .ics download, keyboard shortcuts, market filters, v4 backup import, onboarding, timer, GPS meter (mocked geolocation), timeline, planner; needs `npm run build` first. Round 9 adds: strict-CSP violation check, custom install prompt + dismiss memory, iOS hint, Ford Performance tab keyboard switching, Editions/History (Spanish), Help and manifest shortcuts. Lazy below-the-fold content is scrolled into view before axe runs. Round 11 adds: GPS lap timer with a mocked circuit (drop line, laps, auto-save, Track analysis), mocked Open-Meteo fill + failure, search keyboard navigation and recent searches.
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

The app already works inside the WebView: `HashRouter` keeps every route after `#`, and Vite's `base: './'` makes every asset URL relative, so `capacitor://localhost` (iOS) and `https://localhost` (Android) need no rewrites. In the native wrapper (`window.Capacitor.isNativePlatform()`), `src/lib/platform.ts` skips the service worker and the offline warm-up, because the assets ship inside the app and iOS WKWebView does not support service workers. Maintenance notifications use the web Notification API and fall back to the in-app explanation where the WebView lacks it. No native plugins are used yet. The config pins `server.androidScheme: 'https'`, `cleartext: false`, an empty `allowNavigation`, `android.allowMixedContent: false`, `webContentsDebuggingEnabled: false` and `ios.limitsNavigationsToAppBoundDomains`.

### Unsigned Android APK and iOS check from CI

`.github/workflows/native.yml` runs only when started by hand (**Actions → Native builds (unsigned) → Run workflow**). It does two things:

- **Android**: builds the web app, runs `npx cap add android`, `npx cap sync android` and `./gradlew assembleDebug` (JDK 21, Android SDK), then uploads an **unsigned debug APK** as the workflow artifact `gt500-companion-android-debug-apk`. It is kept for 14 days.
- **iOS** (`macos-latest`): generates `ios/` and runs `npx cap sync ios` to check that the native project syncs. Nothing is built for a device and nothing is signed.

To install the APK on an Android phone, download the artifact zip from the run page and unzip it. Copy the `.apk` to the phone, or run `adb install gt500-companion-debug-*.apk` with USB debugging on. Opening the file on the phone asks you to allow "Install unknown apps" for your file manager or browser. A debug build is signed only with the Android SDK's throwaway debug key, so Android may warn about it. It can't be updated over a build signed with a different key, so uninstall it first.

**Store releases are not automated.** Google Play and the App Store need the owner's own release signing key/keystore, Apple certificates and provisioning profiles, and developer accounts (Google Play Console, Apple Developer Program). None of these are in this repository or its secrets, and the workflow never asks for them.

### Icons and splash screens

`resources/` holds SVG sources (generic stripes and "760", no logos) and their PNG renders: `icon-only`, `icon-foreground`, `icon-background` (1024²) and `splash`, `splash-dark` (2732²). Re-render after editing an SVG with `node scripts/gen-assets.mjs` (Playwright Chromium; set `CHROME_PATH` if needed); it also renders the PWA's full-bleed maskable icons `public/icon-maskable-{192,512}.png`. Then generate every native size:

```sh
npx @capacitor/assets generate --assetPath resources --iconBackgroundColor '#0d0f12' --splashBackgroundColor '#f4f5f7' --splashBackgroundColorDark '#0d0f12'
```

## Performance

Below-the-fold work on `/market` (both SVG charts and the results list) renders only when scrolled near the viewport (`src/components/LazyRender.tsx`, which reserves its height so nothing shifts). The page no longer imports every route module after the service worker registers: the worker already precaches every emitted chunk at install, and evaluating ~40 modules right after load was the main source of blocking time (Market TBT 450 ms → 20 ms). Route chunks are prefetched when you hover, focus or touch a link, and when a link scrolls into view once the browser is idle (skipped with Data Saver on) (`src/lib/prefetch.ts`). Run Lighthouse on the production build with `npm run build && npm run lighthouse [-- /route …]`. It uses `npx lighthouse@12` with the mobile preset and Chromium from `CHROME_PATH`, defaulting to `/opt/pw-browsers/chromium-1194/chrome-linux/chrome`, and writes JSON reports to `.lighthouse/`.

Last run (mobile preset, local `vite preview`, round 9):

| Route | Performance | Accessibility | Best practices | SEO |
|---|---|---|---|---|
| `/` | 99 | 100 | 100 | 100 |
| `/specs` | 99 | 100 | 100 | 100 |
| `/garage` | 95 | 100 | 100 | 100 |
| `/report` | 98 | 100 | 100 | 100 |
| `/market` | 98 | 100 | 100 | 100 |
| `/parts` | 99 | 100 | 100 | 100 |
| `/editions` | 98 | 100 | 100 | 100 |
| `/history` | 99 | 100 | 100 | 100 |
| `/help` | 99 | 100 | 100 | 100 |
| `/settings` | 98 | 100 | 100 | 100 |

Scores vary by a few points from run to run. `/market` was 84–90 before the round-9 changes. The Spanish dictionary is a separate chunk, so English users never download it.

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
- `src/lib/garage.ts` — multi-car Garage (`gt500.cars.v1`: `{ active, cars: [{ id, vin, year, color, nickname, odometer, mods, service, reminders }] }`, up to 12 cars), plans, track and reminder types, due-soon/overdue logic. The single-car key `gt500.garage.v1` is read once and becomes car #1 (id `car1`) without being rewritten; log entries (track, drag, fuel, dyno) carry an optional `carId`, and an entry without one belongs to car #1. `src/lib/carlog.ts` merges one car's entries back into a shared log and purges a deleted car's entries; `src/components/CarContext.tsx` holds the active car and the header switcher state
- `src/lib/backup.ts` — JSON export/import (`app: "gt500-companion"`, `schema: 8`; v1 files migrate with empty drag/fuel and default settings; v2 files gain `onboarding` marked done; v3 files gain empty `dyno`, notifications off and the default Home layout; v4 files turn `garage` into `cars` with one car `car1`, losslessly; v5 files gain `achievements: { seen: [] }`). Entries that point at a car missing from the file are re-homed to its first car. Restoring drops the stale legacy key. 2 MB import cap, reset-all
- `src/lib/dyno.ts` — dyno pulls (`gt500.dyno.v1`), SAE J1349 and STD (J607) correction factors from dry-air pressure and temperature, conversion between them, curve parsing (≤ 400 points); `src/data/dyno.ts` — sourced stock baselines (`dynoBaselines`) with a dyno-type/correction caveat
- `src/lib/share.ts` — versioned base64url share links (`#/share/<payload>`, ≤ 2,000 chars, strict allow-list decode; never includes a VIN)
- `src/lib/notify.ts` — opt-in local maintenance notifications (`gt500.notify.v1`) via `ServiceWorkerRegistration.showNotification`, checked on app open, one alert per due point
- `src/lib/tires.ts` — tire diameter, revs/mile, speedometer error, effective final drive and speed per gear (uses `gearing.ts`)
- `src/lib/roi.ts` — cost per wheel-hp from a sourced `cost` and sourced `gain` only; `src/lib/dashboard.ts` — Home card order/visibility (`gt500.home.v1`)
- `src/lib/timer.ts` — pure stopwatch (start/pause/lap with a 1 s double-tap guard), laps written as Track-log text
- `src/lib/lapTimer.ts` — GPS lap timer math: local x/y projection, segment intersection with crossing side, inverse-accuracy 3-fix smoothing, sub-fix crossing-time interpolation, direction filter and 20 s debounce, laps/sectors with accuracy (±15 m) and gap (3 s) refusal, distance-based ghost delta, capped trace storage (2,000 samples), per-lap speed traces, CSV/GPX export, nearest-facility hint; synthetic circuits for tests
- `src/lib/weather.ts` — opt-in Open-Meteo weather fill: URL builder (coordinates rounded to 2 dp), defensive response parser, injectable fetch
- `src/lib/search.ts` — fuzzy ranked search (diacritic/dash/space-insensitive, Damerau–Levenshtein typo tolerance), grouping, recent searches
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
- `src/lib/i18n.ts` — dependency-free typed i18n: `en` is the reference dictionary (`MsgKey`); `src/lib/i18n-es.ts` is typed `Record<MsgKey, string>`, so a missing Spanish key fails the typecheck, and a test checks key and placeholder parity. Every UI string on every page is translated; sourced facts, data-generated quiz questions and compatibility notes, and text saved into your logs stay in English. `{n|one|other}` gives simple plurals. The Spanish dictionary is its own chunk, loaded before first paint for Spanish users and on demand when switching. `useT()` reads `settings.lang`.
- `src/lib/factExport.ts` — every sourced fact flattened to rows (collection, id, path, label, value, source, confidence, note). Nested citations such as conflicts and guide steps get their own rows. CSV output uses RFC 4180 quoting with formula-injection guarding; JSON is also available.
- `src/lib/checklist.ts` — guide ticks in `sessionStorage` (`gt500.guide.<id>`), kept for the browser session only and not backed up. `src/lib/parts.ts` — dash-insensitive part search, clipboard copy with a fallback. `src/lib/wakelock.ts` — Screen Wake Lock controller with an overlapping-request guard. `src/lib/platform.ts` — Capacitor detection.
- `src/lib/ics.ts` — RFC 5545 calendar export of reminders: TEXT escaping (`\\ ; , newline`), 75-octet line folding that never splits a UTF-8 character, CRLF line ends, all-day `VALUE=DATE` events with stable UIDs; overdue items land on today, mileage-only reminders are skipped and reported
- `src/lib/report.ts` — service-history report model (service and mods logs, odometer history from every log with backwards-reading warnings, recall checklist filtered to the car's year and GT500 applicability, VIN full/last 6/omitted) and a standalone, escaped HTML document with inline CSS and no scripts
- `src/data/auctions.ts` — typed `auctionResults` (`AuctionResult`: date, venue, year, mileage, USD price or `null`, `localPrice` kept unconverted, outcome sold/offer/no-sale, CFTP/Heritage `null` when not stated, `outlier`, `conflicts`) and `marketStats` (published medians/estimates). `src/lib/market.ts` filters, medians and chart points; `src/components/ScatterChart.tsx` is an accessible SVG scatter with a "your car" marker
- `src/lib/achievements.ts` — milestones derived from local data (first track day, 10 drag passes, 1,000 / 10,000 miles logged, ten-second pass, …) with the date each was reached; `gt500.achievements.v1` only remembers which were already announced
- `src/lib/shortcuts.ts` — keyboard shortcut matcher (ignores inputs, textareas, selects, contenteditable and modifier chords); `src/components/Shortcuts.tsx` — the `?` help dialog
- `src/data/editions.ts` — typed `editions` (`ShelbyEdition`: years, model years, power claim, price/upfit price, production with `productionConflicts`, content, street-legal, `research` level) and `editionGaps` (searched, unsourced: Super Snake). `src/data/history.ts` — `events` (`HistoryEvent`: program/convention/auction) and `milestones` (`Milestone`, `placement: null` when unknown) plus `historyGaps`. `fpCatalog` in `src/data/parts.ts` — `FpCatalogItem` (M-number, MSRP + `priceAsOf`, `emissions` null when the catalog is silent, `fitmentYears`, `fitmentExplicit`; the 12 name-inferred items carry the "fitment inferred" caveat). `levelToConfidence` maps research high/medium/low to the badges.
- `src/lib/catalog.ts` — edition/FP filters and the merged, date-ordered history timeline; `src/lib/format.ts` — shared money formatting/parsing (replaces copies in Planner, Share, Timeline, Fuel, market, report, timeline); `src/lib/install.ts` — install-prompt state (`gt500.install.v1`, 90-day dismiss), iOS Safari and standalone detection
- `src/pages/` — screens; `public/` — manifest, icons, service worker

## Deploying to GitHub Pages

`.github/workflows/pages.yml` builds the app (typecheck, lint, tests, build) and deploys `dist/` to GitHub Pages. It runs **only when started by hand**: it has a single `workflow_dispatch` trigger and never runs on push or pull request. To use it:

1. In the repository, open **Settings → Pages** and set **Build and deployment → Source** to **GitHub Actions** (one time).
2. Open **Actions → Deploy to GitHub Pages → Run workflow**, pick the branch and run it.

The site appears at `https://<owner>.github.io/<repo>/`. No configuration change is needed: `base: './'` and `HashRouter` already work under that subpath.

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
- **GPS Lap Timer** (`/laptimer`, approximate): permission-gated, only starts on **Start GPS**. Set the start/finish line on-site with **Drop line here** (perpendicular to your direction of travel, counts only that direction) or from two typed points; add up to 5 sector lines. Live lap, current time, last/best lap and Δ to best (ghost, compared at equal distance). Laps are refused when any fix is worse than ±15 m or fixes are more than 3 s apart. **Stop & save** auto-saves the session to the Track log with `gps` provenance (lines, every lap with worst accuracy, refused laps flagged, a trace capped at 2,000 samples; only the 10 newest sessions keep traces). The 29 circuits/drag strips in `src/data/tracks.ts` are Wikipedia facility points (precision ~1 m–1 km): they only suggest the nearest track name and never become a timing line.
- **Track session analysis** (`/track`): GPS sessions show a speed-vs-distance chart per lap, overlay of up to 4 laps, min/max speed table and CSV/GPX export.
- **Weather auto-fill** (Drag DA calculator, timeslip and dyno forms; opt-in): fetches current temperature, humidity and station pressure from `https://api.open-meteo.com` (the only origin added to CSP `connect-src`), sending coordinates rounded to ~1 km only when you tap **Fetch weather**. Offline or on any error, manual entry is unchanged.
- **Search** (`/search`): typo-tolerant ranked results grouped by section (FL2087 = FL-2087 = "fl 2087", accents ignored), recent searches on this device, ↓/↑/Home/End/Esc keyboard navigation and Enter to open the top hit.
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
- Accessibility: the e2e suite runs axe-core (WCAG 2.1 A/AA) on every route in both themes and both languages and requires 0 serious/critical violations. Fixes from the audit: dark-theme button/active-link contrast (`--accent-btn`), video placeholder accessible names, focusable scrollable tables.
- **Parts & Fluids** (`/parts`): searchable (`?q=`, e.g. `fl2087`), copy-to-clipboard, confidence badges, related maintenance facts; Garage reminders link to their parts (e.g. oil → FL-2087).
- **How-to Guides** (`/guides`, `/guides/:id`): step-by-step pages with tickable checklists (kept for the session), per-step citations, warnings, tools and parts.
- **Language** (Settings): English or Español for the whole interface; `<html lang>` follows. Sourced facts stay in English.
- **Multi-car Garage**: add up to 12 cars, each with its own VIN, year, color, mods, service log, reminders and track, drag, dyno and fuel entries. Switch from the header (shown once you have two cars) or the Garage; deleting a car (never the last) also deletes its log entries after a confirmation that lists the counts. Timeline can show all cars; notifications and achievements cover every car; a shared car link can be added as a new car or merged into the current one.
- **Service History Report** (`/report`): a printable, owner-entered history for resale with a generated-on date and a prominent "owner-entered, not verified" disclaimer: service and mods logs, logged spend, odometer history, and a recall and campaign checklist for the car's year with a link to NHTSA's VIN lookup. **Print / save as PDF** uses the browser's print dialog (chrome hidden by print CSS); **Download HTML** saves a standalone file. The VIN can be shown in full, as the last 6 characters, or left out.
- **Calendar export** (Garage → Maintenance reminders): **Download calendar (.ics)** for the current car or all cars.
- **Market Value** (`/market`): sourced auction results charted as price vs sale date and price vs mileage, with year, CFTP and Heritage filters, opt-in outliers (celebrity provenance) and offers, an app-calculated median, and your car's odometer marked on the mileage chart. Published medians and estimates are listed with conflicts (DriveIndex vs ConceptCarz). Results without a USD price are listed but never charted. If the data slot is empty, the page shows an empty state.
- **Achievements** (`/achievements`): local milestones computed from your logs, with the date each was reached and a "new" badge once.
- **Keyboard shortcuts** (desktop): `/` search, `?` help, `g h` Home, `g s` Specs, `g g` Garage, `g t` Timeline, `g r` Report, `g m` Market, `g a` Achievements, `g p` Settings, `Esc` closes. Ignored while typing in a field.
- **Sources** has **Download CSV / JSON** of all sourced facts with source and confidence, for researchers.
- **Round-6 mods**: JLT Big Air intake ($399; +25–30 rwhp is a manufacturer claim with no dyno sheet, unverified) is now the one cost-per-hp example; VMP Stage 2 Pulley Pack ($1,399.99) and Predator EO Drag Pack ($2,339.99) have reported prices and no gain; the FordMuscle bolt-on build (674 → 828 rwhp, 561 → 666 lb-ft on E85) is one combined record with no per-part attribution. The VMP Odin kit is for the Coyote and F-150, not the GT500, and is not listed.
- **Shelby American Editions** (`/editions`): Signature Edition, GT500KR and Code Red with sourced price, upfit price, power claim, production (KR new-vs-upgrade split and SE cap shown as conflicts), street-legal status and research level; year/confidence/street-legal filters; searched-but-unsourced items (Super Snake) listed as gaps; empty state.
- **Events & History** (`/history`): vertical timeline of press milestones (NAIAS reveal, R&T PCOTY, MotorTrend BDC contender with unknown placement) and owner events (Track Attack, SAAC-46/47/48, KR charity auction); filter by kind; undated items last; empty state.
- **Parts → Ford Performance** tab (`/parts?tab=fp`, arrow-key tabs): 18 M-numbers with current MSRP (as of 2026-10-16), emissions status (unknown for all), fitment years and a listed / fitment-inferred tag; search, year, category and listed-only filters; empty state.
- **Help & Guide** (`/help`, en/es): what each tool does, the confidence badges, data privacy (all local, nothing uploaded) and how backups work.
- **Install**: a custom banner on `beforeinstallprompt` ("Install" / "Not now", dismissal remembered 90 days), an "Add to Home Screen" hint on iOS Safari, hidden when installed or in the native app. The manifest has shortcuts (Garage, Session Timer, VIN Decoder) and separate full-bleed maskable icons.
- Home shows a Garage summary and the next maintenance due. All tools appear in the menu and in Search.
- Every route except Home is lazy-loaded. After the service worker registers, the app fetches each route chunk once so it is cached for offline use.
- The build stamps `dist/sw.js` with a per-build cache name and the list of emitted assets; old caches are deleted on activate. Only `ok`, same-origin, non-redirected responses are cached. A new version waits until you tap **Reload** in the "Update ready" banner (the page posts `SKIP_WAITING`, then reloads on `controllerchange`). An "Offline" banner shows when the connection drops, and a warning appears if the browser refuses to save data.
- `index.html` sets a Content-Security-Policy (self, Wikimedia images, youtube-nocookie and freesound frames; no `'unsafe-inline'` for scripts or styles, `script-src-attr 'none'`, `object-src 'none'`, `form-action 'none'`). YouTube embeds are sandboxed and ids are validated.
- Ownership groups Mustang NHTSA recalls by GT500 applicability (applies / likely / depends on VIN / not applicable) from round-4 review of the recall documents, with build windows. Fluids added from a 2021 GT500 supplement are marked `reported`; its service-interval table is `unverified` because the PDF columns were misaligned.

Garage cars (`gt500.cars.v1`), plans (`gt500.plans.v1`), track sessions (`gt500.track.v1`, incl. GPS lap-timer traces), weather-fill preference (`gt500.weather.v1`), recent searches (`gt500.recentSearches.v1`), timeslips (incl. GPS estimates), fill-ups, settings, intro state and quiz score are kept only in the browser's `localStorage`. Videos are embedded from youtube-nocookie.com and load only on tap; no copyrighted images are re-hosted, and the car art is generic CSS/SVG.

## Security

Round-9 review of the whole repo (fixes have regression tests in `tests/round9.test.tsx` and `e2e/round9.spec.ts`):
- The downloaded service report already escaped every value; it now also carries its own CSP (`default-src 'none'`, no scripts) and `no-referrer`, so a future escaping bug could not run code or load anything.
- CSP: removed `style-src 'unsafe-inline'` (React sets styles through the CSSOM, which CSP allows) and added `script-src-attr 'none'`; an e2e test fails on any CSP violation.
- `.ics`: control characters are stripped from TEXT values (newlines were already escaped, so no property injection).
- CSV: the formula guard also catches a formula after leading whitespace or a newline.
- Imported notification state skips `__proto__`/`constructor` keys and caps lengths; notification titles are capped plain text. The service worker opens only its own `#/garage` on notification click.
- Capacitor: explicit https scheme, no cleartext, no remote navigation, no WebView debugging.
- Every source URL in the data (including nested citations) must be `https://`, so no `javascript:` link can reach the page.
- No issue found in share links (strict allow-list decode, no VIN), i18n interpolation and SVG text (React-escaped), or import validation (allow-list normalizers, 2 MB cap). `npm audit`: 0 vulnerabilities.

## Third-party data

`src/data/startFinishLines.ts` (sourced lap-timer start/finish lines) is derived from OpenStreetMap:
data © OpenStreetMap contributors, available under the Open Database License (ODbL) 1.0
(https://www.openstreetmap.org/copyright), snapshot 2026-06-01. Gate endpoints are computed from OSM nodes and are
`unverified`; the app credits "© OpenStreetMap contributors" in the lap timer, on Sources and in Help. Only that file is
ODbL; the rest of the project's code and data is not affected. See [LICENSE-DATA-OSM.md](LICENSE-DATA-OSM.md).

## Disclaimer

This is an independent fan project. It is not affiliated with, endorsed by or sponsored by Ford Motor Company, Shelby American, Inc. or Carroll Shelby Licensing. "Ford", "Mustang", "Shelby", "GT500" and "Cobra" are trademarks of their respective owners and are used here only to identify the vehicle. No logos are used. Figures are compiled from third-party sources and may be wrong; verify with official Ford documents, NHTSA and your dealer. Nothing here is legal or mechanical advice.

## Data quality tooling (round 10)

- **Data Coverage** (`#/coverage`, in the menu): computed live from `src/data` — confidence counts per section, every null (gap) field with the note saying what is needed and a link to where it shows in the app, open research questions, every conflict with all sourced values, and a source-domain breakdown.
- **`npm run validate:data`**: checks every record against the JSON Schemas in `schemas/` (generated from `src/lib/dataSchema.ts`; a unit test keeps them in sync — regenerate with `npm run validate:data -- --write-schemas`), plus https sources, the confidence enum, null-needs-note, research-level ↔ badge, unique ids / no duplicate records and conflict structure. Runs in the CI build job. See `CONTRIBUTING.md` and the *Data correction* issue template.
- **`npm run check:links`**: HEAD/GET every unique source URL (timeouts, retries, honors `HTTPS_PROXY`) and writes `link-report/links.{md,json}` (ok / redirect / 4xx / 5xx / blocked / error). The `Source link check` workflow runs it only on `workflow_dispatch` and weekly, uploads the report as an artifact, and never fails or commits.
- **Charts**: every SVG chart is a labelled group with keyboard-focusable points (roving tabindex; arrows/Home/End), an on-focus/hover tooltip, a live readout, and a visually hidden data table with a Show/Hide toggle. `prefers-reduced-motion` disables transitions and animations.
- **Visual regression**: `e2e/visual.spec.ts` screenshots 10 pages in both themes at phone size against baselines in `e2e/__screenshots__/` (max 3% pixel diff, fixed clock, animations off). It runs with the rest of `npm run e2e` in CI. After an intended UI change: `npm run build && npm run e2e:update-visual`, review the PNGs, commit them. Font rendering differs between machines, so the committed baselines must come from the CI runner: run the manual **Update visual baselines** workflow (Actions tab → `visual-baselines.yml` → Run workflow on your branch); it regenerates the PNGs on the CI image and commits them back. Until that workflow is on the default branch, add an `e2e/.update-baselines` file in a push instead; the workflow removes it in its commit.
- **Component gallery** (`#/dev/gallery`, `npm run dev` only): badges, citations, conflicts, stats, inputs, buttons and all three charts in both themes. Excluded from production builds (`import.meta.env.DEV`). The dev server relaxes the CSP for Vite's injected styles; production keeps the strict CSP.

## Round 11

- Backup schema **v7**: track sessions may carry `gps` (timing lines, laps, capped trace); v6 files migrate unchanged; import cap 4 MB; every GPS field is range-checked on import.
- Data: `tracks` collection (29 facilities from research round 9, schema in `schemas/tracks.schema.json`, `startFinish` null until a sourced line exists); competitor base MSRPs as a separately sourced `msrp` (model year, destination flag, conflicts); Track Attack end and MotorTrend BDC 2020 winner.
- Archived sources (`originalUrl`): links show the original site with "(archived)", the Sources page lists the original URL, Coverage credits the publisher rather than web.archive.org, and the facts CSV/JSON gain an `originalUrl` column.

## Round 12

- **Track map** (`/track`, GPS sessions): the stored trace drawn as inline SVG with an equirectangular projection auto-fitted to the box (no map tiles, nothing downloaded), coloured by speed with a colour-blind-safe viridis palette (legend with ranges in your units, neutral underlay so slow sections stay visible in both themes), start/finish and sector lines, a lap selector, tap the map or use the slider (keyboard) to read speed, time into the lap and distance, a data-table alternative, and a sector-times table with the best sector per column and the theoretical best (sum of best sectors, valid laps only). `src/lib/trackMap.ts`, `src/components/TrackMap.tsx`.
- **Photos** on Garage service/mod entries and Track sessions: resized client-side to ≤ 1600 px JPEG (quality, then size stepped down to ≤ 1.5 MB; EXIF orientation applied, metadata dropped) with a 240 px thumbnail, stored in IndexedDB (`gt500-photos`). Quotas: 6 per entry, 200 per device, 45 MB total, 30 MB input file; every failure (not an image, can't decode, too big, quota, private-mode storage off) shows a translated message. Lightbox is a modal `<dialog>` (Esc, ←/→, delete). Deleting an entry, a car or all data deletes its photos. `src/lib/photos.ts`, `src/components/Photos.tsx`.
- **Backup schema v8**: `ptc` (your checklist items), track sessions may carry `checklist`, and an optional `photos` list (base64 JPEG, strictly validated: JPEG magic, id/owner allow-list, dimensions, per-photo and total size, per-entry count). "Include photos" is off by default; such a file may be up to 64 MB (plain backups stay capped at 4 MB, and a large file without photos is refused before parsing). Importing a file with photos replaces this device's photos; a file without them keeps them. v7 files migrate with no checklist items.
- **Pre-track checklist** (Track Day Log form): items built from sourced records (2021 supplement track-use schedule: DOT 4 LV brake fluid before the event, oil/filter after ≈ 4 h, rear axle fluid every 500 track miles; the unverified 1,000 mi break-in note), each with the record's badge and source. Tire pressures are not sourced (the `tire-pressures` guide is still `planned`), so that item asks for your own cold target in the pressures fields. Your own items are a template on this device (`gt500.ptc.v1`); each saved session keeps its own ticked copy.
- **Car-colour accent** (Settings → Accent colour, off by default): the active car's paint swatch with only its lightness moved until accent text is ≥ 4.5:1 on every background of the current theme and white button text is ≥ 4.5:1; near-grey paints and unknown colours fall back to the default red. Applied through the CSSOM (CSP-safe). `src/lib/accent.ts`.
- **Data**: `startFinishLines` collection (`src/data/startFinishLines.ts`, `schemas/startFinishLines.schema.json`, empty for now) linked to `tracks` by `trackId`; `validate:data` also checks the track id exists, one line per track + configuration, 3–200 m line length and ≤ 5 km from the facility point; it shows on Data Coverage. The lap timer has a "Known track" picker and offers **Use sourced line** only when a line exists for that track/configuration, with its source and confidence, plus "© OpenStreetMap contributors" when the source is OSM.
- **Bug fixes** (regression tests in `tests/round12.test.tsx`): `fmtLap` printed 59.9996 s as `0:60.000` (now rounds first → `1:00.000`); search results for editions, events, milestones, Ford Performance parts and dyno baselines linked to Home (search now uses the Coverage route map; guides open their own page); imported GPS laps could end before they started and traces could have negative times; GPS lap accuracy ignored the metric setting in the lap timer and session table; stopping the lap timer without a line silently discarded the session (now says so).
- Lighthouse (mobile, local preview): `/` 98/100/100/100, `/specs` 99, `/parts` 98, `/guides/track-service` 98, `/sources` 96, `/coverage` 96, `/track` 98, `/garage` 97, `/settings` 98, `/laptimer` 98 (accessibility, best practices and SEO 100 on all).

## Round 13

- **OBD-II gauges** (`/obd`): connects to a Bluetooth Low Energy ELM327-style adapter through Web Bluetooth, and only when you tap **Connect adapter** (the browser asks permission first). The page feature-detects Web Bluetooth and explains when it is missing: iPhone/iPad browsers and Firefox don't support it, and it needs https. Init `ATZ ATE0 ATL0 ATS0 ATH0 ATSP0`, then the supported-PID bitmaps `01 00/20/40/60` (it follows the "next range" bit). GT500 support for every PID is unverified, so only supported gauges show: rpm (0C), speed (0D), coolant (05), intake air (0F), throttle (11), boost = MAP (0B) − barometric (33), and oil temperature (5C), which is probably unsupported on the 5.2L (an HP Tuners forum note, shown as unverified). MAP tops out at 255 kPa. Ford Mode 22 PIDs are not supported. Parsing is pure and unit-tested (`src/lib/obd.ts`), and the BLE UART transport is in `src/lib/obdBle.ts`. Gauges are SVG arcs with a text value and a `<meter>`, in your units, with no motion under reduced motion. **Read-only by construction:** every command passes `assertReadOnly`, an allow-list of adapter AT commands plus Mode 01/03/07, so Mode 04 (clear codes) and all write/control modes throw before they reach the adapter. A fake transport drives the tests. **Demo mode** uses simulated data, labelled "Demo — simulated" on the gauges, in the CSV and in the file name, and can't be attached to logs. Session logging has CSV export (metric values, numbers only), and **Attach summary** adds a one-line summary to a Track or Drag entry's notes. A safety note tells the driver not to use it while driving: it is for passengers.
- **Trouble codes** (on `/obd`): Mode 03 stored and Mode 07 pending codes, decoded to P/C/B/U with generic vs manufacturer-specific. It handles legacy, CAN single-frame and CAN multi-frame replies. Descriptions are not included: each code says "Description not included" and links to a generic third-party lookup. There is no clear button.
- **Drag tree trainer** (`/tree`): sportsman .5 full tree and pro .4 tree. Reaction time is measured from green using the event timestamp. A tap before green is a red light, and no tap within 2 s times out. Shows best, average, runs and red lights, plus a 100-run history (`gt500.tree.v1`). Works with Space or Enter. With reduced motion there is no glow and lamps switch instantly. `src/lib/tree.ts`.
- **Ask the data** (`/ask`): an offline keyword/intent matcher (English and Spanish keywords) over the sourced records only: oil, 0–60, quarter mile, paint code for a named colour, recalls that apply to the GT500, horsepower, torque, top speed, tires, weight, MSRP by year, fuel. Every answer shows its source and confidence and links to its page. Anything else answers "Not in the data". No network, no LLM. `src/lib/ask.ts`.
- **Track day planner** (`/trackdays`): events with a date (and an optional last day), a track from the tracks list or a custom name, organizer, run group and notes. Generic packing-list templates (road course/HPDE, drag, autocross) that you tick off, links to the pre-track checklist (Track log) and the lap timer, and `.ics` export of upcoming events (all-day, exclusive DTEND, RFC 5545 escaping and folding). **Backup schema v9** adds `trackdays`; v8 files migrate with none.
- **Competitor prices by model year** (Compare, from round 11 research), each with its own source and confidence: 2020 ZL1 coupe $63,000 / convertible $69,000 (excl. destination); 2022 ZL1 6MT $64,395 incl. destination; 2020 Hellcat $58,995; 2020 Redeye $70,595; 2020 Redeye Widebody $76,595 (unverified); 2021 Redeye Widebody $81,060; Jailbreak is a $995 option on the 2022 Redeye Widebody (there was no 2021 Jailbreak); the ZL1 1LE $7,500 package is listed as 2018-only and is not applied to 2020–22.
- **Preview manifest**: `npm run build` also writes `dist/.preview-manifest.json`, which lists every emitted file with its size and SHA-256 for tooling. The app and service worker never read it.
- **Bug fixes** (regression tests in `tests/round13.test.tsx` and `e2e/round13.spec.ts`):
  - Restoring a backup with photos wiped this device's photos before decoding the new ones. A bad photo then left you with none. Records are now built first.
  - Restored photos could push storage past the 45 MB quota once thumbnails were added. Restore now enforces the quotas, thumbnails included.
  - Two checklist items added in the same millisecond shared an id, so they ticked and removed together.
  - Switching the lap timer's known track kept the previous track's sourced (OSM) line and its credit.
  - There is also a regression test that every directional OSM line counts travel along its way bearing and refuses the reverse.
- Lighthouse (mobile, local preview): `/` 100, `/specs` 99, `/obd` 99, `/tree` 99, `/ask` 98, `/trackdays` 99, `/compare` 98, `/settings` 99 (accessibility, best practices and SEO 100 on all).

## Round 14

- **Direction-sign audit** (OSM start/finish lines): every sign was re-derived from scratch. Each gate's stored `a`/`b` matches the documented derivation (OSM node ± 10 m, great-circle, perpendicular to the way bearing) within 0.1 m. `a` is always on the left of travel along the way. The timer counts a crossing from the right of `a→b` to the left as +1. So "+1 = travel along the way bearing" is correct for all 8 directional lines. The non-directional Chuckwalla line counts both ways. **No sign was wrong, and no data changed.** `tests/round14.test.tsx` has a table-driven test for every line. It drives a car round a 300 m loop through the gate along the documented bearing (smoothing on, default 20 s debounce) and checks that 2 valid laps register, and that the reverse lap registers none.
- **Flip / Either direction** (lap timer): with a sourced line in use, a one-tap control chooses **As published**, **Flip direction** or **Either direction**. The choice is remembered per line record on this device (`gt500.sflDir.v1`; device-local, not in backups, so backups stay schema v9). Flip is disabled for a line with no published direction.
- **Spanish for data**: `src/data/es.ts` is a typed `es` overlay keyed by record id. It translates spec labels and notes, never values, units, names, quotes or sources. Missing fields fall back to English. Translated text carries a visible "traducido" tag. A test checks that every overlay key exists in the data, and the English records are untouched. (Section headings were already translated.)
- **Native build pipeline**: a manual-only workflow builds an unsigned Android debug APK and checks the iOS sync (see "Native apps").
- **Diagnostics** (Settings → Advanced → Diagnostics, `/diagnostics`): an opt-in, local-only field-test log for real-world testing on a phone or at a track. It is off by default. It records GPS fix accuracy, fix interval and speed, lap crossings (lap time, valid, worst accuracy, direction setting) and OBD command timings (command, status, byte count, round trip). No coordinates, VIN, device names or clock times are kept: entries are timed from when recording started. It keeps the newest 3,000 entries, shows a summary (median/95th-percentile accuracy, fix gaps, OBD errors and latency) and exports JSON. Nothing leaves the device unless you export it. `src/lib/diag.ts`.
- **Bug fixes from a round 13 audit** (regression tests in `tests/round14.test.tsx`):
  - OBD: an ISO 9141/KWP adapter's `BUS INIT: ...OK` line was treated as a bus error, so every reply on those protocols failed.
  - BLE: a setup failure after the GATT connection opened (e.g. notifications refused) left the adapter connected. A drop mid-command waited for the 2.5 s timeout instead of failing at once.
  - OBD page: a failed init or support read left the transport open, and starting again did not close the earlier connection.
  - Tree trainer: a red light within 0.5 ms of green rounded to −0, which JSON saves as 0, so after a reload it showed as a "perfect light". It is now stored as −0.001.
  - Ask: "1/4 mile" never matched, because normalization strips the slash. "0 to 60" is now recognized too.
  - Track day planner and backup v9: repeated event ids are refused on import (they were edited and deleted together) and de-duplicated on load. Repeated packing-item ids keep the first.
- Lighthouse (mobile, local preview): `/` 99, `/specs` 99, `/laptimer` 98, `/diagnostics` 98, `/settings` 99, `/obd` 98 (accessibility, best practices and SEO 100 on all).

## Round 15

- **Buyer's guide** (`/buy`, in the menu and search) for shopping for a used 2020–2022 GT500. **VIN quick-check** reuses the VIN decoder (`src/lib/vin.ts`) to show the model year and the recalls and campaigns to ask about for that year (the same filter as the service-history report), with links to NHTSA's VIN recall lookup. **Price sanity check**: enter an asking price, model year and optional mileage. It counts how many sourced completed sales for that year (outliers excluded) were lower or higher, shows the sourced range and median, the five sales closest in mileage, and the published market figures, each with its source and confidence. There is no valuation model. **Pre-purchase checklist** built only from existing sourced records (`src/lib/buyerGuide.ts`): recalls/campaigns that may apply, TSBs and owner/vendor reports, service and warranty records, packages and Shelby American editions to verify, and paint codes. Every item shows its confidence badge and source. No new data was added. Ticks are stored in `gt500.buyer.v1` (`src/lib/buyer.ts`). **Backup schema v10** adds `buyer` (`{ checked: [...] }`); v9 files migrate with nothing ticked.

## Round 16

- **Build & sticker** (`/build-sheet`, in the menu and search): pick a model year and the packages offered that year to see an original window-sticker total (base MSRP, destination, gas guzzler tax, options), built only from sourced prices in `src/data/pricing.ts` and `src/data/packages.ts` (`src/lib/buildSheet.ts`). Every line shows its confidence badge and source. Lines without a sourced price for that year are listed but excluded, and the total then reads "at least $X" with a count of unpriced lines. Where sources disagree, the primary value is used and the other sourced values are shown beside it. A price whose context names a model year is applied only to that year. The last build is stored in `gt500.buildSheet.v1` (not part of backups; backup schema stays v10).
- Round 14 research data: GT500KR production (225 total, 180 US), Track Attack dates, 2025–2026 auction results, drag passes, the SVTPerformance GT500 forum and TR-9070 clutch friction areas.

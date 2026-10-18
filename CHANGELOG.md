# Changelog

All notable changes to GT500 Companion, newest first. Research notes for each round live in
`research_notes/Shelby GT500 2020 to 2022/`.

## Round 19 — review fixes for rounds 15–18
- **Cost inputs of deleted cars:** deleting a Garage car now also removes its Cost of ownership inputs (`purgeCarLogs`). Before, they stayed in `gt500.cost.v1`; after enough add/delete cycles the store passed its 12-car cap and a new car's inputs were silently dropped on save and lost on reload.
- **Cost table accessibility:** the per-year total's live region moved inside its table cell (`<td><div role="status">`), so the cell keeps its table semantics.

## Round 18 — round 16 data: tires, DCT fluid, pads, noise limits
- Research round 16 data and where it shows. **OEM tire fitment** (Michelin fitment pages, reported): front 305/30ZR20 XL 103Y, rear 315/30ZR20 XL 104Y, the same with the Carbon Fiber Track Package; new spec records `tire-f-oem` / `tire-r-oem`, listed on the Tire & Wheel Calc page. The Cup 2 load index is not stated as confirmed. The Cup 2 305 price from a Canadian seller was not added: the currency is unclear and part prices are USD, and nothing is ever converted.
- **DCT fluid:** Motorcraft XT-14-L (1 qt bottles, cases of 12) gets the IBSPOT $117.59 price (unverified, seen 2026-10-17). `PartPrice.per` gains `'listing'` (a seller listing whose pack size is unclear): it is shown on the Parts page with a "pack size unclear" caveat and the Cost page never prices a DCT service from it (no per-quart figure is computed). The DCT capacity is still not sourced by Ford or Motorcraft.
- **Aftermarket front pads:** Hawk HPS 5.0 HB928B.644 ($251.90–$294.29, MSRP $310.99), DTC-60 HB928G.644 (about $512–$717) and DTC-70 HB928U.644 ($544.99), all unverified, in `partNumbers` under the new category "Brake pad (aftermarket)" and labelled "Aftermarket, not a Ford OEM part" on the Parts page (other prices in the range kept as conflicts). The Parts page now shows any sourced part price with its date seen. Ford OEM pad and rotor numbers stay an empty slot.
- **Track noise limits:** optional `noiseLimit` on tracks (types, schema, regenerated JSON Schemas). WeatherTech Raceway Laguna Seca: 92 dB typical (reported), with 90 dB and rare 103 dB event days as conflicts. Shown in the Track Day Planner (when a track is picked, and on each event) and the lap timer; tracks without a sourced limit say so. The pre-track checklist gains "Checked the track's noise limit for this event."
- **Oil capacity:** the 11.5 qt "2020 supplement per secondary sources" claim is added as an unverified conflict; the value stays the 10–11.5 qt range, so the oil change stays unpriced. The 2022 MustangSpecs performance figures were not added (they match the Car and Driver numbers, so likely misattributed).

## Round 17 — cost of ownership
- Cost of ownership page (`/cost`, in the menu, search and Help): for the active Garage car, an estimated cost per year, over the ownership period and per mile. Scheduled services come from the sourced 2021 supplement intervals (whichever of miles or months comes first); no part price for a scheduled service is sourced, so each shows "price not sourced" until the owner types their own cost, and the total then reads "at least" with a count of unpriced items. Fuel uses the car's logged mpg, else the sourced EPA combined 14 mpg; fuel price, insurance, tires, annual miles, years and purchase price are owner inputs with no defaults. Every value is labelled "Your number" or "Sourced". A separate section totals what the car's own fuel, service and mods logs record (track sessions are counted; they have no cost field). The value check lists the purchase price next to sourced market medians and the median of sourced auction sales for the model year, labelled as data points, not a forecast (no depreciation curve). Breakdown table, accessible SVG bar chart with a data-table alternative, print-friendly.
- Inputs are stored per car in `gt500.cost.v1`; **backup schema v11** adds `cost` (`{ cars: { [carId]: inputs } }`), v10 files migrate with no inputs.
- Round 15 research data: Ford TSB 24-2327 (2024-10-22, 2020–2022 GT500 DCT fluid leak at the rear cooler tube / case junction, part KR3Z-7R081-C; confirmed, NHTSA PDF), linked to the "DCT cooler lines" vendor claim it corroborates. Sourced part prices with the date seen on `partNumbers[].price` (new optional field; schema regenerated): Motorcraft XO-5W50-QGT $14.94/qt (RockAuto, reported, conflicting snapshots kept) and FL2087A $22.79 (unverified). `cost.ts` now builds `SOURCED_SERVICE_PRICES` from that data: a service is priced only when every part and quantity is sourced, so the oil change stays unpriced (oil capacity is a 10–11.5 qt conflicting range) and the Cost page shows the per-quart and filter prices as references. The PS4S 315 tire price was not added (no per-tire slot; the 305 front has no price). Insurance reference data points (MotorTrend/Insure.com about $2,488/yr with its driver profile; Autoblog model about $1,800 in year 1; both unverified) appear next to the insurance input, never as a default. Hagerty 2020 Hot List milestone; Mecum Dallas Sept 2022 sale $118,250 (unverified; the 2020 auction median moves to $95,000).

## Round 16 — build & sticker
- Build & sticker page (`/build-sheet`): pick a model year and the packages listed for it, see the original MSRP as a window sticker where every line shows its sourced price, confidence and source. Unsourced prices (e.g. 2021 gas guzzler tax, extra-cost paint, a 2020-only Handling Package price in other years) are flagged and excluded, and the total reads "at least" with a count of unpriced lines. Conflicting sourced values are listed beside the primary value; options with unknown year availability are marked "availability unverified". Print-friendly, links to Market and the buyer's price check; last build saved on the device (cleared by reset, not in backups — backup schema stays v10).
- Round 14 research data: GT500KR production 225 (180 US, 60 per model year, + 45 overseas; Shelby American) with Autoblog and Fordmuscle split conflicts; Track Attack ran 2020 to November 2023 (Ford Authority via search summary only); Edsel Ford II BaT sale dated 2025-09-16; Mecum Indy 2026 GT500KR sales ($187,000 and $154,000, unverified, outliers); GBP conversions and a $114,000 vs £88,817 conflict on three 2026 BaT sales already listed by DriveIndex; 9.91 @ 137.60 and 9.15 @ 155 mph drag records (unverified); SVTPerformance GT500 subforum (confirmed); TR-9070 clutch friction areas.

## Round 15 — buyer's guide, round 13 data, native fix
- Buyer's guide page (`/buy`): per-year sourced checklist (recalls, known issues), VIN and price checks; backup schema v10.
- Round 13 research data: 2021 destination charge ($1,195, Ford Authority via search summary only); 2020 Handling Package $1,500 with contents; Carbon Fiber Handling Package contents; 2021 Technology Package listings; 2020 Recaro seats $1,595; Heritage stripe prices corroborated; CFTP $18,900 leaked-guide price conflict; curb weight conflicts (4,225 lb leaked eSourceBook, 4,080 lb Motor1 scale).
- Recall 25V455: GT500 applicability now "unknown" (new value) with the conflicting NHTSA / TFL / by-vehicle scope notes and the NHTSA owner-letter date as written.
- Native workflow: Android build fixed by no longer requesting the retired SDK `tools` package.

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

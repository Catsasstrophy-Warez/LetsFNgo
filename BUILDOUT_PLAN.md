# DayTradeScanner — Build-Out Status

Swift 6 language mode throughout, targeting the latest available SDKs today
(iOS 18+ via `project.yml`/`Package.swift`). Bump the deployment target to
iOS 27 / build with Xcode 27 the day both actually exist — Swift 6 strict
concurrency is already the baseline, so no source changes are expected.

## Complete

Every file below is ported/written and committed.

```
Package.swift / project.yml    SwiftPM + XcodeGen, RealityKit/Metal/MetalKit linked
Sources/DayTradeScanner/
  App/            DayTradeScannerApp.swift
  Core/           MarketClock, Models, PositionSizer, ScanProfile, ScanRecipe,
                  Settings, SwingModels, LongTermModels, TradeHorizon
  Data/           AlpacaStream, AlpacaREST (+ options chain/snapshot endpoints),
                  EDGARFilingStream, FINRAShortVolume, HaltMonitor,
                  StockTwitsClient, SECFloatClient
  Engine/         AlertBudget, BaselineStore, LongTermEngine, LongTermScoringModel,
                  MicroStructure, ScannerEngine, ScoringModel, SwingEngine,
                  SwingScoringModel, SymbolState, UniverseBuilder, VolatilityProfile
  Journal/        PaperTradeLog
  Options/        OptionsModels, GreeksEngine, OptionsEngine,
                  UnusualActivityDetector, StrategyBuilder
  Rendering/      CandleChartRenderer.swift + ChartShaders.metal,
                  MarketPulse3DView.swift (RealityKit)
  UI/             DiscoveryView, HaltsView, LongTermView, OptionsView,
                  PaperLogView, PositionSizerView, RootView, ScanView,
                  SettingsView, Style, SwingView, SymbolDetailView, TuningView
```

### What each new system does

**Options (`Options/`, `UI/OptionsView.swift`)** — a fourth engine alongside
day-trade/swing/long-term, same `@MainActor @Observable` shape as the others.
`OptionsEngine` fetches chains for a small hand-picked underlying list via
Alpaca's options contracts + snapshot endpoints (added to `AlpacaREST`),
recomputes Black-Scholes greeks/IV locally (`GreeksEngine`) whenever the
server snapshot omits them, and runs `UnusualActivityDetector` — a
self-computed volume-vs-open-interest / volume-vs-own-history / notional-size
heuristic, explicitly kept as labeled context rather than a hidden score
override, per the house rule already established for social/flow signals
elsewhere in the app. `StrategyBuilder` constructs the standard named
multi-leg strategies (verticals, straddles/strangles, iron condor,
covered call/CSP as single-leg option views) with payoff-at-expiration,
breakevens, max profit/loss, net greeks, and a delta-approximated probability
of profit. `OptionsView` browses chains, lets you tap contracts onto a leg
selection, and opens a payoff-diagram sheet.

**Metal charts (`Rendering/CandleChartRenderer.swift` +
`ChartShaders.metal`)** — an `MTKView`-backed `CandleChartView`
(`UIViewRepresentable`) that turns a bar window into one triangle-list vertex
buffer (candle bodies, wicks, a VWAP ribbon, and a volume histogram) per
rebuild, with `UIPinchGestureRecognizer`/`UIPanGestureRecognizer` driving a
visible-index window instead of SwiftUI gesture state, since the geometry
rebuild has to happen on the same coordinator that owns the Metal buffers.
Wired into `SymbolDetailView` in place of the old `VWAPSparkline` (kept as a
lightweight fallback for the first couple of bars, and still used standalone
elsewhere it fits).

**RealityKit (`Rendering/MarketPulse3DView.swift`)** — deliberately scoped
down from "core chart renderer" (2D price data gains nothing from a 3D scene
graph) to an optional, explicit "3D market pulse" view: the current ranked
list as a field of RealityKit boxes, height = score, color = direction,
opened from a toolbar button on the day-trade scan screen. Uses the iOS 18+
windowed (non-AR) `RealityView` API — no camera, no ARSession.

### Bugs fixed during the port (see prior session review)

- `CandidateRow`'s "updated Xm ago" label was a bare string literal instead
  of an interpolated one.
- `TuningView` defined swing/long-term weight and evidence sections that were
  never reachable from `body`; added a horizon picker at the top of Tuning.

## Complete (round 2)

- **Options paper trading** — `Journal/OptionsPaperTradeLog.swift`: a
  SwiftData `OptionsPaperTrade` model that freezes every leg (`OptionLegRecord`)
  at entry, independent of `PaperTrade`'s single-price/single-direction shape.
  Cost basis (`netPremiumAtOpen`) and live mark (`currentValue`) share one
  sign convention (positive = net debit), so P&L is `currentValue -
  netPremiumAtOpen` regardless of leg count or side. `OptionsEngine.refresh()`
  and `loadMoreExpirations(for:)` both call `markOpenPaperTrades()` after
  building chain data. Wired into `StrategyPayoffView`'s "Log as paper trade"
  button and a new "Open positions" section on the Options tab, with a
  per-row Close action.
- **Chain pagination** — `OptionsEngine` now tracks a per-underlying
  expiration window (`expirationWindow`, starts at 3, caps at 12) instead of
  a single hardcoded count, and exposes `hasMoreExpirations(for:)` /
  `loadMoreExpirations(for:)`. `OptionChainDetailView` gained a "Load more
  expirations" button that widens just that underlying's chain without
  re-fetching the whole universe.
- **Unit tests** — `Tests/DayTradeScannerTests/`, registered as a
  `testTarget` in `Package.swift` and matching the existing
  `DayTradeScannerTests` target in `project.yml`:
  - `GreeksEngineTests.swift`: Black-Scholes price/delta benchmarked against
    the standard Hull textbook example (S=100,K=100,T=1,r=5%,σ=20% →
    call≈10.45, put≈5.57), put-call parity, gamma/vega symmetry between a
    call and put at the same strike, theta sign, zero-time-to-expiry
    collapsing to intrinsic value, degenerate-input nil handling, and an
    implied-volatility round trip (price at a known σ → solve → recover σ)
    for both a call and a put.
  - `StrategyBuilderTests.swift`: payoff/breakeven arithmetic for a long
    call, long put, bull call spread, bear put spread, long straddle, and
    iron condor against hand-computed expected values (e.g. a $10-wide
    $4-debit vertical → max profit $600, max loss $400, breakeven 104);
    unbounded vs. capped max-profit/max-loss detection; net-greeks summation
    across legs with sign.
  - `UnusualActivityDetectorTests.swift`: no-signal cases (no volume,
    ordinary volume/OI), scoring monotonicity with ratio, the own-history
    surge factor (including the "fewer than 3 samples" guard), notional-size
    and short-dated-expiry contributions, score clamping, and `scan()`'s
    descending sort both within and across chains.

## Complete (round 3 — competitive-adaptation backlog, steps 6–20)

Everything below was added after `COMPETITIVE_ADAPTATION_BACKLOG.md`'s
research pass, in priority order, each committed and pushed separately:

- **Custom recipe builder** (`Core/CustomRecipeStore.swift`,
  `UI/RecipeBuilderView.swift`) — user-built `ScanRecipe`s via filter chips,
  persisted in UserDefaults alongside the 17 built-ins.
- **Recipe JSON import/export** — Share-sheet export and `fileImporter`
  import, folded into the same recipe-builder work since `ScanRecipe` was
  already `Codable`.
- **Chart annotation strip** (`UI/ChartAnnotationStrip.swift`) — gap-open,
  VWAP-cross, news, and "now" markers under the symbol-detail chart, keyed
  to bar index rather than pixel position so it stays correct regardless of
  the Metal chart's own pan/zoom state.
- **Options flow filter/sort bar with saved presets**
  (`Core/UnusualActivityFilter.swift`) — side/sort/threshold filtering over
  `OptionsEngine.unusualActivity`, presets persisted the same way as
  custom recipes.
- **0–100 unusual-activity score display** — cosmetic rescale to match the
  "Activity Score" framing competitor tools use.
- **Audio squawk box** (`Engine/AudioSquawk.swift`) — `AVSpeechSynthesizer`
  readout of halts, filings, top setups, and strategy-bot alerts, each with
  its own Settings toggle, off by default.
- **StockTwits watch-count in social scoring** — `ExtendedSignals.socialWatchCount`
  wired into `ScoringModel.normalizeSocialMomentum`, rebalanced weights.
- **Market-regime banner + sector breadth** (`Engine/MarketRegimeEngine.swift`,
  `UI/MarketRegimeView.swift`) — SPY + 11 SPDR sector ETFs on the same free
  daily-bars endpoint, a persistent strip above the horizon picker, and a
  tap-through sector-tile grid.
- **IV Rank/Percentile** (`Journal/IVHistoryStore.swift`) — new SwiftData
  model recording one front-month ATM IV point per underlying per day,
  since no free source publishes historical IV; rank/percentile computed
  over a trailing 365-day window once enough history accumulates.
- **Snowflake radar chart** (`UI/SnowflakeChartView.swift`) — the eight
  `LongTermComponent` axes as a plain-`Path` radar chart on the long-term
  detail screen.
- **Portfolio tab** (`UI/PortfolioView.swift`) — unified rollup of every
  open equity (any horizon) and options paper position.
- **Backtest mode** (`Engine/BacktestEngine.swift`) — walks swing-watchlist
  daily-bar history day by day through the live, pure `SwingEngine.buildSnapshot`
  + `SwingScoringModel`, no lookahead, reporting win rate and edge over
  baseline for a configurable score threshold and holding period. Scoped to
  the swing horizon only — day-trade backtesting needs minute-bar depth the
  free IEX tier doesn't carry far enough back.
- **Strategy Bot** (`Engine/StrategyBotEngine.swift`) — mechanical lifecycle
  alerts (profit target, stop loss, 21 DTE, expiration day) on open options
  positions, each firing once per position per alert kind.

## Complete (round 4 — post-round-3 gap analysis, recommendations 1–6)

A follow-up review compared the full built feature set against
`COMPETITIVE_ADAPTATION_BACKLOG.md` and found six research items that were
surfaced but never scheduled into rounds 1–3. All six are now built, in
recommended order:

1. **Catalyst calendar** (`UI/CalendarView.swift`) — combines each swing
   candidate's projected next-filing window (extrapolated cadence, labeled
   as an estimate), recent insider clusters, and recent 8-K filings. No new
   data source.
2. **Option screener** (`Core/OptionScreenFilter.swift`,
   `UI/OptionScreenerView.swift`) — thinkorswim "Option Hacker"-style scan
   by side/DTE/delta/IV/volume/OI/spread across every loaded chain at once,
   not one underlying at a time. First real connection between the equity
   recipe system's design and the options module.
3. **Fundamental sparklines + health badges**
   (`UI/FundamentalSparklineView.swift`) — `SECFloatClient.quarterlyTTM` now
   also returns a rolling 8-quarter TTM series from the same XBRL fetch;
   rendered as a trend line plus pass/fail chips on the long-term detail
   screen.
4. **Named/mutable Signal alert types** (`UI/SignalAlertTypesView.swift`) —
   per-component alert subscriptions; a muted component still ranks and
   displays, it just can't be the reason an alert fires or consumes an
   alert-budget slot.
5. **Bar-replay mode** (`UI/ChartReplayView.swift`) — scrub/step through a
   symbol's bars, reusing `CandleChartView` as-is via a truncated bars
   array rather than touching the Metal coordinator.
6. **Trendline-break pattern detection** (`Engine/PatternDetector.swift`) —
   fractal pivot detection + two-point trendline projection, a new
   `SignalComponent.trendlineBreak` that reads chart geometry rather than
   momentum/volume/float context, the only component in the scoring model
   that does.

## Complete (round 5 — the last backlog item)

**Nightly self-reweighting recipes** (`Engine/RecipeFitnessEngine.swift`) —
the Trade Ideas "Holly AI" row, the one item left unscheduled across every
prior round. Recomputes at most once per calendar day from real, resolved
`PaperTradeLog` outcomes grouped by recipe name (live results, not a
synthetic backtest — day-trade scoring needs minute-bar depth the free tier
doesn't carry far back enough to replay honestly), producing a clamped
fitness multiplier that divides into the alert threshold in
`ScannerEngine.fireAlerts`. `RecipeRow` shows a hot/cold badge once a recipe
has at least 5 resolved trades. With this, every item `COMPETITIVE_ADAPTATION_BACKLOG.md`
surfaced as free-tier-buildable has now been built.

## Not yet done / next steps

1. **First Xcode build pass.** Everything in this document — three full
   rounds of work now — was written against the reviewed source and the
   Alpaca API docs from memory, without a compiler in the loop at any point
   (this environment has no Xcode toolchain, though the unit tests are
   written to run under plain `swift test` once one is available). Before
   anything else: run `xcodegen generate && xcodebuild` on macOS and fix
   whatever the type-checker/linker actually flags. This is a larger
   surface than round 1 flagged — expect the usual crop of typos, an Alpaca
   payload field mismatch or two, `@Observable`/`@MainActor` inference
   edge cases across the newer engines (`MarketRegimeEngine`,
   `BacktestEngine`, `StrategyBotEngine`, `IVHistoryStore`), SwiftData
   `#Predicate` macro quirks in `IVHistoryStore`, and possibly a
   `RealityView` call-site signature drift version to version.
2. **Platform target.** Still targeting the latest available SDKs today
   (iOS 18+ via `project.yml`/`Package.swift`); iOS 27 and Xcode 27 do not
   exist as of this writing (September 2026). Swift 6 strict concurrency
   is already the baseline throughout every engine added in all three
   rounds, so no source changes are expected when the real deployment
   target bump happens — this remains a one-line change to
   `project.yml`/`Package.swift` once both actually ship. Re-check this
   note the next time work resumes on this project; if iOS 27/Xcode 27
   have shipped by then, bump immediately and treat it as step 1 of the
   next Xcode build pass rather than a separate task.

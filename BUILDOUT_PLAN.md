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

## Not yet done / next steps

1. **First Xcode build pass.** Everything in this document was written
   against the reviewed source and the Alpaca API docs from memory, across a
   long session, without a compiler in the loop (this environment has no
   Xcode toolchain, though the new unit tests are written to run under plain
   `swift test` once one is available). Before anything else: run
   `xcodegen generate && xcodebuild` on macOS and fix whatever the
   type-checker/linker actually flags — expect the usual crop of typos, an
   Alpaca options-payload field mismatch or two, and possibly a
   `RealityView` call-site signature drift version to version.
2. Bump deployment target to iOS 27 / build with Xcode 27 the day both exist.

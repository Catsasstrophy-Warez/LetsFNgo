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

## Not yet done / next steps

1. **First Xcode build pass.** Everything above was written against the
   reviewed source and the Alpaca API docs from memory, across a long
   session, without a compiler in the loop (this environment has no Xcode
   toolchain). Before anything else: run `xcodegen generate && xcodebuild`
   on macOS and fix whatever the type-checker/linker actually flags —
   expect the usual crop of typos, an Alpaca options-payload field mismatch
   or two, and possibly a `RealityView` call-site signature drift version to
   version.
2. **Options paper trading.** `PaperTradeLog`/`PaperTrade` are still
   single-price, single-direction — a multi-leg options position doesn't fit
   that shape. Needs its own `OptionsPaperTrade` model (or a `PaperTrade`
   subtype) before "log this spread as a paper trade" is wireable from
   `StrategyPayoffView`.
3. **Options chain pagination.** `OptionsEngine` currently scopes each chain
   to the nearest three expirations to keep the request count sane on the
   free tier; a "load more expirations" action in `OptionChainDetailView` is
   a natural follow-up once the base pipeline is proven.
4. **Unit tests.** The scoring/sizing layers already have a track record of
   deterministic-fixture testing (per the earlier `TEST_REPORT.md`
   reference); `GreeksEngine`, `StrategyBuilder`'s payoff/breakeven math, and
   `UnusualActivityDetector` are exactly the kind of pure-function surfaces
   that deserve the same treatment before shipping.
5. Bump deployment target to iOS 27 / build with Xcode 27 the day both exist.

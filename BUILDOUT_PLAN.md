# DayTradeScanner — Full Build-Out Plan

Status as of this commit: repo scaffolded as a real SwiftPM/XcodeGen project.
Swift 6 language mode, targeting the latest available SDKs today (iOS 18+);
deployment target should be bumped to iOS 27 / built with Xcode 27 the moment
Apple ships those — no source changes are expected to be required, since
Swift 6 strict concurrency is already the baseline.

## What's in this commit

```
Package.swift              swift-tools-version 6.0, iOS 18 platform, Swift 6 language mode
project.yml                XcodeGen spec: app target links RealityKit + Metal + MetalKit
Sources/DayTradeScanner/
  Core/
    MarketClock.swift       session/phase math (ET)
    Models.swift             MinuteBar/DailyBar/SignalSnapshot/Candidate/ScoreBreakdown/...
    PositionSizer.swift       whole-share risk-based sizing
    ScanProfile.swift        day/scalp/premarket/runnerHunt/haltResume weight personalities
    ScanRecipe.swift          17-recipe named-scan library + SetupType classifier
    TradeHorizon.swift       dayTrade/swing/longTerm split
    SwingModels.swift        daily-bar swing snapshot/score/candidate types
```

## Remaining to port (already reviewed, verbatim content known — mechanical work)

- `Core/LongTermModels.swift`, `Core/Settings.swift` (Keychain + ScoringConfig + observable store)
- `Data/AlpacaStream.swift`, `Data/AlpacaREST.swift`, `Data/EDGARFilingStream.swift`,
  `Data/FINRAShortVolume.swift`, `Data/HaltMonitor.swift`, `Data/StockTwitsClient.swift`,
  `Data/SECFloatClient.swift`
- `Engine/ScoringModel.swift`, `Engine/SwingScoringModel.swift`, `Engine/LongTermScoringModel.swift`,
  `Engine/SymbolState.swift`, `Engine/AlertBudget.swift`, `Engine/BaselineStore.swift`,
  `Engine/MicroStructure.swift`, `Engine/UniverseBuilder.swift`, `Engine/VolatilityProfile.swift`,
  `Engine/ScannerEngine.swift`, `Engine/SwingEngine.swift`, `Engine/LongTermEngine.swift`
- `Journal/PaperTradeLog.swift`
- `UI/*` (DiscoveryView, HaltsView, LongTermView, PaperLogView, PositionSizerView, SettingsView,
  SwingView, Style.swift, RootView, ScanView, SymbolDetailView, TuningView)
- `App/DayTradeScannerApp.swift`

Known bug to fix during the UI port: `ScanView.swift` `CandidateRow` has a plain
string literal instead of string interpolation for the "updated Xm ago" label —
needs `\(Fmt.minutes(...))`.

Known gap: `TuningView.swift` defines `swingWeightsSection` / `swingEvidenceSection` /
`longTermWeightsSection` / `longTermEvidenceSection` but never wires them into `body` —
swing/long-term weight tuning currently has no UI entry point. Fix by adding a
horizon-scoped tab or segmented control inside `TuningView`.

## New systems requested (options + Metal/RealityKit charts)

### 1. Options engine (4th horizon-adjacent engine, full build-out)

New `Options/` module, mirroring the existing engine pattern (own state, own
scoring, own paper log entries) rather than bolting onto the equity engines:

- `OptionsModels.swift` — `OptionContract` (strike, expiration, type, OI, volume,
  bid/ask, IV), `OptionChain` (per-underlying, grouped by expiration).
- `GreeksEngine.swift` — Black-Scholes (American via a binomial or
  Bjerksund-Stensland approximation) for delta/gamma/theta/vega/rho, IV solved
  by Newton-Raphson/bisection from mid price. Pure, unit-testable functions,
  same style as `PositionSizer`.
- `UnusualActivityDetector.swift` — sweep/block detection from volume vs. OI,
  volume vs. this contract's own recent average, and same-expiration clustering
  — the "flow" signal the competitive research flagged (Unusual Whales-style)
  but kept as labeled context, never a silent score override, per the existing
  house rule in `MASTER_COMPETITIVE_RESEARCH_200.md`.
- `StrategyBuilder.swift` — vertical spreads, iron condors, straddles/strangles,
  covered calls, cash-secured puts: payoff diagrams, max profit/loss, breakevens,
  probability-of-profit from IV.
- `OptionsEngine.swift` — `@MainActor @Observable`, same shape as `ScannerEngine`:
  owns a chain-data REST/stream client, runs UnusualActivityDetector on a timer,
  exposes ranked "unusual activity" and "high-probability spread" candidate lists.
- Data source: Alpaca's options market data API (same account, same free-tier
  pattern already used for equities) for chains/quotes; no new paid dependency
  required for a first cut. A licensed flow provider (Unusual Whales API) can be
  added later as an optional paid adapter, matching the "defer options-flow
  specialist context" guidance already in the research docs.
- Paper trading: extend `PaperTrade`/`PaperTradeLog` with an options-specific
  subtype (multi-leg entry, defined max loss) rather than forcing options
  through the single-price `entryPrice`/`direction` shape built for shares.

### 2. Metal-accelerated charts (chosen over RealityKit/AR)

New `Rendering/` module:

- `CandleChartRenderer.swift` — `MTKView`-backed SwiftUI view (`UIViewRepresentable`)
  rendering candlesticks/VWAP/volume as instanced Metal geometry, so a 390-bar
  intraday series (or a multi-year daily series for swing/long-term) scrolls and
  zooms at 120fps on ProMotion hardware instead of SwiftUI `Path` redraws.
- `ChartShaders.metal` — vertex/fragment shaders for candle bodies/wicks, VWAP
  line, and a volume histogram pass, all in one draw call via instancing.
- Replaces `VWAPSparkline` (currently a SwiftUI `Path`) in `SymbolDetailView` /
  `SwingDetailView` / `LongTermDetailView` with a real interactive chart:
  pinch-zoom, pan, crosshair readout — the "compact chart detail" P1 item called
  out across every competitive-research doc.
- RealityKit is intentionally *not* used for the core charts (2D financial data
  gains nothing from a 3D/AR scene graph and it would cost battery/complexity
  for no readability win) — reserved instead for an optional "market landscape"
  visionOS/iPad spatial view (sector/breadth as a 3D field) as a P3 stretch,
  matching the existing "sector/breadth dashboard" P1 requirement's 2D version
  first.

## Suggested sequencing

1. **Finish the mechanical port** (all files listed above), fix the two known
   bugs, get a green `xcodegen generate && xcodebuild` on the current SDK.
2. **Options engine v1**: models + Greeks + chain fetch + a simple ranked list,
   no strategy builder yet — mirrors how the equity engines started.
3. **Metal chart v1**: replace the sparkline in one detail view, prove the
   render pipeline, then roll out to all three horizons + the options chain view.
4. **Strategy builder + unusual-activity detector** on top of the now-live
   options chain data.
5. Bump deployment target to iOS 27 / build with Xcode 27 the day both exist.

This file is the checkpoint for continuing the build in follow-up sessions —
each item above is independently committable and testable.

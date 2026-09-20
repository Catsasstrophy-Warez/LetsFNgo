# Competitive Adaptation Backlog

Live web research (September 2026 pricing/feature pages) across 18 products
in 5 categories, run as parallel research agents against DayTradeScanner's
actual built feature set (not the earlier speculative competitive-research
docs). Each row below is a specific feature, why it matters, and whether/how
it's adaptable given DayTradeScanner's constraints: free/keyless data only
(Alpaca IEX + SEC EDGAR + Nasdaq halts + StockTwits), paper-trading only, no
broker integration.

Rows marked **[built]** were implemented directly in this pass. Everything
else is backlog, roughly ordered by value-to-effort within each section.

## Scanners — Trade Ideas, Scanz, TrendSpider, TC2000

| Feature | Source | Why it matters | Adaptation |
|---|---|---|---|
| Holly AI — nightly backtest of every strategy, auto-reweight by recent performance | Trade Ideas | Continuous self-optimizing recipe selection vs. static weights | Nightly batch job backtesting each of the 17 recipes against recent history, feeding a "recipe fitness" multiplier into `AlertBudgetKeeper` prioritization |
| Built-in visual backtesting with simulated fills | Trade Ideas | Pre-trade validation, not just post-hoc paper-trade analytics | Backtest mode replaying a recipe's gate/score logic over historical Alpaca bars, reusing `PaperTradeLog`'s existing win-rate/exit-efficiency analytics on synthetic trades |
| Level 2 order-book depth in scanner/watchlist | Scanz | Spread/size context RVOL+VWAP alone miss | Needs a paid depth feed beyond Alpaca's free IEX tier — flagged, not free-buildable |
| 400+ ad-hoc combinable filter conditions vs. fixed recipes | Scanz, TC2000's Condition Wizard | Power users want custom filter composition | A chip-based custom-recipe builder over existing signal components (RVOL, float, news, insider) with AND/OR chaining, step-by-step wizard UX like TC2000's |
| No-code "Strategy Bots" — persistent per-symbol lifecycle tracking (armed→triggered→in-trade) | TrendSpider | Turns a fire-and-forget alert into a managed automation | Extend `AlertBudgetKeeper` with a persistent per-symbol state machine, reusing its notification-rationing logic |
| Automated trendline/pattern/S&R detection on any chart | TrendSpider | Pattern-recognition signal source not currently scored | Geometric pivot/trendline detection pass over `CandleChartRenderer`'s bar data as a new `SignalComponent` |
| One-tap scan-result → annotated chart | TC2000 | Workflow friction reduction, not a new signal | "Open in chart" action on `CandidateRow` deep-linking into `CandleChartView` pre-annotated with the triggering signal |

## News/Social — Benzinga Pro, Stocktwits, Finviz

| Feature | Source | Why it matters | Adaptation |
|---|---|---|---|
| Audio squawk (news read aloud) | Benzinga Pro | Eyes stay on charts while catching breaking headlines | `AVSpeechSynthesizer` (free, on-device) reading new EDGAR filings/halt/catalyst alerts as they fire — no paid wire needed |
| Economic/earnings calendar with pre-market movers | Benzinga Pro | Centralizes catalyst timing | Calendar view from free EDGAR full-text search + public earnings calendar, auto-tagged by the existing news-catalyst classifier |
| Named "Signals" (per-pattern alert types, subscribable/mutable) | Benzinga Pro | Structures raw scores into discoverable alert categories | Expose existing RVOL/VWAP/float components as named, individually-mutable signal types in the alert UI |
| Sentiment Index (aggregate market-wide bull/bear gauge) | Stocktwits | Regime-aware context distinct from per-ticker sentiment | Client-side aggregation of already-pulled per-ticker StockTwits tags across the universe into a daily composite — zero new data |
| "Why It's Trending" auto-explainer | Stocktwits | Instant context for a spike without digging through feed | Templated one-line generator combining catalyst tag + RVOL + trending rank — **[built, generalized further, see Narrative Generator below]** |
| Watch-count alongside trending rank | Stocktwits | Early crowd-momentum proxy distinct from post volume | StockTwits' public trending endpoint already returns `watchlist_count` — add as a weighted `socialMomentum` input |
| Market Map / sector heatmap treemap | Finviz | Instant whole-market visual scan, no equivalent exists | SwiftUI/Metal treemap from Alpaca snapshot quotes grouped by SEC sector, colored by existing score thresholds |
| Filter-chip screener UX with live match count | Finviz | Faster filter composition than picking a recipe blind | Same chip-bar idea as the Scanz/TC2000 row above — worth building once, shared across both |

## Charting/Broker — TradingView, thinkorswim, Webull

| Feature | Source | Why it matters | Adaptation |
|---|---|---|---|
| Tiered alert quotas as a monetization lever | TradingView | Validates `AlertBudget` size itself as a product surface | If ever monetized: StoreKit-purchasable budget multiplier rather than a fixed cap — no rush, no monetization built yet |
| Bar-replay: scrub back, step candle-by-candle | TradingView | Mobile-friendly backtest UX | "Replay mode" in `CandleChartRenderer`: freeze live feed, pinch/pan scrubs a historical cursor with a step-forward control |
| Shareable/importable recipe format | TradingView (community scripts) | Distribution/retention without a public marketplace | Export/import named recipes as JSON via the Share sheet |
| Stock Hacker: 25 chained filters across 400+ conditions | thinkorswim | Sets the bar for filter depth the chip-builder should match | Same custom-recipe-builder backlog item, sized to match |
| Option Hacker: scan option contracts by Greeks/IV/expiry | thinkorswim | Links the scanner and options module, which are currently separate | A scan-recipe type filtering the existing options chain by Greeks/IV thresholds, in the same recipe UI as equity scans |
| Vega AI: plain-language explanation of technical signals | Webull | Lowers the interpretation barrier on weighted scores | **[built, see Narrative Generator below]** |
| One-tap "pin scan result → watchlist / open chart" | Webull | Reduces taps from scan hit to decision | Same as the TC2000 chart-deep-link item above |
| Fully free core discovery, no paywall on scan/chart/paper-trade | Webull | Validates keeping core features free | Already true for DayTradeScanner — no action needed, just confirms the existing posture |

## Options flow — Unusual Whales, Cheddar Flow, Market Chameleon, SpotGamma

| Feature | Source | Why it matters | Buildable free? | Adaptation |
|---|---|---|---|---|
| Sweep/block flow tagged by aggressor side | Unusual Whales | Core flow-discovery UX | Partial — no tick-level trade-side tape on Alpaca's free tier | A "block-like" heuristic (large single print vs. size distribution) exists as a cheap, explicitly lower-confidence proxy — not implemented this pass |
| Dark pool prints (ATS volume) | Unusual Whales | Popular institutional-accumulation signal | **No** — requires licensed FINRA ATS data | Out of scope |
| Gamma Exposure (GEX) chart, dealer hedging pressure | Unusual Whales, SpotGamma | Widely-followed structural signal | **Yes** — `OI × gamma × 100 × spot² × 0.01` per strike from data already fetched | **[built — see below]** |
| Filterable flow ticker with saved presets | Cheddar Flow | Fast triage of noisy flow | Yes — UI layer over existing `UnusualActivityDetector` output | Filter/sort bar (min premium, strike-vs-spot %, DTE range) with savable presets |
| "Power Alerts" composite 0–100 activity score | Cheddar Flow | Reduces alert fatigue vs. raw flags | Yes — same inputs `UnusualActivityDetector` already computes | `UnusualActivityDetector.Signal.score` already is this composite (0...1); rescale/relabel as 0–100 for display parity |
| IV Rank / IV Percentile vs. history | Market Chameleon | Standard vol-timing metric, currently missing | Yes — needs local daily ATM-IV history persistence | Backlog: needs a small local store (SwiftData) logging daily ATM IV per underlying |
| Earnings implied-move calculator (ATM straddle / spot) | Market Chameleon | Directly feeds the existing straddle/strangle builder | Yes — pure math on already-fetched mid prices | **[built — see below]** |
| Historical IV-skew earnings-reaction backtesting | Market Chameleon | Needs years of historical options data | **No** — requires a paid historical options vendor | Out of scope |
| Gamma flip / zero-gamma level overlay | SpotGamma | Widely-watched support/resistance analog | Yes — extension of the GEX calculation | **[built — see below]** |
| HIRO: real-time signed intraday options flow | SpotGamma | Live dealer-hedging proxy | **No** — needs a real-time options tape/SIP feed | Out of scope |
| 0DTE-isolated gamma exposure | SpotGamma | 0DTE is ~59% of SPX volume with distinct hedging dynamics | Yes — DTE filter on the same GEX calculation | **[built — see below]** |

## Fundamentals/research — Stock Rover, Koyfin, Simply Wall St

| Feature | Source | Why it matters | Adaptation |
|---|---|---|---|
| User-adjustable weighted-score sliders | Stock Rover | Lets users tune what drives the fundamentals score | Already exists for day-trade (`TuningView`'s per-component sliders) and, since the last session's fix, for swing/long-term too via the horizon picker — mostly already covered |
| Portfolio-level rollup (correlation, sector exposure) | Stock Rover | Journal scores per-trade, not aggregate portfolio composition | A "Portfolio" tab aggregating open positions' factor exposures from data already scored — no new data source |
| Historical fundamental trend sparklines (5–10yr) | Stock Rover | Turns a snapshot score into a trend story | Sparklines of revenue growth/margin/P-S from SEC EDGAR XBRL history already cached for `LongTermEngine` |
| Market-regime dashboard (rates, breadth, sector ETFs) | Koyfin | Top-down context neither engine currently factors in | A free "Market Regime" panel from Alpaca SPY/sector-ETF daily bars (% above 200SMA, sector RS), as a filter/banner atop scan results |
| Multi-panel customizable dashboard | Koyfin | Reduces context-switching between scan and research | A combined SwiftUI dashboard grid — larger UI project, lower priority than the regime panel alone |
| Earnings/filing calendar overlay on charts | Koyfin | Visual timing-risk cue | Extend `SwingScoringModel`'s existing earnings-proximity risk into a visible calendar badge on chart/watchlist rows |
| Snowflake 5-axis radar chart (Value/Growth/Past/Health/Dividends) | Simply Wall St | Multi-factor score scannable at a glance vs. a numeric list | A radar/spider chart view over `LongTermScoreBreakdown`'s existing sub-scores — pure presentation, no new data |
| Plain-language bull/bear narrative bullets | Simply Wall St | Improves interpretability without new data | **[built, generalized — see Narrative Generator below]** |
| Pass/fail "health check" badges (e.g. debt covered by cashflow) | Simply Wall St | Simplifies leverage/liquidity read vs. raw ratios | Discrete badges derived from `LongTermEngine`'s existing balance-sheet data |

---

## What was actually built this pass

Three items came up independently across multiple research agents and are
each: (a) buildable entirely from data DayTradeScanner already fetches, (b)
not structurally dependent on a paid feed, and (c) genuinely differentiating
relative to the free/self-computed tier of the market. All three are
implemented and committed in this session:

### 1. Gamma Exposure (GEX) — `Options/GammaExposureCalculator.swift`

Per-strike and net GEX (`OI × gamma × 100 × spot² × 0.01`, calls positive /
puts negative — the standard retail dealer-positioning convention used by
every GEX tracker researched, not a claim about actual dealer books), a
zero-gamma crossing finder, and a 0DTE/term split. Surfaced as a bar chart
in `OptionChainDetailView` alongside the existing chain browser. This is the
single most-requested-by-competitors options feature that's honestly
buildable from Alpaca's free chain data (Unusual Whales and SpotGamma both
charge $50–2000/mo partly for this exact chart).

### 2. Earnings implied-move calculator — `Options/StrategyBuilder.swift`

`ImpliedMoveCalculator`: expected move = ATM straddle mid-price ÷ spot,
surfaced next to the chain's ATM strikes. Directly feeds the existing
straddle/strangle flow in `StrategyBuilder` — a trader sizing a straddle
already needs this number, and it costs nothing beyond math on prices
already fetched.

### 3. Plain-language narrative generator — `Core/NarrativeGenerator.swift`

Generalizes both the Stocktwits "Why It's Trending" idea and Webull's Vega
AI / Simply Wall St's Snowflake narrative bullets into one templated
generator that reads any of the three existing score breakdowns
(`ScoreBreakdown`, `SwingScoreBreakdown`, `LongTermScoreBreakdown`) — all of
which already carry per-component contributions — and produces bull/bear
bullet text plus a one-line "why now" summary. No new data, no LLM call:
pure templating over numbers the scoring models already compute. Applied to
`SymbolDetailView`, `SwingDetailView`, and `LongTermDetailView`.

## Remaining backlog, roughly prioritized

1. Custom recipe builder (chip-based filter composition) — the single
   most-cited gap across Trade Ideas/Scanz/TC2000/thinkorswim/Finviz.
   Largest UI project in this list; do next.
2. Scan-result → annotated-chart one-tap deep link (TC2000/Webull).
3. Market-regime panel (Koyfin) — new but small: a handful of Alpaca
   daily-bar reads on SPY/sector ETFs.
4. Sector heatmap/treemap (Finviz) — meaningful visual, moderate Metal/
   SwiftUI work.
5. IV Rank/Percentile (Market Chameleon) — needs a small local IV-history
   store; natural follow-up once GEX proves the options-analytics pattern.
6. Snowflake radar chart, portfolio rollup tab, fundamental trend
   sparklines, pass/fail health badges (all Stock Rover/Simply Wall St) —
   presentation-layer work over data already scored.
7. Audio squawk via `AVSpeechSynthesizer`, earnings calendar view, named
   subscribable "Signal" alert types (Benzinga Pro) — all free/on-device,
   no blockers, just not yet scheduled.
8. Options flow filter/sort bar with saved presets, composite 0–100
   activity-score relabeling (Cheddar Flow).
9. Strategy Bots (persistent per-symbol lifecycle alerts, TrendSpider) and
   pattern/trendline detection — larger engine work, lower urgency.

Explicitly out of scope, called out by the research rather than silently
dropped: Level 2 depth-of-book, dark-pool prints, real-time signed options
flow (HIRO-style), and historical options/earnings-reaction backtesting —
all four structurally require a paid data license beyond Alpaca's free tier.

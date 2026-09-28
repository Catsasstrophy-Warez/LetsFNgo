# Finance

`Sources/NexusFinance` is the finance domain core: accounts, transactions, budgets, cash flow, investments and scenarios (MASTER_PRODUCT_SPEC, "Finance"). It has no UI and no store of its own. Every account, transaction, category, rule, budget, recurring series, scenario, security, holding and trade is an ordinary object in `NexusStore`, with relationships, events and blobs, and each value carries a truth class and provenance. The spec's one rule for this domain is that recorded financial data stays separate from interpretations and forecasts. Here that rule is enforced by truth classes and `TruthPolicy`, not by keeping data in separate places.

| Piece | Where | Notes |
|---|---|---|
| Money | `Money.swift` | `Money` is a `Decimal` plus an ISO 4217 `Currency`. No `Double` is used anywhere. `+`, `-`, `compare`, `ratio` and `sum` throw `MoneyError.currencyMismatch` when currencies differ, so there is no implicit conversion. `rounded(_:)` rounds to the currency's minor units (JPY 0, KWD 3, most others 2). The rules are `halfEven` (the default, banker's rounding), `halfUp`, `towardZero` and `awayFromZero`, all applied to the magnitude. `allocate` splits an amount without losing a cent. In the store an amount is `{amount: "<decimal string>", currency}`, so no JSON or SQLite float ever holds money. |
| Vocabulary | `Vocabulary.swift` | Object types: `account`, `transaction`, `transactionCategory`, `categoryRule`, `budget`, `recurringSeries`, `financialScenario`, `security`, `holding`, `trade`. Relations: `postedTo`, `holds`, `ofSecurity`, `projects`. Events: `statementImported`, `priceQuote`, `balanceStated`. It also defines `YearMonth` and `FinanceCalendar`: Gregorian in UTC, so a posted date is a calendar day that never moves with the device's time zone. |
| Ledger | `Ledger.swift` | Accounts, categories, transactions (`postedTo` their account) and stated balances. `setCategory` is the person's override. |
| CSV | `CSVImport.swift` | RFC 4180 parser: quotes, doubled quotes, line breaks inside quotes, BOM. `CSVMapping` maps columns by header or index, takes one signed amount column or separate debit/credit columns, a date pattern with its locale (month names), a `NumberFormat` (`.us`, `.european`, `.french`, `.swiss`, or `init(locale:)`), the delimiter, and a sign flip for card exports. Amounts accept parentheses, a trailing minus, `CR`/`DR` and currency symbols or ISO codes. Anything else (`12x`, `1e5`) is rejected. |
| OFX/QFX | `OFX.swift` | One tokenizer handles both flavours: OFX 1.x SGML, where leaf elements have no end tags, and OFX 2.x XML. It reads `STMTRS` and `CCSTMTRS`, the account (`BANKACCTFROM`/`CCACCTFROM`), `CURDEF`, every `STMTTRN` (`TRNTYPE`, `DTPOSTED`, `TRNAMT`, `FITID`, `NAME` or `PAYEE/NAME`, `MEMO`, `CHECKNUM`, per-transaction `CURRENCY`) and `LEDGERBAL`. |
| Import | `StatementImporter.swift` | The file goes to blob storage behind a `document` object; re-importing the same bytes reuses that document. Transactions go to the account named by ACCTID/BANKID, or to a new account created from the statement. |
| Categorisation | `Categorization.swift` | `CategoryRule` objects have conditions: payee (or memo) contains, amount range, direction and account, plus a priority. `CategorySuggester` is the hook for a local or cloud model. |
| Budgets and cash flow | `Budgets.swift` | Monthly budgets per category, with actuals and a favourable-positive variance. Cash-flow statements cover a month, a range of months or any interval. Transfer categories are reported separately. |
| Recurring | `Recurring.swift` | Groups transactions by account, payee and direction. A group is a series when it has at least 3 occurrences with steady weekly, biweekly, monthly, quarterly or annual gaps and amounts within 10 % of the median. Stored series are updated in place on each run. |
| Scenarios | `Scenarios.swift` | A projection month by month from recorded balances, recurring series and assumptions: `oneOff`, `monthly`, `adjustRecurring` and `stopRecurring`. `compare` diffs two scenarios, their minimums and the first month below zero. |
| Investments | `Investments.swift` | Securities, trades, holdings (`account holds holding ofSecurity security`), FIFO and average-cost lots, realised and unrealised gains, and allocation by asset class. Securities without a recorded price are listed as unpriced. |

## Truth classes

| Value | Truth class | Origin | Why |
|---|---|---|---|
| Imported transaction (OFX, CSV) | **recorded** | `importer(source: <document>)`, the document in `dependencies`, the row in `method` | A direct record from a trusted external system, the bank. The origin names the stored file, so every row traces back to the bytes it came from. The person who imported it is named in `method` and on the `statementImported` event. |
| Transaction entered by hand | **recorded** | `user` | A person's own record of what they spent. |
| Ledger balance from a statement (`LEDGERBAL`) | **recorded** | `importer(source: <document>)` | The same as the transactions. An older statement never replaces a newer balance, though both stay on the timeline as `balanceStated` events. |
| Balance a person states | **recorded** (or **observed**) | `user` | Only recorded or observed truth can sit on an account balance. `Ledger.recordBalance` refuses anything else with `truthNotAllowed`. |
| Category set by a rule | **derived** | `system`, the rule object in `dependencies`, "rule: <name>" | A calculation over the transaction and a rule the person wrote. |
| Category suggested by a model | **agentInterpretation** | `model(ModelRef)`, with `confidence` | An AI conclusion. Suggestions below the confidence floor are dropped. |
| Category set by a person | **recorded** | `user` | The person's own classification of their money. It is protected: rule runs and model passes skip it, and `TruthPolicy` refuses a derived or interpreted write over it (`StoreError.truthConflict`). |
| Budget amounts | **recorded** | `user` | The person's plan, as they wrote it. |
| Budget actuals, variance, cash flow | **derived**, computed on read | | They count **recorded** transactions only, so an agent's guessed or a modeled transaction never becomes an actual. They are not stored, so they cannot go stale beside the data. |
| Recurring series | **derived** | `system`, the matched transactions in `dependencies` | Detected by calculation over recorded transactions. |
| Scenario assumptions | **claimed** | the author | A statement about something that hasn't happened ("rent rises 20 % in September"). |
| Forecast (projection) | **modeled** | `simulation(run: <scenario>)`, accounts and series in `dependencies` | Simulation output. It is stored only on the scenario object (`projection`), together with a `simulated` event. It can never be written onto an account balance: `Ledger.recordBalance` refuses modeled truth, and the store's `TruthPolicy` refuses a modeled value over the recorded balance. Tests cover both paths. |
| Trade | **recorded** | `user` or `importer` | A broker record or the person's own record. |
| Price from an importer or a person | **recorded** | `importer` / `user` | A quote from a trusted feed or statement. |
| Price from an agent or a model | **claimed** | `agent` / `model` | An assertion. It is kept on the security's timeline, but gains, market value and allocation use only recorded (or observed) prices. |
| Lots, cost basis, realised and unrealised gain, allocation | **derived** | `system` | Calculated from recorded trades and prices. The holding object also stores its current quantity and FIFO cost basis as derived attributes, for search and display. |

## Dedup

A statement row duplicates a stored transaction on the same account when:
- both rows have a FITID and the FITIDs match; or
- either row has no FITID and their **content keys** match.

A content key is the SHA-256 of (day, amount, currency, normalised payee), followed by the row's occurrence number for that hash within its file. Re-importing any file adds nothing. A CSV export that overlaps an OFX download matches the OFX rows. Two identical coffees on one day are both kept.

## Categorisation precedence

person (recorded) > rule (derived) > model (agentInterpretation)

A rule run replaces a model's suggestion and an older rule's result. A model pass only fills transactions that have no category. Neither ever touches a person's category.

## Tests

`Tests/NexusFinanceTests` (Swift Testing):

- `MoneyTests`: exact arithmetic, currency mismatches, rounding rules, minor units, allocation, parsing and string-backed Codable.
- `ImportTests`: number formats, CSV quoting, mappings with locale dates and debit/credit columns, SGML and XML OFX, provenance to the stored blob, and dedup by FITID and by hash.
- `CategorizationTests`: rule conditions and the derived, interpreted and recorded precedence. An agent's write over a person's category is refused.
- `BudgetTests`: variance, cash flow and transfers. An agent-guessed transaction is excluded from actuals. Recurring rent, a varying utility bill and a weekly gym fee are detected; irregular payments are not.
- `ScenarioTests`: the projection is modeled and stored on the scenario, and the account is untouched. A modeled balance is refused by the ledger and by `TruthPolicy`. Assumptions are claimed. Two scenarios are compared, and the first negative month is found.
- `InvestmentTests`: FIFO and average cost, realised and unrealised gains, recorded and claimed prices, allocation, unpriced holdings and overselling.
- `FinanceSliceTests`: end to end on one SQLite file. It imports OFX (SGML and XML) and CSV, dedups, and categorises with rules plus a person's override that a later rule run leaves alone. It then checks a budget variance, detects the recurring rent, runs a modeled forecast that never changes the recorded balance, saves, and reloads with objects, revisions, relationships, timeline, blobs and reports identical.

## Follow-ups

- OFX investment statements (`INVSTMTRS`: `BUYSTOCK`, `SELLSTOCK`, `INVPOS`) should feed `Portfolio`.
- Multi-currency totals need an explicit, recorded FX rate. Until then, mixing currencies throws.
- Finance research should use `NexusResearch` over filings and analyst sources, with its claims attached to `security` objects.
- A finance specialist agent (`NexusAgents`) and finance screens (`NexusUI`).
- Splits, and transfers matched across two accounts.

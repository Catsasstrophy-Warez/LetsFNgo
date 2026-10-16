# Contributing a data correction

GT500 Companion only shows facts that cite a public source. Every record in `src/data/` carries a `source`
(an **https** URL) and a `confidence` (`confirmed` / `reported` / `unverified`). Unknowns are `null` with a `note`
saying what is missing, and when sources disagree every sourced value is kept in a `conflicts` list. Nothing is
estimated or invented.

## Find what needs help

Open the app's **Data Coverage** page (`#/coverage`, in the menu). It is computed from `src/data/` and lists:

- confidence counts per section,
- every gap (null field) with the note that says what is needed, linked to where it shows in the app,
- every conflict between sources,
- the source domains facts come from.

## Option 1 — open an issue (no code)

Use the **Data correction** issue template (`.github/ISSUE_TEMPLATE/data-correction.yml`). Give the section and
record (as named on the Coverage page), the field, the proposed value with its unit, an https source URL and the
exact quote from that source. A maintainer will add it.

## Option 2 — open a pull request

1. Edit the record in the right file under `src/data/` (the collection names on the Coverage page match the exports
   in `src/data/index.ts`). Keep the record shape from `src/data/types.ts`.
2. Rules the checker enforces:
   - `source` is an `https://` URL; `confidence` is `confirmed`, `reported` or `unverified`.
   - A `null` value needs a `note` explaining the gap.
   - Ids are unique within a collection and no record is duplicated.
   - `conflicts` / `priceConflicts` / `productionConflicts` entries are full sourced values (`value`, `source`,
     `confidence`, optional `context`), hold at least two different values between them and the record, and do not
     repeat the same value + source.
   - Records with a research level keep `high → confirmed`, `medium → reported`, `low → unverified`.
   - No unknown fields: every object schema is closed (`additionalProperties: false`).
3. Confidence guide: **confirmed** = a Ford / Shelby primary document or several independent reputable sources;
   **reported** = one reputable secondary source (magazine, major outlet); **unverified** = forum posts, databases,
   or low-quality sources. When in doubt, pick the lower level.
4. Run the checks:

   ```sh
   npm run validate:data   # schema + contribution rules for every record
   npm test                # unit tests (includes a schemas-in-sync test)
   ```

5. If you added a field to a type, add it to `src/lib/dataSchema.ts` too and regenerate the committed JSON Schemas:

   ```sh
   npm run validate:data -- --write-schemas
   ```

   The files in `schemas/` (one per collection, JSON Schema 2020-12) can also be used by editors and other tools.

## Source links

`npm run check:links` checks every unique source URL (HEAD, then GET; timeouts and retries) and writes
`link-report/links.md` and `links.json` (ok / redirect / 4xx / 5xx / blocked / error). Many sites block automated
requests (`blocked`), which does not mean the page is gone. A GitHub Actions workflow (`Source link check`) runs it
weekly and on demand and uploads the report as an artifact; it never fails a build or commits anything. For a dead
link, prefer replacing it with a web.archive.org snapshot of the same page.

## Code changes

See the README for the dev setup. Keep `npm run typecheck`, `npm run lint`, `npm test`, `npm run validate:data`,
`npm run build` and `npm run e2e` green, and add every UI string to both `src/lib/i18n.ts` and `src/lib/i18n-es.ts`.

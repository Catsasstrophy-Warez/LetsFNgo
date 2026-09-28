# Travel, contacts, career and buildings

Four domains added after finance, each a vocabulary over the one world model
(Project → Object → Relationship → Event → Evidence → Action), not a mini-app.
Each is a small module with an importer, a runtime and tests. None keeps a store
of its own: everything goes through `NexusPersistence`. None adds a migration.

The same truth rules hold in all four:

- An imported value is **recorded**. Its origin is `importer(source:)`, naming
  the stored file (a `document` whose bytes are a blob) or the address book
  (a `source`).
- A value a person enters is **observed**.
- A timeline, a conflict, an area total or a "days since last contact" figure is
  **derived**. It is computed on read and never stored.
- Anything an agent suggests is an **agent interpretation**, kept apart from
  facts. Re-imports never overwrite what a person entered.

Six read-only agent tools cover the four domains (`Sources/NexusAgents/DomainTools.swift`):
`trip_timeline`, `contacts_due`, `job_applications`, `expiring_certifications`,
`space_summary` and `locate_asset`. They are registered in `WorldTools.all` and
given to the `project` agent. The UI adds a section per domain to the Project
screen and a domain view in Object Detail, the way Finance and Automotive do. No
new screen families were added.

## Travel (`NexusTravel`)

- **Objects:** `trip`, `travelLeg` (mode `flight`, `train`, `drive`, `stay` or
  `other`), `booking` (a confirmation code), `place`.
- **Relationships:** `hasLeg` (trip → leg), `departsFrom`, `arrivesAt`, and
  `covers` (booking → leg).
- **Import:** iCalendar `.ics` (RFC 5545: unfolding, escapes, TZID, UTC, floating
  and all-day times, DURATION, nested VALARMs skipped). Re-import matches legs by
  UID. A leg's mode is guessed from its wording, so it is stored as derived. A
  person's correction is observed and later imports keep it.
- **Boarding passes:** reads an IATA BCBP barcode string or a Wallet `pass.json`,
  not a zipped `.pkpass`. A pass for a flight already on the trip adds its seat
  and confirmation to that leg.
- **Derived:** the trip timeline, with connection times, and three conflict
  checks: overlapping legs, tight connections (flight 60 min, train 15 min) and
  place mismatches.

## Contacts (`NexusCRM`)

- **Objects:** the shared `person` and `organization` types, with `worksAt`.
  Interactions are `interaction` events on the shared timeline. Follow-ups are
  `task`s linked by `followUpFor`.
- **Import:** vCard 2.1, 3.0 and 4.0 (`.vcf`), on every platform. It handles
  groups, folding, escapes, quoted-printable and `tel:` URIs. It merges by card
  UID, then email, then name, and only adds to what is there.
- **Apple Contacts:** read-only import through the Contacts framework, after the
  person grants permission. The code is in `Sources/NexusUI/AppleContacts.swift`
  (Apple-only) and feeds the same importer.
- **Derived:** last contacted and cadence ("haven't talked in 90 days"). The
  default cadence is 90 days, and each person can have their own. Only recorded
  or observed interactions count; an agent's inference never resets the clock.
  Overdue contacts can be turned into follow-up tasks.

## Career (`NexusCareer`)

- **Objects:** `jobRole` (with `employedBy` → `organization`), `skill`
  (`usesSkill`), `certification` (`issuedBy`), `workProject` (`workedOn`) and
  `jobApplication` (`appliedTo`).
- **Applications:** a status pipeline (saved → applied → screening →
  interviewing → offer → accepted, or rejected or withdrawn at any open stage).
  Each move is an `applicationStatusChanged` event.
- **Certifications:** each certification has a derived standing. Expiring and
  expired ones get "Renew …" tasks (linked by `renews`). The tasks are drafts
  when an agent creates them. Renewing a certification closes its task.
- **Import:** JSON Resume. It also accepts a non-standard `expiryDate` on
  certificates.
- **Résumé:** a Markdown `artifact` derived from the objects. It lists
  dependencies on every object it used and leaves out agent-suggested skills and
  expired certifications.

## Buildings and spaces (`NexusArchitecture`)

- **Objects:** `site` → `building` → `storey` → `space`, nested with the core
  `contains`. A project that contains a building therefore reaches its rooms.
  Spaces carry number, area (a quantity in `m2` or `[sft_i]`), capacity and use.
- **Assets:** existing equipment, sensors, instruments and vehicles are placed
  with `locatedIn`. A move ends the old relationship, so location history is kept.
- **Room schedules:** `spaceReservation` objects, linked by `reserves`. Double
  bookings are refused, and free spaces can be found for an interval and a
  capacity.
- **Import:** a space-list CSV, with columns found by header name and areas in
  m² or ft². The IFC import is a minimal STEP reader for IfcSite, IfcBuilding,
  IfcBuildingStorey and IfcSpace. It reads names, long names, storey elevations
  (with the length unit), IfcRelAggregates nesting and space areas from
  IfcElementQuantity, and matches on GlobalId when re-importing. It reads no
  geometry.
- **Derived:** floor-area totals.

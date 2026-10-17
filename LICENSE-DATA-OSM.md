# OpenStreetMap data (ODbL 1.0)

`src/data/startFinishLines.ts` contains data derived from OpenStreetMap.

Data © OpenStreetMap contributors, available under the Open Database License (ODbL) 1.0:
https://www.openstreetmap.org/copyright — full licence text: https://opendatacommons.org/licenses/odbl/1-0/

- Snapshot: OSM base 2026-06-01T08:52:28Z.
- Derivation: each start/finish gate (`a`/`b`) is an OSM start/finish node offset 10 m either side,
  perpendicular to the bearing of its `highway=raceway` way. The source node and way are cited per entry.
- The derived lines are a Derivative Database under the ODbL; if you redistribute them, keep this attribution
  and offer the derived data under the ODbL.

Only that file is covered by the ODbL. The rest of this project's code and data is not affected.

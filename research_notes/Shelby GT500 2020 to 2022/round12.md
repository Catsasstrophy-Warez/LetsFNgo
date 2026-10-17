# Round 12: OSM line retry, way-geometry check, dead-link replacements, competitor prices
Date: 2026-10-17. Machine-readable data is in round12.json.

## 1. Start/finish lines (OpenStreetMap Overpass)
- Endpoints tried:
  - overpass-api.de: no response (connection failed).
  - overpass.kumi.systems: HTTP 500.
  - overpass.private.coffee: HTTP 500.
  - maps.mail.ru/osm/tools/overpass: worked. OSM base 2026-10-17T07:01–07:11Z.
- Method: highway=raceway ways within 2.5 km of each facility point, plus their tagged nodes and any `raceway=*` features. I filtered every key and value for start / finish / timing / S/F.
- **No new lines found.** startFinishLines is empty.
  - Nothing tagged at 15 tracks, though raceway ways exist at each (way count in brackets):
    - VIR (42), Watkins Glen (23), Sebring (27, retried at 1.8 km), Road Atlanta (14)
    - Sonoma (21), Mid-Ohio (10), NOLA (15), Gainesville (10)
    - Pomona (1), Atco (1), Summit Point (29), Carolina MP (13)
    - Brainerd (8), Utah MC (31), NJMP (12)
  - Queries timed out twice (504 or error) at 6 tracks: Buttonwillow, Willow Springs, Barber, Texas Motorplex, Pittsburgh, LVMS. Round 10 found nothing at these.
  - zMAX has no facility coordinate.

## 2. Way geometry for the 9 existing lines (re-fetched 2026-10-17)
All 9 bearings match startFinishLines.ts exactly. Each bearing runs from the node before the line node to the node after it, in way order.

| trackId | way | bearing° | oneway |
|---|---|---|---|
| laguna-seca | 10464852 | 216.3 | yes |
| charlotte | 402168709 | 195.3 | yes |
| chuckwalla | 218017846 | 38.3 | **untagged** (closed way). Direction 0 is correct. |
| COTA (node 7909207460) | 118258939 | 128.1 | yes |
| COTA (node 13826373967) | 118258939 | 128.1 | yes |
| lime-rock | 293189369 | 114.0 | yes |
| road-america | 122090289 | 178.8 | yes |
| thunderhill East | 28825115 | 179.6 | yes |
| thunderhill West | 756822999 | 353.3 | yes |

So direction=+1 (travel along the way's node order) is consistent with the OSM data at all 8 oneway lines. This is still the mappers' claim and has not been checked against track documentation.

## 3. Dead-link replacements
Archive services were rate-limited (archive.ph and archive.org both returned 429), so every replacement is the same article found on another live URL.

| Entry | Replacement | Evidence |
|---|---|---|
| dyno hennessey | fordauthority.com/2020/01/hennessey-performance-straps-a-2020-shelby-gt500-to-the-dyno | Same story per search. curl got 403 (bot block). Medium. |
| dyno enginelabs | fordmuscle.com/news/whipple-upgrade-pushes-a-gt500s-predator-v8-past-four-digits/ | 200. Title matches; text has "723 rear-wheel horsepower". High. |
| mods borla | azproperformance.com/products/borla-2020-ford-gt500-5-2l-at-3in-atak-catback-exhaust-w-chrome-tips | 200. SKU BOR140837 at $2,799.99. High. |
| fordmuscle ?p=938086 (2 entries) | fordmuscle.com/news/bolt-on-stock-motor-shelby-gt500-breaks-into-the-8-second-zone/ | 200. Title matches; text has "8.86 at 163 mph". High. |
| production colors (AOL) | none found | Gap. |
| Motorcraft 5W-50 PDF (2 entries) | fcsdchemicalsandlubricants.com/products/motor-oil/productdetails?id=69 | 200. Page states API SP and WSS-M2C931-E1. High. |
| performance customer-stock (Dragzine) | fordmuscle.com/news/stock-customer-owned-2020-gt500-quarter-mile/ | 200. Title matches; dated 2019-12-04. High. |
| communities reddit mirror | reddit.com/r/GT500/ | Canonical URL. curl got 403. Medium. |

## 4. Competitor prices
- **ZL1 1LE package, 2020–2022:** not found. The only package price is $7,500, from 2017 launch coverage. Gap.
- **2021 Hellcat:** sources conflict.
  - iSeeCars: $60,150 plus $1,495 destination.
  - Hendrick dealer guide: $61,465.
  - Motor Matchup: $59,245.
  - Low confidence.
- **2022 Hellcat:** sources conflict.
  - iSeeCars: $64,830.
  - CarGurus: $68,320.
  - Hendrick: $69,620.
  - Low confidence.
- **2022 Redeye:** sources conflict.
  - iSeeCars: $76,430, excluding $1,595 destination and $1,768 gas-guzzler tax.
  - Hendrick: $78,225.
  - Motor Matchup: $80,940.
  - Low confidence.
- **2022 ZL1 convertible, manual:** $69,000 including $1,395 destination (iSeeCars). Medium confidence.
- **2022 ZL1 10-speed automatic option:** +$1,595 (ccarprice.com, a non-US site). Low confidence.
- No Stellantis or GM media page was reached. gmauthority.com returned 403.

## Sources
- https://maps.mail.ru/osm/tools/overpass/api/interpreter (OSM data © OpenStreetMap contributors, ODbL)
- https://www.fordmuscle.com/news/whipple-upgrade-pushes-a-gt500s-predator-v8-past-four-digits/
- https://www.fordmuscle.com/news/bolt-on-stock-motor-shelby-gt500-breaks-into-the-8-second-zone/
- https://www.fordmuscle.com/news/stock-customer-owned-2020-gt500-quarter-mile/
- https://azproperformance.com/products/borla-2020-ford-gt500-5-2l-at-3in-atak-catback-exhaust-w-chrome-tips
- https://fcsdchemicalsandlubricants.com/products/motor-oil/productdetails?id=69
- https://fordauthority.com/2020/01/hennessey-performance-straps-a-2020-shelby-gt500-to-the-dyno
- https://www.iseecars.com/car/2021-dodge-challenger-price
- https://www.iseecars.com/car/2022-dodge-challenger-price
- https://www.hendrickdodge.com/2021-dodge-challenger-price/
- https://www.hendrickdodge.com/2022-dodge-challenger-price/
- https://cargurus.com/research/2022-Dodge-Challenger-c32018
- https://www.iseecars.com/car/2022-chevrolet-camaro-price
- https://www.ccarprice.com/ir/compare-chevrolet-camaro-zl1-convertible-2022-7117.php
- https://www.autoblog.com/tag/camaro+1le/
- https://www.carscoops.com/?p=2300085

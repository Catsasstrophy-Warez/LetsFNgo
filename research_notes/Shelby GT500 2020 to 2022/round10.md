# Round 10: Start/finish line coordinates from OpenStreetMap

## Takeaway
OSM has a start/finish node mapped on a raceway way for **8 of 28 tracks that have centroids** (9 lines; COTA has two candidate nodes). zMAX has no centroid and was not queried. Every gate in round10.json is **derived**: OSM maps the line as a single point (node), never as a two-point line way. So every entry is `confidence: unverified`. The node position is mapper-reported. The 20 m perpendicular gate is computed from it. Validate against the on-site timing line before shipping. No drag strip has a tagged starting line or 1/4-mile finish in OSM. Drag strips are mapped only as untagged `highway=raceway` ways, so none were recorded. Their way endpoints are mapping artifacts, not timing lines.

## Method
- Endpoint: overpass-api.de reset every connection through the session proxy. The mirror `https://overpass.private.coffee/api/interpreter` worked, intermittently (HTTP 500s, retried). Data snapshot `timestamp_osm_base` = 2026-06-01T08:52:28Z.
- Per track: `(way["highway"="raceway"](around:R,lat,lon); nwr["raceway"](…); nwr["race_track"](…); nwr["finish"](…);)->.w;(.w;.w>;);out;`. R = 3000 m for most tracks; 2000 m for COTA, Road Atlanta, Buttonwillow, Barber, Charlotte, Gainesville, Pomona and Summit Point, because 3 km kept failing on the mirror. Tags on every returned element (including raceway member nodes) were then scanned for start/finish/S-F/line/drag/1/4/timing.
- Limitation: a finish-line node that sits off any raceway way and lacks raceway/race_track/finish keys (e.g. only `name=Start`) would be missed. A broad name-regex query timed out or failed on the mirror. Official track maps/PDFs were not checked this round. Those maps are raster images without coordinates, so they could only confirm the location.
- Derivation: bearing between the node's two neighbors on its raceway way; endpoints ±10 m perpendicular. Direction comes from way direction only when the way is `oneway=yes`.

## Cited findings
| trackId | Config | OSM node (tag) | Node lat, lon | Raceway way | Bearing ° | a | b | Conf |
|---|---|---|---|---|---|---|---|---|
| weathertech-raceway-laguna-seca | Grand Prix Circuit | [node 8866453726](https://www.openstreetmap.org/node/8866453726) `description="Start/Finish"` | 36.5864582, -121.7566371 | [way 10464852](https://www.openstreetmap.org/way/10464852) oneway=yes | 216.3 | 36.586405, -121.7565468 | 36.5865114, -121.7567274 | unverified |
| charlotte-motor-speedway | Quad Oval | [node 9668619996](https://www.openstreetmap.org/node/9668619996) `raceway=start-finish` | 35.3522551, -80.6855926 | [way 402168709](https://www.openstreetmap.org/way/402168709) oneway=yes | 195.3 | 35.3522313, -80.6854863 | 35.3522789, -80.6856989 | unverified |
| chuckwalla-valley-raceway | Start/finish (layout not specified in tag) | [node 2273254970](https://www.openstreetmap.org/node/2273254970) `raceway=start-finish` | 33.7536714, -115.3196227 | [way 218017846](https://www.openstreetmap.org/way/218017846) oneway=None | 38.3 | 33.7537271, -115.3197076 | 33.7536157, -115.3195378 | unverified |
| circuit-of-the-americas | Grand Prix Circuit | [node 7909207460](https://www.openstreetmap.org/node/7909207460) `raceway=start-finish` | 30.131893, -97.6398291 | [way 118258939](https://www.openstreetmap.org/way/118258939) oneway=yes | 128.1 | 30.1319638, -97.6397649 | 30.1318222, -97.6398933 | unverified |
| circuit-of-the-americas | node named "Finish Line" (layout unspecified) | [node 13826373967](https://www.openstreetmap.org/node/13826373967) `name="Finish Line"` | 30.1335372, -97.64225 | [way 118258939](https://www.openstreetmap.org/way/118258939) oneway=yes | 128.1 | 30.133608, -97.6421859 | 30.1334664, -97.6423141 | unverified |
| lime-rock-park | Grand Prix Circuit | [node 4314687370](https://www.openstreetmap.org/node/4314687370) `name="S/F Line"` | 41.9285995, -73.3810094 | [way 293189369](https://www.openstreetmap.org/way/293189369) oneway=yes | 114.0 | 41.9286817, -73.3809603 | 41.9285173, -73.3810585 | unverified |
| road-america | Grand Prix Course | [node 4317202676](https://www.openstreetmap.org/node/4317202676) `name="Road America S/F Line"` | 43.7978954, -87.9896282 | [way 122090289](https://www.openstreetmap.org/way/122090289) oneway=yes | 178.8 | 43.7978972, -87.9895036 | 43.7978936, -87.9897528 | unverified |
| thunderhill-raceway-park | East Circuit | [node 316914551](https://www.openstreetmap.org/node/316914551) `description="Start/Finish (East)"` | 39.5384764, -122.3311785 | [way 28825115](https://www.openstreetmap.org/way/28825115) oneway=yes | 179.6 | 39.538477, -122.3310619 | 39.5384758, -122.3312951 | unverified |
| thunderhill-raceway-park | West Circuit | [node 9372293077](https://www.openstreetmap.org/node/9372293077) `description="Start/Finish (West)"` | 39.5374544, -122.3387965 | [way 756822999](https://www.openstreetmap.org/way/756822999) oneway=yes | 353.3 | 39.5374439, -122.3389123 | 39.5374649, -122.3386807 | unverified |

Notes:
- **Laguna Seca**: the `description=Start/Finish` node is on the main circuit way 10464852 (oneway, bearing 216°).
- **Charlotte**: `raceway=start-finish`, named "Charlotte Motor Speedway Start/Finish Line". It is on the oval's frontstretch way, shared with the 1/4 Mile track. This is the oval line; no Roval-specific line is mapped.
- **COTA**: two nodes on the same oneway way about 240 m apart. Node 7909207460 is `raceway=start-finish` (preferred). Node 13826373967 is `name=Finish Line` (layout unspecified). The way direction (128°) is the mapper's.
- **Chuckwalla**: `raceway=start-finish` on way 218017846, which has no oneway tag, so direction is unknown.
- **Lime Rock** ("S/F Line" on Sam Posey Straight) and **Road America** ("Road America S/F Line" on Road America Straight): name-tagged nodes.
- **Thunderhill**: separate "Start/Finish (East)" and "Start/Finish (West)" description nodes. These are the separate East and West circuits. No Five Mile line is mapped.
- Nothing found: VIR, Watkins Glen, Sebring, Road Atlanta, Buttonwillow, Willow Springs, Sonoma, Mid-Ohio, Barber, NOLA, Gainesville, Pomona, Atco, Texas Motorplex, Pittsburgh (a node named "False Grid" only, not a line), Summit Point, Carolina MP, Brainerd, Utah MC, NJMP, LVMS, zMAX (no centroid).
- Drag-strip raceway ways exist but carry no start/finish tagging: Pomona way 34396976, Sonoma way 28825448, Brainerd way 137243025, Buttonwillow way 34351305, Texas Motorplex ways 550188092/550188094, Willow Springs 1/4-mile ways 34365657/167547789.

## License
OSM data © OpenStreetMap contributors, ODbL 1.0 (https://www.openstreetmap.org/copyright). The app must display "© OpenStreetMap contributors". A derived database redistributed publicly is subject to ODbL share-alike.

## Gaps
Official circuit maps; on-site GPS capture; confirming direction of travel against track documentation; tracks with nothing in OSM.

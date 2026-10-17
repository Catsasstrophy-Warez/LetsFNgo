import type { StartFinishLine } from './types';

/**
 * Sourced start/finish lines (one record per track configuration), linked to `tracks` by `trackId`.
 *
 * THIRD-PARTY DATA — this file only:
 * Data © OpenStreetMap contributors, available under the Open Database License (ODbL) 1.0,
 * https://www.openstreetmap.org/copyright. OSM snapshot 2026-06-01 (timestamp_osm_base 2026-06-01T08:52:28Z).
 * The gate endpoints `a`/`b` are derived: each OSM start/finish node offset 10 m either side, perpendicular to the
 * bearing of its highway=raceway way (great-circle, 6371008.8 m sphere). `direction` is +1 only where the way is
 * tagged oneway (mapper-asserted). See LICENSE-DATA-OSM.md. The rest of the project's code and data is not ODbL.
 *
 * Every entry is `unverified`: the lap timer warns that the line is derived and should be confirmed on-site.
 * See CONTRIBUTING.md → "Track start/finish lines".
 */
export const startFinishLines: StartFinishLine[] = [
  {
    "id": "weathertech-raceway-laguna-seca--grand-prix-circuit",
    "trackId": "weathertech-raceway-laguna-seca",
    "configuration": "Grand Prix Circuit",
    "a": {
      "lat": 36.586405,
      "lon": -121.7565468
    },
    "b": {
      "lat": 36.5865114,
      "lon": -121.7567274
    },
    "direction": 1,
    "sectors": [],
    "source": "https://www.openstreetmap.org/node/8866453726",
    "confidence": "unverified",
    "note": "OSM node 8866453726 (description=\"Start/Finish\") at 36.5864582, -121.7566371 lies on highway=raceway way 10464852 ('WeatherTech Raceway Laguna Seca'). Bearing of the way between neighbor nodes 7215279273 and 89865258 = 216.3 deg; a and b are the node offset 10 m each way perpendicular (bearing 126.3 / 306.3 deg), great-circle on a 6371008.8 m sphere. Gate endpoints are derived, not mapped; the node itself may not be at track center. Way: https://www.openstreetmap.org/way/10464852. Direction: Bearing about 216.3 deg (from the OSM way direction with oneway=yes; mapper-asserted, not checked against official track documentation); stored as +1 (travel along the way bearing). Oneway bearing re-verified against OSM on 2026-10-17 (still mapper data, not track documentation). Derived and unverified: confirm on-site."
  },
  {
    "id": "charlotte-motor-speedway--quad-oval",
    "trackId": "charlotte-motor-speedway",
    "configuration": "Quad Oval",
    "a": {
      "lat": 35.3522313,
      "lon": -80.6854863
    },
    "b": {
      "lat": 35.3522789,
      "lon": -80.6856989
    },
    "direction": 1,
    "sectors": [],
    "source": "https://www.openstreetmap.org/node/9668619996",
    "confidence": "unverified",
    "note": "OSM node 9668619996 (raceway=start-finish) at 35.3522551, -80.6855926 lies on highway=raceway way 402168709 ('Charlotte Motor Speedway;1/4 Mile track'). Bearing of the way between neighbor nodes 4040735196 and 4040734683 = 195.3 deg; a and b are the node offset 10 m each way perpendicular (bearing 105.3 / 285.3 deg), great-circle on a 6371008.8 m sphere. Gate endpoints are derived, not mapped; the node itself may not be at track center. Way: https://www.openstreetmap.org/way/402168709. Direction: Bearing about 195.3 deg (from the OSM way direction with oneway=yes; mapper-asserted, not checked against official track documentation); stored as +1 (travel along the way bearing). Oneway bearing re-verified against OSM on 2026-10-17 (still mapper data, not track documentation). Derived and unverified: confirm on-site."
  },
  {
    "id": "chuckwalla-valley-raceway--start-finish",
    "trackId": "chuckwalla-valley-raceway",
    "configuration": "Start/finish (layout not specified in tag)",
    "a": {
      "lat": 33.7537271,
      "lon": -115.3197076
    },
    "b": {
      "lat": 33.7536157,
      "lon": -115.3195378
    },
    "sectors": [],
    "source": "https://www.openstreetmap.org/node/2273254970",
    "confidence": "unverified",
    "note": "OSM node 2273254970 (raceway=start-finish) at 33.7536714, -115.3196227 lies on highway=raceway way 218017846. Bearing of the way between neighbor nodes 2273254943 and 2273255047 = 38.3 deg; a and b are the node offset 10 m each way perpendicular (bearing 308.3 / 128.3 deg), great-circle on a 6371008.8 m sphere. Gate endpoints are derived, not mapped; the node itself may not be at track center. Way: https://www.openstreetmap.org/way/218017846. No direction given (the way is not tagged oneway); either direction counts and the first crossing sets it. Way bearing re-verified against OSM on 2026-10-17; the way is still not tagged oneway (mapper data, not track documentation). Derived and unverified: confirm on-site."
  },
  {
    "id": "circuit-of-the-americas--grand-prix-circuit",
    "trackId": "circuit-of-the-americas",
    "configuration": "Grand Prix Circuit",
    "a": {
      "lat": 30.1319638,
      "lon": -97.6397649
    },
    "b": {
      "lat": 30.1318222,
      "lon": -97.6398933
    },
    "direction": 1,
    "sectors": [],
    "source": "https://www.openstreetmap.org/node/7909207460",
    "confidence": "unverified",
    "note": "OSM node 7909207460 (raceway=start-finish) at 30.131893, -97.6398291 lies on highway=raceway way 118258939. Bearing of the way between neighbor nodes 13826373967 and 1330333420 = 128.1 deg; a and b are the node offset 10 m each way perpendicular (bearing 38.1 / 218.1 deg), great-circle on a 6371008.8 m sphere. Gate endpoints are derived, not mapped; the node itself may not be at track center. Way: https://www.openstreetmap.org/way/118258939. Direction: Bearing about 128.1 deg (from the OSM way direction with oneway=yes; mapper-asserted, not checked against official track documentation); stored as +1 (travel along the way bearing). Oneway bearing re-verified against OSM on 2026-10-17 (still mapper data, not track documentation). COTA has two candidate OSM lines; prefer the raceway=start-finish node 7909207460 (Grand Prix Circuit) over the node named \"Finish Line\" (13826373967). Derived and unverified: confirm on-site."
  },
  {
    "id": "circuit-of-the-americas--finish-line-node",
    "trackId": "circuit-of-the-americas",
    "configuration": "node named \"Finish Line\" (layout unspecified)",
    "a": {
      "lat": 30.133608,
      "lon": -97.6421859
    },
    "b": {
      "lat": 30.1334664,
      "lon": -97.6423141
    },
    "direction": 1,
    "sectors": [],
    "source": "https://www.openstreetmap.org/node/13826373967",
    "confidence": "unverified",
    "note": "OSM node 13826373967 (name=\"Finish Line\") at 30.1335372, -97.64225 lies on highway=raceway way 118258939. Bearing of the way between neighbor nodes 1330333594 and 7909207460 = 128.1 deg; a and b are the node offset 10 m each way perpendicular (bearing 38.1 / 218.1 deg), great-circle on a 6371008.8 m sphere. Gate endpoints are derived, not mapped; the node itself may not be at track center. Way: https://www.openstreetmap.org/way/118258939. Direction: Bearing about 128.1 deg (from the OSM way direction with oneway=yes; mapper-asserted, not checked against official track documentation); stored as +1 (travel along the way bearing). Oneway bearing re-verified against OSM on 2026-10-17 (still mapper data, not track documentation). COTA has two candidate OSM lines; prefer the raceway=start-finish node 7909207460 (Grand Prix Circuit) over the node named \"Finish Line\" (13826373967). Derived and unverified: confirm on-site."
  },
  {
    "id": "lime-rock-park--grand-prix-circuit",
    "trackId": "lime-rock-park",
    "configuration": "Grand Prix Circuit",
    "a": {
      "lat": 41.9286817,
      "lon": -73.3809603
    },
    "b": {
      "lat": 41.9285173,
      "lon": -73.3810585
    },
    "direction": 1,
    "sectors": [],
    "source": "https://www.openstreetmap.org/node/4314687370",
    "confidence": "unverified",
    "note": "OSM node 4314687370 (name=\"S/F Line\") at 41.9285995, -73.3810094 lies on highway=raceway way 293189369 ('Sam Posey Straight'). Bearing of the way between neighbor nodes 178375033 and 414255318 = 114.0 deg; a and b are the node offset 10 m each way perpendicular (bearing 24.0 / 204.0 deg), great-circle on a 6371008.8 m sphere. Gate endpoints are derived, not mapped; the node itself may not be at track center. Way: https://www.openstreetmap.org/way/293189369. Direction: Bearing about 114.0 deg (from the OSM way direction with oneway=yes; mapper-asserted, not checked against official track documentation); stored as +1 (travel along the way bearing). Oneway bearing re-verified against OSM on 2026-10-17 (still mapper data, not track documentation). Derived and unverified: confirm on-site."
  },
  {
    "id": "road-america--grand-prix-course",
    "trackId": "road-america",
    "configuration": "Grand Prix Course",
    "a": {
      "lat": 43.7978972,
      "lon": -87.9895036
    },
    "b": {
      "lat": 43.7978936,
      "lon": -87.9897528
    },
    "direction": 1,
    "sectors": [],
    "source": "https://www.openstreetmap.org/node/4317202676",
    "confidence": "unverified",
    "note": "OSM node 4317202676 (name=\"Road America S/F Line\") at 43.7978954, -87.9896282 lies on highway=raceway way 122090289 ('Road America Straight'). Bearing of the way between neighbor nodes 1262000220 and 1261999916 = 178.8 deg; a and b are the node offset 10 m each way perpendicular (bearing 88.8 / 268.8 deg), great-circle on a 6371008.8 m sphere. Gate endpoints are derived, not mapped; the node itself may not be at track center. Way: https://www.openstreetmap.org/way/122090289. Direction: Bearing about 178.8 deg (from the OSM way direction with oneway=yes; mapper-asserted, not checked against official track documentation); stored as +1 (travel along the way bearing). Oneway bearing re-verified against OSM on 2026-10-17 (still mapper data, not track documentation). Derived and unverified: confirm on-site."
  },
  {
    "id": "thunderhill-raceway-park--east-circuit",
    "trackId": "thunderhill-raceway-park",
    "configuration": "East Circuit",
    "a": {
      "lat": 39.538477,
      "lon": -122.3310619
    },
    "b": {
      "lat": 39.5384758,
      "lon": -122.3312951
    },
    "direction": 1,
    "sectors": [],
    "source": "https://www.openstreetmap.org/node/316914551",
    "confidence": "unverified",
    "note": "OSM node 316914551 (description=\"Start/Finish (East)\") at 39.5384764, -122.3311785 lies on highway=raceway way 28825115 ('Thunderhill Raceway'). Bearing of the way between neighbor nodes 9375286052 and 316914552 = 179.6 deg; a and b are the node offset 10 m each way perpendicular (bearing 89.6 / 269.6 deg), great-circle on a 6371008.8 m sphere. Gate endpoints are derived, not mapped; the node itself may not be at track center. Way: https://www.openstreetmap.org/way/28825115. Direction: Bearing about 179.6 deg (from the OSM way direction with oneway=yes; mapper-asserted, not checked against official track documentation); stored as +1 (travel along the way bearing). Oneway bearing re-verified against OSM on 2026-10-17 (still mapper data, not track documentation). Derived and unverified: confirm on-site."
  },
  {
    "id": "thunderhill-raceway-park--west-circuit",
    "trackId": "thunderhill-raceway-park",
    "configuration": "West Circuit",
    "a": {
      "lat": 39.5374439,
      "lon": -122.3389123
    },
    "b": {
      "lat": 39.5374649,
      "lon": -122.3386807
    },
    "direction": 1,
    "sectors": [],
    "source": "https://www.openstreetmap.org/node/9372293077",
    "confidence": "unverified",
    "note": "OSM node 9372293077 (description=\"Start/Finish (West)\") at 39.5374544, -122.3387965 lies on highway=raceway way 756822999 ('Thunderhill Raceway'). Bearing of the way between neighbor nodes 9375286057 and 9375286058 = 353.3 deg; a and b are the node offset 10 m each way perpendicular (bearing 263.3 / 83.3 deg), great-circle on a 6371008.8 m sphere. Gate endpoints are derived, not mapped; the node itself may not be at track center. Way: https://www.openstreetmap.org/way/756822999. Direction: Bearing about 353.3 deg (from the OSM way direction with oneway=yes; mapper-asserted, not checked against official track documentation); stored as +1 (travel along the way bearing). Oneway bearing re-verified against OSM on 2026-10-17 (still mapper data, not track documentation). Derived and unverified: confirm on-site."
  }
];

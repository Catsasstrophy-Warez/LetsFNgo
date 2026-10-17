# Round 9: Track database, Track Attack, competitor MSRPs, awards

## Track database (29 tracks)
### Takeaway
Lengths, layouts and coordinates come from each track's English Wikipedia infobox, pulled with the MediaWiki API on 2026-10-17. **None of the coordinates is a start/finish line.** Wikipedia gives one facility-level point, accurate to roughly 1 to 100 m. Precision varies: Watkins Glen, Mid-Ohio, Sebring and Atco have only 2 to 3 decimals, about 100 m to 1 km. A lap timer needs the start/finish gate captured from OSM or surveyed on site; startFinishLat/Lon are null everywhere.
### Cited Findings
| Track | Config (primary) | mi | City, ST | Lat, Lon (facility) | Type | Conf |
|---|---|---|---|---|---|---|
| [WeatherTech Raceway Laguna Seca](https://en.wikipedia.org/wiki/Laguna_Seca) | Grand Prix Circuit (1996-present) | 2.238 | Monterey County (near Monterey/Salinas), CA | 36.58416667, -121.75361111 | road course | medium |
| [Virginia International Raceway](https://en.wikipedia.org/wiki/Virginia_International_Raceway) | Full Course; also Grand East/Grand West/North/South/Patriot | 3.27 | Alton, VA | 36.56166667, -79.20472222 | road course | medium |
| [Road America](https://en.wikipedia.org/wiki/Road_America) | Grand Prix Course | 4.048 | Elkhart Lake / Town of Plymouth, WI | 43.7975, -87.99388889 | road course | medium |
| [Circuit of the Americas](https://en.wikipedia.org/wiki/Circuit_of_the_Americas) | Grand Prix Circuit; also National, NASCAR | 3.426 | Austin, TX | 30.13277778, -97.64111111 | road course | medium |
| [Watkins Glen International](https://en.wikipedia.org/wiki/Watkins_Glen_International) | Grand Prix Circuit with Inner Loop; also Short Circuit | 3.45 | Watkins Glen, NY | 42.337, -76.927 | road course | medium |
| [Sebring International Raceway](https://en.wikipedia.org/wiki/Sebring_International_Raceway) | GP Road Course; also School and Johnson Club circuits | 3.741 | Sebring (Highlands County), FL | 27.455, -81.35 | road course | medium |
| [Michelin Raceway Road Atlanta](https://en.wikipedia.org/wiki/Road_Atlanta) | Grand Prix Circuit (1998-present) | 2.54 | Braselton area (Hall County), GA | 34.14666667, -83.81777778 | road course | medium |
| [Thunderhill Raceway Park](https://en.wikipedia.org/wiki/Thunderhill_Raceway_Park) | East Circuit; also West and Five Mile | 2.866 | Willows (Glenn County), CA | 39.54033333, -122.33069444 | road course | medium |
| [Buttonwillow Raceway Park](https://en.wikipedia.org/wiki/Buttonwillow_Raceway_Park) | Race #13 CW; also #14 CW and others | 3.0 | Buttonwillow, CA | 35.49130556, -119.54494444 | road course | medium |
| [Willow Springs International Motorsports Park](https://en.wikipedia.org/wiki/Willow_Springs_International_Motorsports_Park) | Big Willow; also Streets of Willow, Horse Thief Mile | 2.5 | Rosamond (Kern County), CA | 34.875, -118.26444444 | road course | medium |
| [Sonoma Raceway](https://en.wikipedia.org/wiki/Sonoma_Raceway) | Long Circuit; also IndyCar, Club; on-site drag strip | 2.52 | Sonoma, CA | 38.16083333, -122.455 | road course + drag strip | medium |
| [Mid-Ohio Sports Car Course](https://en.wikipedia.org/wiki/Mid-Ohio_Sports_Car_Course) | Second Road Course (1990-present) | 2.258 | Lexington area (Troy Twp, Morrow County), OH | 40.69, -82.636 | road course | medium |
| [Barber Motorsports Park](https://en.wikipedia.org/wiki/Barber_Motorsports_Park) | Grand Prix Circuit | 2.38 | Birmingham, AL | 33.5325, -86.618889 | road course | medium |
| [NOLA Motorsports Park](https://en.wikipedia.org/wiki/NOLA_Motorsports_Park) | A Course; also 13-turn A, B, C | 2.748 | Avondale, LA | 29.88361111, -90.19777778 | road course | medium |
| [Charlotte Motor Speedway (Roval / Ford Performance Racing School)](https://en.wikipedia.org/wiki/Charlotte_Motor_Speedway) | Quad Oval 1.5 mi; Roval (length not extracted) | None | Concord, NC | 35.3525, -80.6825 | oval + road course | medium |
| [zMAX Dragway](https://en.wikipedia.org/wiki/Charlotte_Motor_Speedway) | Drag strip (part of CMS complex) | None | Concord, NC | None, None | drag strip | low |
| [Gainesville Raceway](https://en.wikipedia.org/wiki/Gainesville_Raceway) | Drag Strip | 0.25 | Gainesville, FL | 29.75805556, -82.27472222 | drag strip | medium |
| [In-N-Out Burger Pomona Dragstrip (Auto Club Raceway at Pomona)](https://en.wikipedia.org/wiki/In-N-Out_Burger_Pomona_Dragstrip) | Drag Strip | 0.25 | Pomona, CA | 34.09508889, -117.76976389 | drag strip | medium |
| [Atco Dragway](https://en.wikipedia.org/wiki/Atco_Dragway) | Drag Strip | 0.25 | Atco, NJ | 39.775, -74.83 | drag strip | medium |
| [Texas Motorplex](https://en.wikipedia.org/wiki/Texas_Motorplex) | Drag Strip | 0.25 | Ennis, TX | 32.3286, -96.7174 | drag strip | medium |
| [Lime Rock Park](https://en.wikipedia.org/wiki/Lime_Rock_Park) | Grand Prix Circuit | 1.53 | Lakeville, CT | 41.92768889, -73.38359722 | road course | medium |
| [Pittsburgh International Race Complex](https://en.wikipedia.org/wiki/Pittsburgh_International_Race_Complex) | Full Circuit; also North, South | 2.78 | Wampum, PA | 40.84897611, -80.34215889 | road course | medium |
| [Summit Point Motorsports Park](https://en.wikipedia.org/wiki/Summit_Point_Motorsports_Park) | Main Circuit; also Jefferson, Shenandoah | 2.0 | Summit Point, WV | 39.23438889, -77.97528889 | road course | medium |
| [Carolina Motorsports Park](https://en.wikipedia.org/wiki/Carolina_Motorsports_Park) | Full Circuit; also East, West | 2.279 | Kershaw, SC | 34.4876614, -80.5969722 | road course | medium |
| [Brainerd International Raceway](https://en.wikipedia.org/wiki/Brainerd_International_Raceway) | Competition Road Course; also Donnybrooke; drag strip | 2.5 | Brainerd, MN | 46.417069, -94.273142 | road course + drag strip | medium |
| [Utah Motorsports Campus](https://en.wikipedia.org/wiki/Utah_Motorsports_Campus) | Full Course; also Outer, East, West | 4.486 | Grantsville, UT | 40.575, -112.37472222 | road course | medium |
| [New Jersey Motorsports Park](https://en.wikipedia.org/wiki/New_Jersey_Motorsports_Park) | Thunderbolt Raceway; also Lightning | 2.25 | Millville, NJ | 39.35896944, -75.06162778 | road course | medium |
| [Las Vegas Motor Speedway](https://en.wikipedia.org/wiki/Las_Vegas_Motor_Speedway) | Tri-Oval 1.5 mi; road courses; on-site drag strip | 1.5 | Las Vegas, NV | 36.27134, -115.01112 | oval + road course + drag strip | medium |
| [Chuckwalla Valley Raceway](https://en.wikipedia.org/wiki/Chuckwalla_Valley_Raceway) | Combined track | 2.68 | Desert Center, CA | 33.75361111, -115.31972222 | road course | medium |

### Gaps
- Start/finish coordinates: none sourced. Next step: OSM `highway=raceway` / timing-line nodes.
- zMAX Dragway: no separate Wikipedia article; coordinates null. Charlotte Roval length was not extracted from the infobox (layout list only).
- Infobox lengths may differ slightly from track-published figures. Track websites were not checked.

## Gap fills
### Cited Findings
- **GT500 Track Attack years/eligibility**: Free one-day program at Ford Performance Racing School, Charlotte Motor Speedway, for 2020+ Shelby GT500 owners. Ended after the GT500 was discontinued following MY2022 and was replaced by Dark Horse Track Attack. No official per-MY (2021/2022) eligibility text found. [source](https://fordauthority.com/2024/01/ford-mustang-dark-horse-track-attack-registration-now-open) (medium (secondary; search snippets))
- **MotorTrend Best Driver's Car 2020 winner**: Porsche 718 Cayman GT4. Field: C8 Z51, F8 Tributo, GT500, Huracan Evo, 911 Turbo S, Cayenne Turbo Coupe, Cayman GT4 [source](https://www.rennlist.com/how-tos/slideshows/porsche-718-cayman-gt4-pros-and-cons-623189) (medium)
- **GT500 final placement in MT BDC 2020**: null (unsourced; did not win; MotorTrend publishes no full ranking)
- **Car and Driver 10Best 2020 GT500**: null (unsourced; no C&D page found)

## Competitor base MSRPs
### Cited Findings
- 2020 Chevrolet Corvette Stingray 1LT: $59,995 (incl. $1,095 destination) [source](https://www.musclecarsandtrucks.com/2020-corvette-stingray-price-officially-revealed-pre-orders-open/) (high (GM announced; secondary report))
- 2023 Chevrolet Corvette Z06 1LZ coupe: $106,395 (incl. $1,395 destination) [source](https://www.hagerty.com/media/news/2023-chevrolet-corvette-c8-z06-pricing-announced/) (high)
- 2020 Porsche 911 Carrera S coupe: $113,300 (excl. $1,250 destination (TFL cites $113,200)) [source](https://www.cars.com/research/porsche-911-2020/specs/405360) (medium)
- 2022 Porsche 911 Carrera S: $117,100 (Porsche MY22 price table) [source](https://newsroom.porsche.com/en_US/2021/products/2022-porsche-911-gt3-pricing-updates-24060.html) (high)
- 2022 Porsche 911 GT3: $161,100 (excl. $1,350 delivery) [source](https://newsroom.porsche.com/en_US/2021/products/2022-porsche-911-gt3-pricing-updates-24060.html) (high)
- 2021 Chevrolet Camaro ZL1: $63,000 (base, excl. destination) [source](https://www.truedelta.com/Dodge-Challenger-vs-Chevrolet-Camaro-price-comparison,819-499,2018-2021) (medium)
- 2021 Dodge Challenger SRT Hellcat Redeye: $71,750 (Widebody $77,750; dest $1,495) [source](https://www.iseecars.com/car/2021-dodge-challenger-price) (medium-low)
- 2021 Dodge Challenger SRT Super Stock: $79,595 (excl. destination (iSeeCars lists $80,750)) [source](https://www.thedrive.com/news/35681/2021-dodge-challenger-srt-super-stock-with-807-hp-v8-starts-at-79595) (medium)
- 2020/2022 Camaro ZL1; ZL1 1LE (all years): null (not found)  (null)
- Challenger SRT Hellcat (2020-22), Jailbreak, Redeye 2020/2022: null (not found)  (null)

### Gaps
- Camaro ZL1 for 2020/2022, ZL1 1LE, Challenger Hellcat, Jailbreak, and Redeye for 2020/2022 are unsourced. The C8 Z06 price is for the 2023 model (there was no 2020-22 C8 Z06). Destination inclusion is inconsistent across sources, as noted per row.

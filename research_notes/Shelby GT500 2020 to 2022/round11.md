# Round 11: start/finish lines, competitor MSRPs, OBD-II PIDs

Research date 2026-10-17. Values appear only where a source gives them.

## 1. Start/finish lines (no new lines)
- I retried Overpass on 2026-10-17 with a CONUS-wide query: nodes whose raceway, name or description tags match start/finish/timing. None of the mirrors returned data:
  - overpass.private.coffee: HTTP 500 for POST, GET and a trivial test query.
  - overpass.kumi.systems: HTTP 500.
  - maps.mail.ru: HTTP 504.
  - overpass-api.de: connection reset.
- No official track map or timing document giving start/finish coordinates turned up for any of the 22 tracks.
- `startFinishLines` is empty. The round10 "nothing found" list stands: VIR, Watkins Glen, Sebring, Road Atlanta, Buttonwillow, Willow Springs, Sonoma, Mid-Ohio, Barber, NOLA, Summit Point, NJMP, Pittsburgh, Utah MC, Carolina MP, Brainerd, LVMS, Pomona, Gainesville, Atco, Texas Motorplex, zMAX.
- Next step: rerun the query when a mirror is up. Any lines found would need the round10 derivation method, unverified confidence and the ODbL attribution ("© OpenStreetMap contributors", ODbL 1.0).

## 2. Competitor prices
| Model | MY | Price (USD) | Basis | Source | Confidence |
|---|---|---|---|---|---|
| Camaro ZL1 coupe | 2020 | 63,000 | Base MSRP, excludes destination (convertible 69,000) | cars.com 2020 Camaro specs | medium (aggregator) |
| Camaro ZL1 coupe, 6MT | 2022 | 64,395 | MSRP including $1,395 destination | GM Authority, May 2022, via search snippet (page returned 403) | medium |
| ZL1 1LE package | 2018 launch | 7,500 | Package price | Autoblog; Chevy Hardcore | high for 2018; unconfirmed for 2020-2022 |
| ZL1 1LE package | 2020-2022 | not found | — | Only a used-listing mention of $7,500 for 2020 | gap |
| Challenger SRT Hellcat | 2020 | 58,995 | Base MSRP; $1,495 destination per iSeeCars | iSeeCars; CarGurus | medium |
| Challenger SRT Hellcat Redeye | 2020 | 70,595 | Base MSRP (Redeye Widebody 76,595 per CarGurus) | iSeeCars; CarGurus | medium |
| Challenger SRT Hellcat Redeye Widebody | 2021 | 81,060 | Starting price as reported | Fox News | medium |
| Jailbreak package | 2022 | 995 | Option MSRP added to Redeye Widebody | Stellantis release, 2021-12-10 (newsrelease.do?id=23338) | high |
| Jailbreak | 2021 | none | The Jailbreak debuted for MY2022, so there is no 2021 Jailbreak | Stellantis release | high |
| Hellcat 2021/2022; Redeye 2022 | — | not found | — | — | gap |

## 3. OBD-II PIDs (SAE J1979 Mode 01)
The PID definitions below are the standard SAE J1979 ones; the app should apply the formulas exactly as given. I found no source confirming which of these PIDs the 2020-2022 GT500 PCM actually reports, so support is unverified for every one. The app should read support bitmaps PID 0x00, 0x20, 0x40 and 0x60 at connect and show only the gauges the car reports.

| PID | Parameter | Formula | GT500 support |
|---|---|---|---|
| 0x0C | Engine RPM | (256A+B)/4 | unverified; likely, since emissions-required on all OBD-II cars |
| 0x0D | Vehicle speed | A km/h | unverified; likely, same reason |
| 0x05 | Coolant temperature | A-40 °C | unverified; likely |
| 0x0F | Intake air temperature | A-40 °C | unverified; likely |
| 0x0B | Intake manifold absolute pressure | A kPa | unverified. Boost = MAP minus barometric pressure (PID 0x33). The one-byte value tops out at 255 kPa. |
| 0x11 | Throttle position | 100A/255 % | unverified; likely |
| 0x5C | Engine oil temperature | A-40 °C | unverified and doubtful. An HP Tuners thread says the 2017 GT350 5.2L has no oil temperature PID. Explorer ST and Ranger owners could not get oil temperature with an OBDLink MX+ or FORScan. |

Other notes:
- A 2009 GT500 owner found Torque Pro's boost reading did not match the factory gauge (TTAC Piston Slap). It is an old platform, but it supports treating app-computed boost as approximate.
- Ford-enhanced (Mode 22) PIDs need OEM-specific definitions. OBDLink says OEM PID access is not guaranteed.
- BLE ELM327 adapter caveats are general knowledge, not GT500-specific sources:
  - Cheap clones may misreport their firmware version.
  - iOS needs BLE (GATT) adapters, not Bluetooth Classic SPP.
  - Polling many PIDs lowers the refresh rate per gauge.

## Sources
- https://media.stellantisnorthamerica.com/newsrelease.do?id=23338
- https://www.foxnews.com/auto/dodge-challenger-charger-muscle-cars-jailbreak
- https://www.iseecars.com/car/2020-dodge-challenger-price
- https://www.cargurus.ca/Cars/2020-Dodge-Challenger-Value-c29713
- https://www.cars.com/research/chevrolet-camaro-2020/specs/407671/
- https://gmauthority.com/blog/2022/05/2022-chevy-camaro-gets-200-price-increase/
- https://www.autoblog.com/tag/camaro+1le/
- https://www.chevyhardcore.com/?p=1095874
- https://forum.hptuners.com/showthread.php?p=864663
- https://www.thetruthaboutcars.com/2014/09/piston-slap-6
- https://www.explorerst.org/goto/post?id=128604
- https://support.obdsol.com/en/support/solutions/articles/43000708843
- https://en.wikipedia.org/wiki/OBD-II_PIDs (standard PID formulas)

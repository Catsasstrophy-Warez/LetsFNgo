# Round 13: owner supplements, production, pricing, recall 25V455
Date: 2026-10-17. Machine-readable data is in round13.json. Confidence: high = confirmed, medium = reported, low = unverified.

## Found
- **25V455 (Ford 25S75)**, from the NHTSA API (high):
  - Total population is 850,318. NHTSA lists both MY2021 and MY2022 Mustang.
  - Remedy: a PCM software update for non-Super Duty vehicles.
  - The NHTSA record reads "Owner notification letters were mailed July 27, 2026." That is quoted as given.
  - Source: https://api.nhtsa.gov/recalls/campaignNumber?campaignNumber=25V455
- **25V455 Mustang scope** (medium): TFL lists "2021-2022 Ford Mustang GT (5.0L V8; 24,790 units)". It does not mention the GT500. GT500 inclusion is still unconfirmed.
  - Source: https://tfltruck.com/2025/07/ford-recall-fuel-pump-trucks-suv-news/
  - Note: recallsByVehicle for MUSTANG 2021 returned 6 recalls, and 25V455 was not among them. The campaign endpoint still lists Mustang. Treat this as unresolved.
- **Destination charge**, all medium:
  - 2020: $1,095. Source: https://www.motor1.com/news/370086/most-expensive-mustang-shelby-gt500/
  - 2021 and 2022: $1,195, from a Ford Authority price table seen in a search summary. The page itself returned 403.
  - Source: https://fordauthority.com/2022/02/2022-ford-mustang-shelby-gt500-gets-six-percent-price-increase
- **Handling Package**, 2020, $1,500 (medium):
  - Contents: adjustable strut top mounts (installed at plant), catch can, Gurney flap, splitter wickers. The flap and wickers ship loose. Ford Authority's table also lists a wheel lock kit.
  - Sources:
    - https://www.musclecarsandtrucks.com/2021-ford-mustang-shelby-gt500-carbon-fiber-handling-package-costs-10000/
    - https://fordauthority.com/2021/11/2022-ford-mustang-shelby-gt500-drops-carbon-fiber-handling-package/
- **Carbon Fiber Handling Package**, 2021 only, $10,000 (medium):
  - Contents: black-painted CF 20-inch wheels, adjustable strut top mounts, catch can, Gurney flap, wickers, wheel locks.
  - Dropped for 2022.
  - Sources: the Ford Authority 2021/01 and 2021/11 articles.
- **2021 Technology Package**, $3,000 (medium, dealer listing): B&O 12-speaker audio, BLIS with cross-traffic alert, navigation.
  - Sources:
    - https://www.americanmusclecarz.com/vehicles/20512/2021-ford-shelby-mustang-gt500-carbon-fiber-track-pack
    - https://www.stlouiscarmuseum.com/vehicles/1075/2021-ford-shelby-mustang-gt500-carbon-fiber-track-pack
- **Recaro seats**, 2020, $1,595 (medium). Source: https://www.motor1.com/news/370086/most-expensive-mustang-shelby-gt500/
- **2022 Heritage stripes** (medium): vinyl Wimbledon White $2,140; painted $12,140. Source: https://theshopmag.com/features/ford-expands-mustang-lineup-with-coastal-gt500-heritage-editions/
- **Tire pressure** (low): 32 psi front and rear. This is a third-party site, not the placard. Source: https://tirepressure.com/2022-ford-mustang-tire-pressure

## Conflicts
- **Heritage Edition count:**
  - 225, from MustangSpecs: https://www.mustangspecs.com/?p=64873
  - About 255, from Barrett-Jackson: https://barrett-jackson.com/Events/Event/Details/2022-FORD-SHELBY-GT500-HERITAGE-EDITION-266929
  - Both are medium. Neither is a Ford figure.
- **Carbon Fiber Track Package price:**
  - $18,500, from 2021 dealer listings.
  - $18,900, from leaked 2020 guide coverage: https://www.thedrive.com/news/29420/2020-ford-mustang-shelby-gt500-weighs-223-pounds-less-than-challenger-hellcat-leak-claims
  - The difference may be model year rather than an error. Both are medium.
- **Curb weight:**
  - 4,225 lb, from the leaked dealer eSourceBook. Low: Ford declined to confirm. Source: https://www.thedrive.com/news/29420/2020-ford-mustang-shelby-gt500-weighs-223-pounds-less-than-challenger-hellcat-leak-claims
  - 4,080 lb, Motor1 scale weight with the Handling Package. Medium. Source: https://www.motor1.com/news/386412/2020-shelby-gt500-weight/
  - Still no Ford-published figure.

## Not found
- 2020 and 2022 owner supplements: no fluids, intervals, break-in text or placard pressures.
- 2021 and 2022 production totals, and color or package splits. A forum notes that no 2021 breakdown exists.
- Wimbledon White paint code. The N4 code stays low confidence.
- 2021 prices for stripes, Convenience Package and Recaro seats, from a window sticker.
- GT500 VIN applicability for 25V455.

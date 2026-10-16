import type { SpecFact } from './types';

const WIKI = 'https://en.wikipedia.org/wiki/Shelby_Mustang';
const TREMEC = 'https://tremec.com/?p=407';
const FA_ENGINE = 'https://fordauthority.com/2019/06/2020-shelby-gt500-predator-engine-details-surface/amp';
const MA_DEEP = 'https://www.motorauthority.com/news/1124390_2020-ford-mustang-shelby-gt500-specs-deep-dive';
const ENCY = 'https://www.encycarpedia.com/us/ford/20-mustang-shelby-gt500-coupe';
const CARADVICE = 'https://www.caradvice.com.au/781402/2020-ford-mustang-shelby-gt500-details/';

/** One spec sheet covers 2020-2022: the mechanicals did not change across model years. */
export const specs: SpecFact[] = [
  { id: 'engine', system: 'Engine', label: 'Engine', value: '5.2L "Predator" hand-built cross-plane V8, supercharged', source: WIKI, confidence: 'confirmed' },
  { id: 'supercharger', system: 'Engine', label: 'Supercharger', value: '2.65L Eaton TVS R2650 Roots', source: WIKI, confidence: 'confirmed' },
  { id: 'hp', system: 'Engine', label: 'Horsepower', value: 760, unit: 'hp @ 7,300 rpm', source: CARADVICE, confidence: 'confirmed' },
  { id: 'tq', system: 'Engine', label: 'Torque', value: 625, unit: 'lb-ft @ 5,000 rpm', source: CARADVICE, confidence: 'confirmed' },
  { id: 'redline', system: 'Engine', label: 'Redline', value: 7500, unit: 'rpm', source: TREMEC, confidence: 'confirmed' },
  { id: 'compression', system: 'Engine', label: 'Compression ratio', value: '9.5:1', source: TREMEC, confidence: 'confirmed' },
  { id: 'boost', system: 'Engine', label: 'Max boost', value: 12, unit: 'psi (approx.)', source: FA_ENGINE, confidence: 'reported' },
  { id: 'intercooler', system: 'Engine', label: 'Intercooler', value: 'Bar-and-plate, above the rotors', source: 'https://themustangsource.com/?p=31080', confidence: 'reported' },
  { id: 'bore-stroke', system: 'Engine', label: 'Bore × stroke', value: null, source: 'https://www.cjponyparts.com/resources/news/2020-shelby-gt500', confidence: 'unverified', note: 'Not verified — source page was blocked during research.' },
  { id: 'trans', system: 'Drivetrain', label: 'Transmission', value: 'Tremec TR-9070 7-speed dual-clutch', source: 'https://whichcar.com.au/news/2020-ford-mustang-shelby-gt500-performance-figures', confidence: 'confirmed' },
  {
    id: 'shift', system: 'Drivetrain', label: 'Shift time', value: '< 100', unit: 'ms', source: TREMEC, confidence: 'confirmed', context: 'TREMEC',
    conflicts: [
      { value: '< 100 ms', source: TREMEC, confidence: 'confirmed', context: 'TREMEC' },
      { value: '80 ms', source: TREMEC, confidence: 'reported', context: 'Other press coverage' },
    ],
  },
  { id: 'gear-ratios', system: 'Drivetrain', label: 'Gear ratios (1–7, R)', value: '3.14 / 2.05 / 1.43 / 1.10 / 0.86 / 0.68 / 0.56 · R 2.76', source: 'https://tremec.com/wp-content/uploads/2023/05/Product.Sheet_TR-9070.DCT_.pdf', confidence: 'confirmed', note: 'TREMEC product sheet "Ratio A". A Ford owner-manual search snippet reportedly matches 1st, 2nd, 7th and reverse.' },
  { id: 'clutch-packs', system: 'Drivetrain', label: 'DCT clutch packs', value: '5 friction plates (odd gears) / 6 (even gears)', source: 'https://theshopmag.com/features/behind-the-raw-power-driving-the-shelby-gt500', confidence: 'reported' },
  { id: 'clutch-rating', system: 'Drivetrain', label: 'DCT clutch torque rating', value: '≈ 664–700', unit: 'lb-ft', source: 'https://www.mustang6g.com/forums/threads/dct-performance.128063/post-2650750', confidence: 'unverified', note: 'Forum posts only; no Ford/TREMEC figure found.' },
  { id: 'diff', system: 'Drivetrain', label: 'Differential', value: '3.73:1 Torsen limited-slip', source: CARADVICE, confidence: 'confirmed' },
  { id: 'launch', system: 'Drivetrain', label: 'Launch control', value: 'Selectable 1,200–3,200 rpm', source: 'https://www.carscoops.com/2019/12/bone-stock-2020-ford-mustang-shelby-gt500-runs-the-quarter-mile-in/', confidence: 'reported' },
  { id: 'brakes-f', system: 'Chassis & Brakes', label: 'Front brakes', value: 'Brembo 6-piston, 420 mm (16.5 in) two-piece rotors', source: MA_DEEP, confidence: 'reported' },
  { id: 'brakes-r', system: 'Chassis & Brakes', label: 'Rear brakes', value: 'Brembo 4-piston, 370 mm (14.5 in) rotors', source: MA_DEEP, confidence: 'reported' },
  { id: 'magneride', system: 'Chassis & Brakes', label: 'MagneRide calibration / spring rates', value: null, source: WIKI, confidence: 'unverified', note: 'Not confirmed by any source.' },
  { id: 'tires', system: 'Wheels & Tires', label: 'Tires', value: 'Michelin Pilot Sport 4S (Pilot Sport Cup 2 with CFTP)', source: WIKI, confidence: 'confirmed' },
  { id: 'tire-f', system: 'Wheels & Tires', label: 'Front tire size', value: '305/30R20', source: WIKI, confidence: 'confirmed' },
  { id: 'tire-r', system: 'Wheels & Tires', label: 'Rear tire size', value: '315/30R20', source: 'https://www.pistonheads.com/buy/listing/10496139', confidence: 'reported', note: 'From a listing; not yet confirmed by a Ford spec sheet.' },
  { id: 'wheels', system: 'Wheels & Tires', label: 'Wheel sizes', value: '20×11 front / 20×11.5 rear', source: 'https://www.pistonheads.com/buy/listing/10496139', confidence: 'reported' },
  { id: 'wheelbase', system: 'Dimensions & Weight', label: 'Wheelbase', value: 107.1, unit: 'in', source: WIKI, confidence: 'confirmed' },
  { id: 'length', system: 'Dimensions & Weight', label: 'Length', value: 190.2, unit: 'in', source: WIKI, confidence: 'confirmed' },
  { id: 'width', system: 'Dimensions & Weight', label: 'Width', value: '76.6 (81.9 with mirrors)', unit: 'in', source: WIKI, confidence: 'confirmed' },
  { id: 'height', system: 'Dimensions & Weight', label: 'Height', value: 54.3, unit: 'in', source: WIKI, confidence: 'confirmed' },
  {
    id: 'curb-weight', system: 'Dimensions & Weight', label: 'Curb weight', value: '4,006–4,225', unit: 'lb', source: MA_DEEP, confidence: 'reported',
    note: 'Sources conflict. 4,225 lb has the most authoritative origin; shown as a range until a Ford spec sheet confirms one number.',
    conflicts: [
      { value: 4225, source: MA_DEEP, confidence: 'reported', context: 'Dealer training manual' },
      { value: 4182, source: ENCY, confidence: 'reported', context: 'Spec databases' },
      { value: 4006, source: ENCY, confidence: 'unverified', context: 'Some listings' },
    ],
  },
  { id: 'top-speed', system: 'Dimensions & Weight', label: 'Top speed', value: 180, unit: 'mph (electronically limited)', source: 'https://www.motorauthority.com/news/1125737_first-drive-review-2020-ford-mustang-shelby-gt500-boasts-drag-car-speed-road-racer-moves', confidence: 'reported' },
  { id: 'mpg', system: 'Fuel & Economy', label: 'EPA fuel economy', value: '12 city / 18 hwy / 14 combined', unit: 'mpg', source: ENCY, confidence: 'reported' },
  { id: 'tank', system: 'Fuel & Economy', label: 'Fuel tank', value: 16, unit: 'gal (approx.)', source: ENCY, confidence: 'reported' },
  { id: 'speedo', system: 'Features', label: 'Speedometer', value: '220 mph cluster', source: 'https://www.vanguardmotorsales.com/inventory/5310/2020-ford-mustang-shelby-gt500', confidence: 'reported' },
  { id: 'line-lock', system: 'Features', label: 'Launch control & line lock', value: 'Standard', source: 'https://www.vanguardmotorsales.com/inventory/5310/2020-ford-mustang-shelby-gt500', confidence: 'reported' },
  { id: 'drive-modes', system: 'Features', label: 'Drive modes', value: 'Normal · Weather · Sport · Drag · Track', source: 'https://blog.consumerguide.com/shelby-gt500-gallery/', confidence: 'reported', note: 'Track: stiffer steering, firmer MagneRide, most aggressive shift program (Motor Authority). Drag: launch control. Normal/Weather/Sport effects not documented. MyMode and Track Apps contents not confirmed.' },
  { id: 'drag-mode', system: 'Features', label: 'Drag mode', value: 'Launch control (left-foot brake + full throttle)', source: 'https://fox11online.com/news/auto-matters/2020-ford-mustang-shelby-gt500-ford-delivers-fastest-production-mustang-ever-first-look', confidence: 'reported' },
  { id: 'track-mode', system: 'Features', label: 'Track mode', value: 'Stiffer steering, firmer MagneRide, most aggressive shifts', source: 'https://www.motorauthority.com/news/1125737_first-drive-review-2020-ford-mustang-shelby-gt500-boasts-drag-car-speed-road-racer-moves', confidence: 'reported' },
  { id: 'exhaust-modes', system: 'Features', label: 'Exhaust modes (active valves)', value: 'Quiet · Normal · Sport · Track', source: 'https://www.carscoops.com/?p=1770890', confidence: 'reported' },
  { id: 'plant', system: 'Features', label: 'Assembly plant', value: 'Flat Rock, Michigan', source: WIKI, confidence: 'confirmed' },
];

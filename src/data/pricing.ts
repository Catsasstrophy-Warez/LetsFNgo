import type { MarketSale, PriceRecord } from './types';

const JALOP = 'https://jalopnik.com/the-2020-ford-mustang-shelby-gt500-will-start-at-70-30-1835940835';
const CS22 = 'https://www.carscoops.com/?p=2394782';

export const prices: PriceRecord[] = [
  { id: 'p20-base', year: 2020, label: 'Base MSRP', kind: 'msrp', value: 70300, source: JALOP, confidence: 'confirmed' },
  { id: 'p20-dest', year: 2020, label: 'Destination', kind: 'destination', value: 1095, source: JALOP, confidence: 'confirmed' },
  { id: 'p20-gg', year: 2020, label: 'Gas guzzler tax', kind: 'gas-guzzler', value: 2600, source: JALOP, confidence: 'confirmed' },
  { id: 'p20-del', year: 2020, label: 'Delivered base price', kind: 'delivered', value: 73995, source: 'https://www.motorauthority.com/news/1125770_how-the-2020-ford-mustang-shelby-gt500-tops-100-000', confidence: 'confirmed', note: 'Hagerty quoted $74,095 ($100 difference, possibly a destination change).' },
  { id: 'p20-loaded', year: 2020, label: 'Fully loaded', kind: 'delivered', value: 107080, source: 'https://www.motor1.com/news/370086/most-expensive-mustang-shelby-gt500/', confidence: 'reported' },
  { id: 'p20-cd', year: 2020, label: 'Car and Driver as-tested', kind: 'as-tested', value: 94665, source: 'https://fordauthority.com/2020/01/2020-ford-mustang-shelby-gt500-v-2019-chevrolet-camaro-zl1-1le', confidence: 'reported' },
  { id: 'p22-heritage', year: 2022, label: 'Heritage Edition base (mustangspecs)', kind: 'msrp', value: 76695, source: 'https://www.mustangspecs.com/?p=52472', confidence: 'reported', note: 'Plus $2,140 vinyl stripes or +$10,000 hand-painted stripes, per the same source.' },
  { id: 'p21-base', year: 2021, label: 'Base MSRP', kind: 'msrp', value: null, source: 'https://mustangattitude.com/mustang/2021shelby.shtml', confidence: 'unverified', note: 'No sourced 2021 base MSRP.' },
  { id: 'p21-cftp', year: 2021, label: 'Example CFTP car incl. delivery & gas guzzler', kind: 'delivered', value: 97365, source: 'https://www.stlouiscarmuseum.com/vehicles/1075/2021-ford-shelby-mustang-gt500-carbon-fiber-track-pack', confidence: 'reported' },
  { id: 'p22-base', year: 2022, label: 'Base MSRP (Carscoops)', kind: 'msrp', value: 73465, source: CS22, confidence: 'reported', note: 'Conflicts with $72,900 in Heritage coverage; likely counted differently.' },
  { id: 'p22-base-alt', year: 2022, label: 'Base MSRP (Heritage coverage)', kind: 'msrp', value: 72900, source: 'https://www.thespeedjournal.com/limited-edition-2022-mustang-shelby-gt500-heritage-edition/', confidence: 'reported', note: 'Conflicts with $73,465.' },
  { id: 'p22-dest', year: 2022, label: 'Destination', kind: 'destination', value: 1195, source: CS22, confidence: 'reported' },
  { id: 'p22-gg', year: 2022, label: 'Gas guzzler tax', kind: 'gas-guzzler', value: 2600, source: CS22, confidence: 'reported' },
];

const PCAR = 'https://www-backend.pcarmarket.com/auction/';
export const marketSales: MarketSale[] = [
  { id: 'm-markup', date: null, venue: 'Dealer (Riverside, CA)', year: 2020, description: 'CFTP car asking price vs $105,890 MSRP', amount: 185890, outcome: 'asking', source: 'https://www.carscoops.com/?p=1986503', confidence: 'reported' },
  { id: 'm-bj20', date: null, venue: 'Barrett-Jackson', year: 2020, description: 'Iconic Silver CFTP with painted stripes', amount: 154000, outcome: 'sold', source: 'https://www.ford-trucks.com/?p=119208', confidence: 'reported' },
  { id: 'm-bj21', date: null, venue: 'Barrett-Jackson', year: 2021, description: 'Oxford White CFTP with stripes', amount: 165000, outcome: 'sold', source: 'https://www.ford-trucks.com/?p=119208', confidence: 'reported' },
  { id: 'm-pcar22', date: null, venue: 'PCARMarket', year: 2022, description: 'Iconic Silver CFTP, 18 mi', amount: 112000, outcome: 'sold', source: PCAR + '2022-ford-mustang-shelby-gt500', confidence: 'reported' },
  { id: 'm-pcar22b', date: null, venue: 'PCARMarket', year: 2022, description: 'Dark Matter Gray CFTP, 11 mi (final bid)', amount: 94250, outcome: 'high-bid', source: PCAR + '2022-ford-mustang-gt500-1', confidence: 'reported' },
  { id: 'm-pcarher', date: '2024-08-20', venue: 'PCARMarket', year: 2022, description: 'Heritage Edition CFTP, Brittany Blue (not sold)', amount: 84000, outcome: 'high-bid', source: PCAR + '2022-ford-mustang-shelby-gt500-heritage-edition-carbon-fiber-track-pack', confidence: 'reported' },
  { id: 'm-pcar21', date: null, venue: 'PCARMarket', year: 2021, description: 'Carbonized Gray, ~2,450 mi', amount: 79250, outcome: 'sold', source: PCAR + '2021-ford-mustang-shelby-cobra-gt500-coupe', confidence: 'reported' },
  { id: 'm-mecum-dal', date: '2022-09', venue: 'Mecum Dallas', year: 2020, description: 'Sold', amount: 118250, outcome: 'sold', source: 'https://www.hagerty.com/valuation-tools/past-sales/2020-ford-mustang/vin/1c1ff011-1ef7-4975-9379-bfccc3e54002', confidence: 'unverified', note: 'Mapping of result to Hagerty page not verified.' },
  { id: 'm-mecum-gl', date: '2023-03', venue: 'Mecum Glendale', year: 2020, description: 'High bid, not sold', amount: 100000, outcome: 'high-bid', source: 'https://www.hagerty.com/valuation-tools/past-sales/2020-ford-mustang/vin/e2882aff-826f-40ce-8da8-4a31d724cb50', confidence: 'unverified', note: 'Mapping not verified.' },
  { id: 'm-mecum-sch', date: '2022-10', venue: 'Mecum Schaumburg', year: 2020, description: 'High bid, not sold', amount: 70000, outcome: 'high-bid', source: 'https://www.hagerty.com/valuation-tools/past-sales/2020-ford-mustang/vin/80af0d86-12dd-484f-a249-aaeb16621f55', confidence: 'unverified', note: 'Mapping not verified.' },
];

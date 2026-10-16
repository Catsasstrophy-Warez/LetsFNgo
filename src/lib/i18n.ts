/**
 * Tiny typed i18n layer (no dependencies). English is the complete reference dictionary; other languages
 * may be partial and fall back to English per key. Only UI chrome is translated — sourced data facts
 * (spec values, notes, sources) stay in English so they match their citations.
 */
export type Lang = 'en' | 'es';
export const LANGS: [Lang, string][] = [['en', 'English'], ['es', 'Español']];

export const en = {
  'nav.home': 'Home', 'nav.specs': 'Specs', 'nav.years': 'Model Years', 'nav.colors': 'Colors', 'nav.visualizer': 'Color Visualizer',
  'nav.packages': 'Packages & Pricing', 'nav.performance': 'Performance', 'nav.vin': 'VIN Decoder', 'nav.ownership': 'Ownership',
  'nav.garage': 'Garage', 'nav.planner': 'Build Planner', 'nav.timeline': 'Ownership Timeline', 'nav.track': 'Track Day Log',
  'nav.timer': 'Session Timer', 'nav.drag': 'Drag Strip Log', 'nav.gps': 'GPS Meter (approx.)', 'nav.fuel': 'Fuel & Cost',
  'nav.dyno': 'Dyno Log', 'nav.tires': 'Tire & Wheel Calc', 'nav.gearing': 'Gear & Speed Calc', 'nav.tools': 'Performance Tools',
  'nav.parts': 'Parts & Fluids', 'nav.guides': 'How-to Guides',
  'nav.mods': 'Mods & Tuning', 'nav.compare': 'Compare', 'nav.diff': 'Year & Rival Compare', 'nav.media': 'Media', 'nav.community': 'Community',
  'nav.quiz': 'Trivia Quiz', 'nav.print': 'Print Spec Sheet', 'nav.sources': 'Sources', 'nav.settings': 'Settings', 'nav.search': 'Search',
  'tab.vin': 'VIN',
  'chrome.menu': 'Menu', 'chrome.toggleTheme': 'Toggle theme', 'chrome.skip': 'Skip to content', 'chrome.loading': 'Loading…',
  'chrome.sections': 'Sections', 'chrome.quick': 'Quick',
  'chrome.footer': 'Unofficial fan reference. Not affiliated with, endorsed by or sponsored by Ford Motor Company, Shelby American or Carroll Shelby Licensing. Names are used for identification only. Verify figures with official documents.',
  'settings.title': 'Settings', 'settings.units': 'Units', 'settings.imperial': 'Imperial (mi, mph, lb, °F)', 'settings.metric': 'Metric (km, km/h, kg, °C)',
  'settings.unitsNote': 'Applies to Specs, Gear & Speed, Performance Tools, Garage, Drag Strip and Fuel logs and the print sheet. Data is stored in imperial units and converted for display, so switching never changes what you logged.',
  'settings.theme': 'Theme', 'settings.dark': 'Dark', 'settings.light': 'Light', 'settings.system': 'Match device',
  'settings.language': 'Language', 'settings.languageNote': 'Translates menus and settings. Sourced facts stay in English so they match their citations.',
  'settings.intro': 'Intro', 'settings.introText': 'Run the 3-step first-run intro again (year, color, VIN, units). It only fills values you choose.',
  'settings.introBtn': 'Run intro again', 'settings.carLink': 'Looking for your car?',
} as const;
export type MsgKey = keyof typeof en;

export const es: Partial<Record<MsgKey, string>> = {
  'nav.home': 'Inicio', 'nav.specs': 'Especificaciones', 'nav.years': 'Años de modelo', 'nav.colors': 'Colores', 'nav.visualizer': 'Visualizador de color',
  'nav.packages': 'Paquetes y precios', 'nav.performance': 'Prestaciones', 'nav.vin': 'Decodificador VIN', 'nav.ownership': 'Propiedad',
  'nav.garage': 'Garaje', 'nav.planner': 'Planificador', 'nav.timeline': 'Historial', 'nav.track': 'Registro de pista',
  'nav.timer': 'Cronómetro', 'nav.drag': 'Registro de arrancones', 'nav.gps': 'Medidor GPS (aprox.)', 'nav.fuel': 'Combustible y costos',
  'nav.dyno': 'Registro de dinamómetro', 'nav.tires': 'Calculadora de llantas', 'nav.gearing': 'Marchas y velocidad', 'nav.tools': 'Herramientas',
  'nav.parts': 'Piezas y fluidos', 'nav.guides': 'Guías prácticas',
  'nav.mods': 'Modificaciones', 'nav.compare': 'Comparar', 'nav.diff': 'Comparar años y rivales', 'nav.media': 'Multimedia', 'nav.community': 'Comunidad',
  'nav.quiz': 'Trivia', 'nav.print': 'Ficha imprimible', 'nav.sources': 'Fuentes', 'nav.settings': 'Ajustes', 'nav.search': 'Buscar',
  'tab.vin': 'VIN',
  'chrome.menu': 'Menú', 'chrome.toggleTheme': 'Cambiar tema', 'chrome.skip': 'Saltar al contenido', 'chrome.loading': 'Cargando…',
  'chrome.sections': 'Secciones', 'chrome.quick': 'Acceso rápido',
  'chrome.footer': 'Referencia no oficial de aficionados. Sin afiliación, respaldo ni patrocinio de Ford Motor Company, Shelby American ni Carroll Shelby Licensing. Los nombres se usan solo para identificación. Verifique las cifras con documentos oficiales.',
  'settings.title': 'Ajustes', 'settings.units': 'Unidades', 'settings.imperial': 'Imperiales (mi, mph, lb, °F)', 'settings.metric': 'Métricas (km, km/h, kg, °C)',
  'settings.unitsNote': 'Se aplica a especificaciones, marchas y velocidad, herramientas, garaje, registros de arrancones y combustible y la ficha imprimible. Los datos se guardan en unidades imperiales y se convierten al mostrarlos, así que cambiar nunca altera lo registrado.',
  'settings.theme': 'Tema', 'settings.dark': 'Oscuro', 'settings.light': 'Claro', 'settings.system': 'Igual que el dispositivo',
  'settings.language': 'Idioma', 'settings.languageNote': 'Traduce los menús y los ajustes. Los datos con fuente siguen en inglés para coincidir con sus citas.',
  'settings.intro': 'Introducción', 'settings.introText': 'Vuelva a ejecutar la introducción de 3 pasos (año, color, VIN, unidades). Solo rellena los valores que elija.',
  'settings.introBtn': 'Repetir introducción', 'settings.carLink': '¿Busca su auto?',
};

const DICTS: Record<Lang, Partial<Record<MsgKey, string>>> = { en, es };

export const normLang = (v: unknown): Lang => (v === 'es' ? 'es' : 'en');

/** Translate a key, falling back to English. `{name}` placeholders are filled from `vars`. */
export function translate(lang: Lang, key: MsgKey, vars?: Record<string, string | number>): string {
  const s = DICTS[lang][key] ?? en[key];
  return vars ? s.replace(/\{(\w+)\}/g, (m, k) => (k in vars ? String(vars[k]) : m)) : s;
}

/** Keys a language has not translated yet (English is always complete by construction). */
export const missingKeys = (lang: Lang): MsgKey[] => (Object.keys(en) as MsgKey[]).filter((k) => !DICTS[lang][k]);

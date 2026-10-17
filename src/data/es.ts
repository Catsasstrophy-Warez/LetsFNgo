import type { SpecFact } from './types';

/**
 * Spanish overlay for the human-readable text of sourced facts, keyed by record id. Only labels and explanatory notes
 * are translated — never values, units, codes, names, quotes, sources or confidence. A record (or field) missing here
 * falls back to the English original, and translated text is shown with a visible "translated" marker so a reader
 * knows the cited source is in English. The English records in the data files stay untouched.
 *
 * tests/round14.test.ts checks that every key here exists in the data, so a renamed or removed record fails CI.
 */
export interface FactTextEs { label?: string; note?: string }

export const esOverlay: { specs: Record<string, FactTextEs> } = {
  specs: {
    engine: { label: 'Motor' },
    supercharger: { label: 'Sobrealimentador' },
    hp: { label: 'Potencia' },
    tq: { label: 'Par motor' },
    redline: { label: 'Línea roja', note: 'De la página de la transmisión de TREMEC, no de una especificación de motor de Ford.' },
    compression: { label: 'Relación de compresión' },
    boost: { label: 'Presión máxima de sobrealimentación' },
    intercooler: { label: 'Intercooler' },
    'bore-stroke': { label: 'Diámetro × carrera', note: 'Solo fuentes secundarias (también Ford Authority); no se obtuvo una hoja técnica de Ford.' },
    trans: { label: 'Transmisión' },
    shift: { label: 'Tiempo de cambio' },
    'gear-ratios': { label: 'Relaciones de marcha (1–7, R)', note: 'Hoja de producto de TREMEC, "Ratio A". Según se informa, un fragmento de búsqueda del manual del propietario de Ford coincide en 1.ª, 2.ª, 7.ª y reversa.' },
    'clutch-packs': { label: 'Paquetes de embrague DCT' },
    'clutch-rating': { label: 'Par admisible del embrague DCT', note: 'Solo publicaciones de foros; no se encontró una cifra de Ford ni de TREMEC.' },
    diff: { label: 'Diferencial' },
    launch: { label: 'Control de arranque' },
    'brakes-f': { label: 'Frenos delanteros' },
    'brakes-r': { label: 'Frenos traseros' },
    magneride: { label: 'Calibración MagneRide / constantes de resorte', note: 'Ninguna fuente lo confirma.' },
    tires: { label: 'Llantas' },
    'tire-f': { label: 'Medida de llanta delantera' },
    'tire-r': { label: 'Medida de llanta trasera', note: 'De un anuncio de venta; aún no confirmado por una hoja técnica de Ford.' },
    wheels: { label: 'Medidas de rin' },
    wheelbase: { label: 'Distancia entre ejes' },
    length: { label: 'Largo' },
    width: { label: 'Ancho' },
    height: { label: 'Alto' },
    'curb-weight': { label: 'Peso en vacío', note: 'Las fuentes no coinciden. 4,225 lb tiene el origen más fiable; se muestra como rango hasta que una hoja técnica de Ford confirme una sola cifra.' },
    'top-speed': { label: 'Velocidad máxima' },
    mpg: { label: 'Rendimiento de combustible EPA' },
    tank: { label: 'Tanque de combustible' },
    speedo: { label: 'Velocímetro' },
    'line-lock': { label: 'Control de arranque y line lock' },
    'drive-modes': { label: 'Modos de manejo', note: 'Track: dirección más firme, MagneRide más firme y el programa de cambios más agresivo (Motor Authority). Drag: control de arranque. Los efectos de Normal/Weather/Sport no están documentados. El contenido de MyMode y Track Apps no está confirmado.' },
    'drag-mode': { label: 'Modo Drag' },
    'track-mode': { label: 'Modo Track' },
    'exhaust-modes': { label: 'Modos de escape (válvulas activas)' },
    plant: { label: 'Planta de ensamble' },
  },
};

export interface LocalText { label: string; note: string | undefined; /** True when any shown field came from the overlay. */ translated: boolean }

/** A spec's label and note in `lang`, falling back to English per field. */
export function specText(s: Pick<SpecFact, 'id' | 'label' | 'note'>, lang: 'en' | 'es'): LocalText {
  const o = lang === 'es' ? esOverlay.specs[s.id] : undefined;
  const label = o?.label ?? s.label;
  const note = s.note === undefined ? undefined : o?.note ?? s.note;
  return { label, note, translated: !!o && (o.label !== undefined || (s.note !== undefined && o.note !== undefined)) };
}

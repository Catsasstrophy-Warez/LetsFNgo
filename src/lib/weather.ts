/**
 * Opt-in weather auto-fill from Open-Meteo (https://open-meteo.com — free, no API key). Only this origin is allowed
 * by the CSP connect-src. The request sends just the rounded coordinates; nothing is sent unless the user taps
 * "Fetch weather" after turning the feature on. Offline or on any error, manual entry keeps working.
 */
import { load, save } from './storage';

export const WEATHER_ORIGIN = 'https://api.open-meteo.com';
export const WEATHER_KEY = 'gt500.weather.v1';

export interface WeatherPrefs { enabled: boolean; lat: string; lon: string }
export const DEFAULT_WEATHER: WeatherPrefs = { enabled: false, lat: '', lon: '' };

export function normWeatherPrefs(v: unknown): WeatherPrefs {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return { ...DEFAULT_WEATHER };
  const o = v as Record<string, unknown>;
  const s = (x: unknown) => (typeof x === 'string' ? x.slice(0, 20) : '');
  return { enabled: o.enabled === true, lat: s(o.lat), lon: s(o.lon) };
}
export const loadWeatherPrefs = () => normWeatherPrefs(load<unknown>(WEATHER_KEY, null));
export const saveWeatherPrefs = (p: WeatherPrefs) => save(WEATHER_KEY, p);

/** Parse a typed coordinate pair; null when out of range. */
export function parseCoords(lat: string, lon: string): { lat: number; lon: number } | null {
  const a = Number(lat.trim().replace(',', '.')), b = Number(lon.trim().replace(',', '.'));
  if (lat.trim() === '' || lon.trim() === '' || !Number.isFinite(a) || !Number.isFinite(b) || Math.abs(a) > 90 || Math.abs(b) > 180) return null;
  return { lat: a, lon: b };
}

/** Request URL. Coordinates are rounded to 2 dp (~1 km) — enough for weather, less precise for privacy. */
export function weatherUrl(lat: number, lon: number): string {
  const q = new URLSearchParams({ latitude: lat.toFixed(2), longitude: lon.toFixed(2), current: 'temperature_2m,relative_humidity_2m,surface_pressure,pressure_msl', temperature_unit: 'fahrenheit', timezone: 'auto' });
  return `${WEATHER_ORIGIN}/v1/forecast?${q}`;
}

export interface Weather {
  tempF: number; humidity: number;
  /** Station (surface) pressure, inHg — what the density-altitude formula wants with pressureIsStation. */
  stationInHg: number;
  /** Sea-level (MSL) pressure, inHg, when reported. */
  mslInHg: number | null;
  /** Grid elevation Open-Meteo used, ft. */
  elevationFt: number | null;
  time: string;
}

const HPA_TO_INHG = 0.0295299830714;
const fin = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);

/** Validate an Open-Meteo `forecast?current=…` response. Returns null for anything unexpected or out of range. */
export function parseWeather(json: unknown): Weather | null {
  if (!json || typeof json !== 'object') return null;
  const o = json as Record<string, unknown>;
  const c = o.current as Record<string, unknown> | undefined;
  const units = (o.current_units ?? {}) as Record<string, unknown>;
  if (!c || typeof c !== 'object') return null;
  const rawTemp = c.temperature_2m;
  const rh = c.relative_humidity_2m, sp = c.surface_pressure, msl = c.pressure_msl;
  if (!fin(rawTemp) || !fin(rh) || !fin(sp)) return null;
  const temp = units.temperature_2m === '°C' ? rawTemp * 1.8 + 32 : rawTemp;
  if (temp < -80 || temp > 140 || rh < 0 || rh > 100 || sp < 300 || sp > 1100) return null;
  const elev = fin(o.elevation) ? Math.round(o.elevation / 0.3048) : null;
  return {
    tempF: Math.round(temp * 10) / 10, humidity: Math.round(rh), stationInHg: Math.round(sp * HPA_TO_INHG * 100) / 100,
    mslInHg: fin(msl) && msl > 800 && msl < 1100 ? Math.round(msl * HPA_TO_INHG * 100) / 100 : null,
    elevationFt: elev, time: typeof c.time === 'string' ? c.time.slice(0, 16) : '',
  };
}

export type WeatherError = 'offline' | 'network' | 'bad-response';

/** Fetch current weather. `fetchImpl` is injectable for tests (no live network in tests). */
export async function fetchWeather(lat: number, lon: number, fetchImpl: typeof fetch = fetch, signal?: AbortSignal): Promise<{ ok: true; weather: Weather } | { ok: false; error: WeatherError }> {
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return { ok: false, error: 'offline' };
  try {
    const res = await fetchImpl(weatherUrl(lat, lon), { signal, credentials: 'omit', referrerPolicy: 'no-referrer' });
    if (!res.ok) return { ok: false, error: 'network' };
    const w = parseWeather(await res.json());
    return w ? { ok: true, weather: w } : { ok: false, error: 'bad-response' };
  } catch {
    return { ok: false, error: 'network' };
  }
}

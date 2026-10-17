import { useEffect, useRef, useState } from 'react';
import { useT } from './SettingsContext';
import { fetchWeather, loadWeatherPrefs, parseCoords, saveWeatherPrefs, type Weather, type WeatherPrefs } from '../lib/weather';

/**
 * Opt-in "fill from current weather" control. Off by default; when on, the user types coordinates or taps
 * "Use my location" (one-shot, permission-gated), then "Fetch weather". Only rounded coordinates go to Open-Meteo.
 * Any failure leaves the manual fields untouched.
 */
export function WeatherFill({ onFill }: { onFill: (w: Weather) => void }) {
  const t = useT();
  const [p, setP] = useState<WeatherPrefs>(loadWeatherPrefs);
  const [status, setStatus] = useState<{ ok: boolean; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const abort = useRef<AbortController | null>(null);
  useEffect(() => () => abort.current?.abort(), []);
  const update = (next: WeatherPrefs) => { setP(next); saveWeatherPrefs(next); };

  const locate = () => {
    if (!navigator.geolocation) return setStatus({ ok: false, text: t('gps.noGeo') });
    setStatus({ ok: true, text: t('wx.locating') });
    navigator.geolocation.getCurrentPosition(
      (pos) => { update({ ...p, lat: pos.coords.latitude.toFixed(2), lon: pos.coords.longitude.toFixed(2) }); setStatus(null); },
      (e) => setStatus({ ok: false, text: e.code === 1 ? t('gps.denied') : t('gps.unavailable') }),
      { enableHighAccuracy: false, maximumAge: 600000, timeout: 15000 },
    );
  };
  const go = async () => {
    const c = parseCoords(p.lat, p.lon);
    if (!c) return setStatus({ ok: false, text: t('wx.badCoords') });
    abort.current?.abort();
    abort.current = new AbortController();
    setBusy(true); setStatus(null);
    const r = await fetchWeather(c.lat, c.lon, fetch, abort.current.signal);
    setBusy(false);
    if (!r.ok) return setStatus({ ok: false, text: t(r.error === 'offline' ? 'wx.offline' : r.error === 'bad-response' ? 'wx.bad' : 'wx.failed') });
    onFill(r.weather);
    setStatus({ ok: true, text: t('wx.filled', { time: r.weather.time || '—' }) });
  };

  return (
    <div className="wx">
      <label className="check"><input type="checkbox" checked={p.enabled} onChange={(e) => update({ ...p, enabled: e.target.checked })} /> {t('wx.enable')}</label>
      <p className="muted small">{t('wx.privacy')}</p>
      {p.enabled && (
        <>
          <div className="form two">
            <label>{t('wx.lat')}<input className="input" inputMode="decimal" value={p.lat} onChange={(e) => update({ ...p, lat: e.target.value })} placeholder="36.58" /></label>
            <label>{t('wx.lon')}<input className="input" inputMode="decimal" value={p.lon} onChange={(e) => update({ ...p, lon: e.target.value })} placeholder="-121.75" /></label>
          </div>
          <div className="btn-row">
            <button type="button" className="btn ghost" onClick={locate}>{t('wx.useLocation')}</button>
            <button type="button" className="btn" onClick={go} disabled={busy}>{busy ? t('wx.fetching') : t('wx.fetch')}</button>
          </div>
        </>
      )}
      {status && <p className={status.ok ? 'ok-t small' : 'err small'} role={status.ok ? 'status' : 'alert'}>{status.text}</p>}
    </div>
  );
}

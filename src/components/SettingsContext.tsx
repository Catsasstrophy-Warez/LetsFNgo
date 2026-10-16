import { createContext, useContext } from 'react';
import { DEFAULT_SETTINGS, type Settings } from '../lib/units';
import { setCurrentLang, translate, type MsgKey } from '../lib/i18n';

export interface SettingsCtx { settings: Settings; setSettings: (s: Settings) => void }
export const SettingsContext = createContext<SettingsCtx>({ settings: DEFAULT_SETTINGS, setSettings: () => undefined });
export const useSettings = () => useContext(SettingsContext);
export const useUnits = () => useContext(SettingsContext).settings.units;
/** Translator bound to the current language: `t('nav.home')`. */
export const useT = () => { const lang = useContext(SettingsContext).settings.lang ?? 'en'; setCurrentLang(lang); return (k: MsgKey, vars?: Record<string, string | number>) => translate(lang, k, vars); };

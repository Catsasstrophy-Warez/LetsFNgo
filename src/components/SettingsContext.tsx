import { createContext, useContext } from 'react';
import { DEFAULT_SETTINGS, type Settings } from '../lib/units';

export interface SettingsCtx { settings: Settings; setSettings: (s: Settings) => void }
export const SettingsContext = createContext<SettingsCtx>({ settings: DEFAULT_SETTINGS, setSettings: () => undefined });
export const useSettings = () => useContext(SettingsContext);
export const useUnits = () => useContext(SettingsContext).settings.units;

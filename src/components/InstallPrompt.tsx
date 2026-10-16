import { useEffect, useState } from 'react';
import { useT } from './SettingsContext';
import { dismissInstall, installMode, isDismissed, isIosSafari, isStandalone, loadInstall } from '../lib/install';
import { isNativeApp } from '../lib/platform';
import { today } from '../lib/garage';

interface BipEvent extends Event { prompt: () => Promise<void>; userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }> }

/** Install banner (Chromium `beforeinstallprompt`) or iOS "Add to Home Screen" hint, with remembered dismissal. */
export function InstallPrompt() {
  const t = useT();
  const [evt, setEvt] = useState<BipEvent | null>(null);
  const [hidden, setHidden] = useState(() => isDismissed(loadInstall(), today()));
  useEffect(() => {
    const onBip = (e: Event) => { e.preventDefault(); setEvt(e as BipEvent); };
    const onInstalled = () => { setEvt(null); setHidden(true); };
    window.addEventListener('beforeinstallprompt', onBip);
    window.addEventListener('appinstalled', onInstalled);
    return () => { window.removeEventListener('beforeinstallprompt', onBip); window.removeEventListener('appinstalled', onInstalled); };
  }, []);
  const mode = installMode({ hasPrompt: !!evt, ios: typeof navigator !== 'undefined' && isIosSafari(navigator.userAgent, navigator.maxTouchPoints), standalone: isStandalone(), native: isNativeApp(), dismissed: hidden });
  if (!mode) return null;
  const dismiss = () => { dismissInstall(today()); setHidden(true); };
  const install = async () => {
    if (!evt) return;
    await evt.prompt();
    const c = await evt.userChoice.catch(() => ({ outcome: 'dismissed' as const }));
    setEvt(null);
    if (c.outcome === 'dismissed') dismiss();
  };
  return (
    <aside className="banner install" aria-labelledby="install-t">
      <p id="install-t"><strong>{t('install.title')}</strong> {mode === 'ios' ? t('install.ios') : t('install.text')}</p>
      <div className="row-actions">
        {mode === 'prompt' && <button className="btn" onClick={install}>{t('install.btn')}</button>}
        <button className="btn ghost" onClick={dismiss}>{t('install.dismiss')}</button>
      </div>
    </aside>
  );
}

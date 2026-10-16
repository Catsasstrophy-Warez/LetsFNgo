import type { CapacitorConfig } from '@capacitor/cli';

/**
 * Native wrappers (iOS + Android) around the built PWA in dist/. The app uses HashRouter and Vite `base: './'`,
 * so every asset URL is relative and routes live after `#` — both work from the WebView's local file server
 * (capacitor://localhost on iOS, https://localhost on Android) without rewrites.
 * The generated ios/ and android/ projects are NOT committed; create them with `npm run cap:add`.
 */
const config: CapacitorConfig = {
  appId: 'io.github.catsasstrophywarez.gt500companion',
  appName: 'GT500 Companion',
  webDir: 'dist',
  backgroundColor: '#0b0d10',
  // Hardening: the WebView serves the bundled app over https://localhost, never navigates to remote hosts
  // (external links open in the system browser), allows no cleartext HTTP and no remote debugging in release.
  server: { androidScheme: 'https', iosScheme: 'capacitor', cleartext: false, allowNavigation: [] },
  android: { allowMixedContent: false, webContentsDebuggingEnabled: false },
  ios: { contentInset: 'automatic', limitsNavigationsToAppBoundDomains: true },
};

export default config;

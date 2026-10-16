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
  android: { allowMixedContent: false },
  ios: { contentInset: 'automatic' },
};

export default config;

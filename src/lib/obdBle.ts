/**
 * Web Bluetooth transport for BLE ELM327-style adapters. Only opened from a user tap ("Connect adapter"); the browser
 * shows its own device chooser and permission prompt. Web Bluetooth is not available in iOS Safari / iOS browsers or
 * Firefox, and needs a secure context (https). No CSP change is needed: it is not a network request.
 */
import type { ObdTransport } from './obd';

/** Common BLE UART layouts used by ELM327 clones: [service, notify characteristic, write characteristic]. */
export const BLE_PROFILES: [string, string, string][] = [
  ['0000fff0-0000-1000-8000-00805f9b34fb', '0000fff1-0000-1000-8000-00805f9b34fb', '0000fff2-0000-1000-8000-00805f9b34fb'],
  ['0000ffe0-0000-1000-8000-00805f9b34fb', '0000ffe1-0000-1000-8000-00805f9b34fb', '0000ffe1-0000-1000-8000-00805f9b34fb'],
  ['000018f0-0000-1000-8000-00805f9b34fb', '00002af0-0000-1000-8000-00805f9b34fb', '00002af1-0000-1000-8000-00805f9b34fb'],
  ['e7810a71-73ae-499d-8c15-faa9aef0c3f2', 'bef8d6c9-9c21-4c9e-b632-bd58c1009f9f', 'bef8d6c9-9c21-4c9e-b632-bd58c1009f9f'],
];

export type BleSupport = 'ok' | 'noApi' | 'insecure';
export function bleSupport(): BleSupport {
  if (typeof window !== 'undefined' && window.isSecureContext === false) return 'insecure';
  return typeof navigator !== 'undefined' && 'bluetooth' in navigator ? 'ok' : 'noApi';
}

/* Minimal Web Bluetooth typings (not in lib.dom). */
interface Char { value?: DataView; startNotifications(): Promise<Char>; addEventListener(t: string, f: (e: Event) => void): void; writeValue(v: BufferSource): Promise<void> }
interface Service { getCharacteristic(u: string): Promise<Char> }
interface Gatt { connected: boolean; connect(): Promise<Gatt>; disconnect(): void; getPrimaryService(u: string): Promise<Service> }
interface Device { name?: string; gatt?: Gatt; addEventListener(t: string, f: () => void): void }
interface Bluetooth { requestDevice(o: { acceptAllDevices: boolean; optionalServices: string[] }): Promise<Device> }

export const REPLY_TIMEOUT_MS = 2500;

/** Ask the user to pick an adapter and open its UART. Rejects if the user cancels or no known profile matches. */
export async function connectBle(onDisconnect: () => void): Promise<ObdTransport & { name: string }> {
  const bt = (navigator as unknown as { bluetooth: Bluetooth }).bluetooth;
  const dev = await bt.requestDevice({ acceptAllDevices: true, optionalServices: BLE_PROFILES.map((p) => p[0]) });
  const gatt = await dev.gatt!.connect();
  dev.addEventListener('gattserverdisconnected', onDisconnect);
  let rx: Char | null = null, tx: Char | null = null;
  for (const [svc, n, w] of BLE_PROFILES) {
    try { const s = await gatt.getPrimaryService(svc); rx = await s.getCharacteristic(n); tx = await s.getCharacteristic(w); break; } catch { /* try next */ }
  }
  if (!rx || !tx) { gatt.disconnect(); throw new Error('profile'); }
  let buf = '';
  let waiter: ((s: string) => void) | null = null;
  const dec = new TextDecoder();
  rx.addEventListener('characteristicvaluechanged', (e) => {
    const v = (e.target as unknown as Char).value;
    if (!v) return;
    buf += dec.decode(v);
    if (buf.includes('>') && waiter) { const out = buf; buf = ''; const w = waiter; waiter = null; w(out); }
  });
  await rx.startNotifications();
  const enc = new TextEncoder();
  let chain: Promise<unknown> = Promise.resolve();
  const send = (cmd: string) => {
    const p = chain.then(() => new Promise<string>((ok, bad) => {
      buf = '';
      const timer = setTimeout(() => { waiter = null; bad(new Error('timeout')); }, cmd === 'ATZ' ? REPLY_TIMEOUT_MS * 2 : REPLY_TIMEOUT_MS);
      waiter = (s) => { clearTimeout(timer); ok(s); };
      tx!.writeValue(enc.encode(`${cmd}\r`)).catch((e) => { clearTimeout(timer); waiter = null; bad(e); });
    }));
    chain = p.catch(() => undefined);
    return p;
  };
  return { name: dev.name ?? 'OBD adapter', send, close: async () => { if (gatt.connected) gatt.disconnect(); } };
}

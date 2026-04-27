import type { PairingPayload } from '../domain/types';

const STORAGE_KEY = 'remodex.web.pairingPayload.v1';

export function loadSavedPairing(): PairingPayload | null {
  const envPayload = import.meta.env.VITE_REMODEX_PAIRING_PAYLOAD as string | undefined;
  if (envPayload?.trim()) {
    const parsed = parsePairingPayload(envPayload);
    return isPairingExpired(parsed) ? null : parsed;
  }
  const raw = localStorage.getItem(STORAGE_KEY);
  if (!raw) return null;
  const parsed = parsePairingPayload(raw);
  if (isPairingExpired(parsed)) {
    clearPairing();
    return null;
  }
  return parsed;
}

export function savePairing(payload: PairingPayload): void {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(payload));
}

export function clearPairing(): void {
  localStorage.removeItem(STORAGE_KEY);
}

export async function fetchBootstrapPairing(): Promise<PairingPayload | null> {
  const configuredUrl = (import.meta.env.VITE_REMODEX_BOOTSTRAP_URL as string | undefined)?.trim();
  const urls = [
    configuredUrl,
    `${window.location.origin}/local-web/bootstrap`,
    'http://127.0.0.1:8787/local-web/bootstrap',
  ].filter(Boolean) as string[];

  for (const url of urls) {
    try {
      const response = await fetch(url, { cache: 'no-store' });
      if (!response.ok) continue;
      const body = await response.json() as { pairingPayload?: PairingPayload };
      if (body.pairingPayload && !isPairingExpired(body.pairingPayload)) {
        return body.pairingPayload;
      }
    } catch {
      // Try the next configured endpoint.
    }
  }
  return null;
}

export function isPairingExpired(payload: PairingPayload, now = Date.now()): boolean {
  return Number.isFinite(payload.expiresAt) && payload.expiresAt <= now;
}

export function parsePairingPayload(input: string): PairingPayload {
  const trimmed = input.trim();
  const payloadText = trimmed.startsWith('remodex://') ? decodeDeepLink(trimmed) : trimmed;
  const parsed = JSON.parse(payloadText) as PairingPayload;
  if (!parsed.relay || !parsed.sessionId || !parsed.macDeviceId || !parsed.macIdentityPublicKey) {
    throw new Error('Pairing payload is missing required fields.');
  }
  return parsed;
}

export function relaySocketUrl(pairing: PairingPayload): string {
  const envRelay = import.meta.env.VITE_REMODEX_RELAY_URL as string | undefined;
  if (envRelay?.trim()) {
    return normalizeRelayUrl(envRelay.trim(), pairing.sessionId);
  }
  const currentUrl = new URL(window.location.href);
  if (currentUrl.protocol === 'https:') {
    return appendRole(`wss://${currentUrl.host}/relay/${encodeURIComponent(pairing.sessionId)}`);
  }
  return normalizeRelayUrl(pairing.relay, pairing.sessionId);
}

function normalizeRelayUrl(relay: string, sessionId: string): string {
  const withoutSlash = relay.replace(/\/+$/, '');
  if (withoutSlash.endsWith(`/${sessionId}`)) {
    return appendRole(withoutSlash);
  }
  return appendRole(`${withoutSlash}/${encodeURIComponent(sessionId)}`);
}

function appendRole(url: string): string {
  const separator = url.includes('?') ? '&' : '?';
  return `${url}${separator}role=iphone`;
}

function decodeDeepLink(value: string): string {
  const url = new URL(value);
  const payload = url.searchParams.get('payload') || url.searchParams.get('p');
  if (!payload) {
    throw new Error('Deep link did not include a pairing payload.');
  }
  return decodeURIComponent(payload);
}

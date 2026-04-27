import { ed25519, x25519 } from '@noble/curves/ed25519';
import type { PairingPayload } from '../domain/types';
import {
  base64ToBytes,
  bytesToBase64,
  concatBytes,
  decodeUtf8,
  lengthPrefixed,
  lengthPrefixedUtf8,
  randomBytes,
  sha256,
  asBufferSource,
  utf8,
} from './encoding';

const PROTOCOL_VERSION = 1;
const HANDSHAKE_TAG = 'remodex-e2ee-v1';
const HANDSHAKE_LABEL = 'client-auth';
const HANDSHAKE_MODE = 'qr_bootstrap';
const SENDER_PHONE = 'iphone';
const SENDER_MAC = 'mac';

interface SecureServerHello {
  kind: 'serverHello';
  protocolVersion: number;
  sessionId: string;
  handshakeMode: string;
  macDeviceId: string;
  macIdentityPublicKey: string;
  macEphemeralPublicKey: string;
  serverNonce: string;
  keyEpoch: number;
  expiresAtForTranscript: number;
  macSignature: string;
  clientNonce?: string;
}

interface SecureError {
  kind: 'secureError';
  code?: string;
  message?: string;
}

interface SecureEnvelope {
  kind: 'encryptedEnvelope';
  v: number;
  sessionId: string;
  keyEpoch: number;
  sender: string;
  counter: number;
  ciphertext: string;
  tag: string;
}

interface SecureApplicationPayload {
  bridgeOutboundSeq?: number;
  payloadText: string;
}

export class SecureTransport {
  private phoneIdentityPrivateKey = randomBytes(32);
  private phoneIdentityPublicKey = ed25519.getPublicKey(this.phoneIdentityPrivateKey);
  private phoneDeviceId = `web-${crypto.randomUUID()}`;
  private session: {
    sessionId: string;
    keyEpoch: number;
    macDeviceId: string;
    phoneToMacKey: CryptoKey;
    macToPhoneKey: CryptoKey;
    nextOutboundCounter: number;
    lastInboundCounter: number;
    lastInboundBridgeOutboundSeq: number;
  } | null = null;

  get deviceId(): string {
    return this.phoneDeviceId;
  }

  async performHandshake(pairing: PairingPayload, socket: WebSocket): Promise<void> {
    const ephemeralPrivate = x25519.utils.randomPrivateKey();
    const ephemeralPublic = x25519.getPublicKey(ephemeralPrivate);
    const clientNonce = randomBytes(32);
    const clientNonceBase64 = bytesToBase64(clientNonce);

    socket.send(JSON.stringify({
      kind: 'clientHello',
      protocolVersion: PROTOCOL_VERSION,
      sessionId: pairing.sessionId,
      handshakeMode: HANDSHAKE_MODE,
      phoneDeviceId: this.phoneDeviceId,
      phoneIdentityPublicKey: bytesToBase64(this.phoneIdentityPublicKey),
      phoneEphemeralPublicKey: bytesToBase64(ephemeralPublic),
      clientNonce: clientNonceBase64,
    }));

    const serverHello = await waitForControl<SecureServerHello>(socket, (message) => {
      if (message.kind === 'secureError') {
        throw new Error(message.message || message.code || 'Secure handshake failed');
      }
      return message.kind === 'serverHello' && message.clientNonce === clientNonceBase64;
    });

    if (serverHello.protocolVersion !== PROTOCOL_VERSION || serverHello.sessionId !== pairing.sessionId) {
      throw new Error('Bridge secure protocol mismatch.');
    }
    if (serverHello.handshakeMode !== HANDSHAKE_MODE) {
      throw new Error('Unexpected secure handshake mode.');
    }
    if (serverHello.macDeviceId !== pairing.macDeviceId || serverHello.macIdentityPublicKey !== pairing.macIdentityPublicKey) {
      throw new Error('Bridge identity did not match pairing payload.');
    }

    const transcript = buildTranscriptBytes({
      sessionId: pairing.sessionId,
      protocolVersion: PROTOCOL_VERSION,
      handshakeMode: HANDSHAKE_MODE,
      keyEpoch: serverHello.keyEpoch,
      macDeviceId: serverHello.macDeviceId,
      phoneDeviceId: this.phoneDeviceId,
      macIdentityPublicKey: serverHello.macIdentityPublicKey,
      phoneIdentityPublicKey: bytesToBase64(this.phoneIdentityPublicKey),
      macEphemeralPublicKey: serverHello.macEphemeralPublicKey,
      phoneEphemeralPublicKey: bytesToBase64(ephemeralPublic),
      clientNonce,
      serverNonce: base64ToBytes(serverHello.serverNonce),
      expiresAtForTranscript: serverHello.expiresAtForTranscript,
    });

    const macSignatureValid = ed25519.verify(
      base64ToBytes(serverHello.macSignature),
      transcript,
      base64ToBytes(serverHello.macIdentityPublicKey),
    );
    if (!macSignatureValid) {
      throw new Error('Bridge signature verification failed.');
    }

    const clientAuthTranscript = concatBytes(transcript, lengthPrefixedUtf8(HANDSHAKE_LABEL));
    const phoneSignature = ed25519.sign(clientAuthTranscript, this.phoneIdentityPrivateKey);
    socket.send(JSON.stringify({
      kind: 'clientAuth',
      sessionId: pairing.sessionId,
      phoneDeviceId: this.phoneDeviceId,
      keyEpoch: serverHello.keyEpoch,
      phoneSignature: bytesToBase64(phoneSignature),
    }));

    await waitForControl(socket, (message) => {
      if (message.kind === 'secureError') {
        throw new Error(message.message || message.code || 'Secure handshake failed');
      }
      return message.kind === 'secureReady'
        && message.sessionId === pairing.sessionId
        && message.keyEpoch === serverHello.keyEpoch
        && message.macDeviceId === serverHello.macDeviceId;
    });

    const sharedSecret = x25519.getSharedSecret(ephemeralPrivate, base64ToBytes(serverHello.macEphemeralPublicKey));
    const salt = await sha256(transcript);
    const infoPrefix = `${HANDSHAKE_TAG}|${pairing.sessionId}|${serverHello.macDeviceId}|${this.phoneDeviceId}|${serverHello.keyEpoch}`;

    const lastAppliedBridgeOutboundSeq = this.session?.lastInboundBridgeOutboundSeq ?? 0;
    this.session = {
      sessionId: pairing.sessionId,
      keyEpoch: serverHello.keyEpoch,
      macDeviceId: serverHello.macDeviceId,
      phoneToMacKey: await deriveAesKey(sharedSecret, salt, `${infoPrefix}|phoneToMac`),
      macToPhoneKey: await deriveAesKey(sharedSecret, salt, `${infoPrefix}|macToPhone`),
      nextOutboundCounter: 0,
      lastInboundCounter: -1,
      lastInboundBridgeOutboundSeq: lastAppliedBridgeOutboundSeq,
    };
  }

  sendResumeState(socket: WebSocket): void {
    if (!this.session) {
      throw new Error('Secure channel is not ready.');
    }
    socket.send(JSON.stringify({
      kind: 'resumeState',
      sessionId: this.session.sessionId,
      keyEpoch: this.session.keyEpoch,
      lastAppliedBridgeOutboundSeq: this.session.lastInboundBridgeOutboundSeq,
    }));
  }

  async encryptApplicationMessage(payloadText: string): Promise<string> {
    if (!this.session) {
      throw new Error('Secure channel is not ready.');
    }
    const counter = this.session.nextOutboundCounter;
    const nonce = secureNonce(SENDER_PHONE, counter);
    const plaintext = utf8(JSON.stringify({ payloadText } satisfies SecureApplicationPayload));
    const sealed = new Uint8Array(await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: asBufferSource(nonce) },
      this.session.phoneToMacKey,
      asBufferSource(plaintext),
    ));
    const ciphertext = sealed.slice(0, sealed.length - 16);
    const tag = sealed.slice(sealed.length - 16);
    this.session.nextOutboundCounter += 1;

    return JSON.stringify({
      kind: 'encryptedEnvelope',
      v: PROTOCOL_VERSION,
      sessionId: this.session.sessionId,
      keyEpoch: this.session.keyEpoch,
      sender: SENDER_PHONE,
      counter,
      ciphertext: bytesToBase64(ciphertext),
      tag: bytesToBase64(tag),
    });
  }

  async decryptWireMessage(rawMessage: string): Promise<string | null> {
    if (!this.session) {
      return null;
    }
    const parsed = JSON.parse(rawMessage) as SecureEnvelope | SecureError | { kind?: string };
    if (isSecureError(parsed)) {
      throw new Error(parsed.message || parsed.code || 'Secure channel error');
    }
    if (parsed.kind !== 'encryptedEnvelope') {
      return null;
    }
    const envelope = parsed as SecureEnvelope;
    if (envelope.sessionId !== this.session.sessionId || envelope.keyEpoch !== this.session.keyEpoch || envelope.sender !== SENDER_MAC) {
      return null;
    }
    if (envelope.counter <= this.session.lastInboundCounter) {
      return null;
    }

    const combined = concatBytes(base64ToBytes(envelope.ciphertext), base64ToBytes(envelope.tag));
    const plaintext = new Uint8Array(await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: asBufferSource(secureNonce(envelope.sender, envelope.counter)) },
      this.session.macToPhoneKey,
      asBufferSource(combined),
    ));
    this.session.lastInboundCounter = envelope.counter;
    const applicationPayload = JSON.parse(decodeUtf8(plaintext)) as SecureApplicationPayload;
    if (typeof applicationPayload.bridgeOutboundSeq === 'number') {
      this.session.lastInboundBridgeOutboundSeq = applicationPayload.bridgeOutboundSeq;
    }
    return applicationPayload.payloadText;
  }
}

function waitForControl<T>(socket: WebSocket, predicate: (message: Record<string, any>) => boolean): Promise<T> {
  return new Promise((resolve, reject) => {
    const timeout = window.setTimeout(() => cleanup(() => reject(new Error('Secure handshake timed out.'))), 15000);
    const onMessage = (event: MessageEvent) => {
      try {
        const message = JSON.parse(String(event.data));
        if (predicate(message)) {
          cleanup(() => resolve(message as T));
        }
      } catch (error) {
        cleanup(() => reject(error));
      }
    };
    const onClose = () => cleanup(() => reject(new Error('Relay socket closed during secure handshake.')));
    const cleanup = (callback: () => void) => {
      window.clearTimeout(timeout);
      socket.removeEventListener('message', onMessage);
      socket.removeEventListener('close', onClose);
      callback();
    };
    socket.addEventListener('message', onMessage);
    socket.addEventListener('close', onClose);
  });
}

function isSecureError(value: SecureEnvelope | SecureError | { kind?: string }): value is SecureError {
  return value.kind === 'secureError';
}

function buildTranscriptBytes(input: {
  sessionId: string;
  protocolVersion: number;
  handshakeMode: string;
  keyEpoch: number;
  macDeviceId: string;
  phoneDeviceId: string;
  macIdentityPublicKey: string;
  phoneIdentityPublicKey: string;
  macEphemeralPublicKey: string;
  phoneEphemeralPublicKey: string;
  clientNonce: Uint8Array;
  serverNonce: Uint8Array;
  expiresAtForTranscript: number;
}): Uint8Array {
  return concatBytes(
    lengthPrefixedUtf8(HANDSHAKE_TAG),
    lengthPrefixedUtf8(input.sessionId),
    lengthPrefixedUtf8(String(input.protocolVersion)),
    lengthPrefixedUtf8(input.handshakeMode),
    lengthPrefixedUtf8(String(input.keyEpoch)),
    lengthPrefixedUtf8(input.macDeviceId),
    lengthPrefixedUtf8(input.phoneDeviceId),
    lengthPrefixed(base64ToBytes(input.macIdentityPublicKey)),
    lengthPrefixed(base64ToBytes(input.phoneIdentityPublicKey)),
    lengthPrefixed(base64ToBytes(input.macEphemeralPublicKey)),
    lengthPrefixed(base64ToBytes(input.phoneEphemeralPublicKey)),
    lengthPrefixed(input.clientNonce),
    lengthPrefixed(input.serverNonce),
    lengthPrefixedUtf8(String(input.expiresAtForTranscript)),
  );
}

async function deriveAesKey(sharedSecret: Uint8Array, salt: Uint8Array, info: string): Promise<CryptoKey> {
  const baseKey = await crypto.subtle.importKey('raw', asBufferSource(sharedSecret), 'HKDF', false, ['deriveKey']);
  return crypto.subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: asBufferSource(salt), info: asBufferSource(utf8(info)) },
    baseKey,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  );
}

function secureNonce(sender: string, counter: number): Uint8Array {
  const nonce = new Uint8Array(12);
  nonce[0] = sender === SENDER_MAC ? 1 : 2;
  let value = BigInt(counter);
  for (let index = 11; index >= 1; index -= 1) {
    nonce[index] = Number(value & 0xffn);
    value >>= 8n;
  }
  return nonce;
}

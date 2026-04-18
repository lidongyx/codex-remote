// FILE: relay.js
// Purpose: Thin self-hostable WebSocket relay for Remodex pairing, trusted-session lookup, and encrypted forwarding.
// Layer: Standalone server module
// Exports: setupRelay, getRelayStats, hasActiveMacSession, hasAuthenticatedMacSession, resolveTrustedMacSession, resolveTrustedDeviceConnection, resolvePairingCode

const { createHash, createPublicKey, randomBytes, verify } = require("crypto");
const { WebSocket } = require("ws");

const CLEANUP_DELAY_MS = 60_000;
const HEARTBEAT_INTERVAL_MS = 30_000;
const CLOSE_CODE_SESSION_UNAVAILABLE = 4002;
const CLOSE_CODE_IPHONE_REPLACED = 4003;
const CLOSE_CODE_MAC_ABSENCE_BUFFER_FULL = 4004;
const MAC_ABSENCE_GRACE_MS = 45_000;
const TRUSTED_SESSION_RESOLVE_TAG = "remodex-trusted-session-resolve-v1";
const TRUSTED_SESSION_RESOLVE_SKEW_MS = 90_000;
const DEVICE_CHANNEL_TOKEN_PREFIX = "device~";
const DEVICE_CHANNEL_TOKEN_TTL_MS = 90_000;
const SHORT_PAIRING_CODE_MIN_LENGTH = 8;
const SHORT_PAIRING_CODE_MAX_LENGTH = 12;

// In-memory session registry for one Mac host and one live iPhone client per session.
const sessions = new Map();
const liveSessionsByMacDeviceId = new Map();
const liveSessionsByPairingCode = new Map();
const usedResolveNonces = new Map();
const deviceChannelTargets = new Map();

// Attaches relay behavior to a ws WebSocketServer instance.
function setupRelay(
  wss,
  {
    setTimeoutFn = setTimeout,
    clearTimeoutFn = clearTimeout,
    macAbsenceGraceMs = MAC_ABSENCE_GRACE_MS,
  } = {}
) {
  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (ws._relayAlive === false) {
        ws.terminate();
        continue;
      }
      ws._relayAlive = false;
      ws.ping();
    }
  }, HEARTBEAT_INTERVAL_MS);
  heartbeat.unref?.();

  wss.on("close", () => clearInterval(heartbeat));

  wss.on("connection", (ws, req) => {
    const urlPath = req.url || "";
    const match = urlPath.match(/^\/relay\/([^/?]+)/);
    const role = req.headers["x-role"];
    const requestedSessionId = match?.[1];
    const sessionId = role === "iphone"
      ? resolveIphoneTargetSessionId(requestedSessionId)
      : requestedSessionId;

    if (!sessionId || (role !== "mac" && role !== "iphone")) {
      ws.close(4000, "Missing sessionId or invalid x-role header");
      return;
    }

    ws._relayAlive = true;
    ws.on("pong", () => {
      ws._relayAlive = true;
    });

    // Only the Mac host is allowed to create a fresh session room.
    if (role === "iphone" && !sessions.has(sessionId)) {
      ws.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac session not available");
      return;
    }

    if (!sessions.has(sessionId)) {
      sessions.set(sessionId, {
        mac: null,
        macRegistration: null,
        clients: new Set(),
        cleanupTimer: null,
        macAbsenceTimer: null,
        notificationSecret: null,
      });
    }

    const session = sessions.get(sessionId);

    if (role === "iphone" && !canAcceptIphoneConnection(session)) {
      ws.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac session not available");
      return;
    }

    if (session.cleanupTimer) {
      clearTimeoutFn(session.cleanupTimer);
      session.cleanupTimer = null;
    }

    if (role === "mac") {
      clearMacAbsenceTimer(session, { clearTimeoutFn });
      // The relay keeps a per-session push secret so first-time device registration
      // cannot be claimed by someone who only knows the session id.
      session.notificationSecret = readHeaderString(req.headers["x-notification-secret"]);
      session.macRegistration = readMacRegistrationHeaders(req.headers, sessionId);
      if (session.mac && session.mac.readyState === WebSocket.OPEN) {
        session.mac.close(4001, "Replaced by new Mac connection");
      }
      session.mac = ws;
      registerLiveMacSession(session.macRegistration);
      console.log(`[relay] Mac connected -> ${relaySessionLogLabel(sessionId)}`);
    } else {
      // Keep one live iPhone RPC client per session to avoid competing sockets.
      for (const existingClient of session.clients) {
        if (existingClient === ws) {
          continue;
        }
        if (
          existingClient.readyState === WebSocket.OPEN
          || existingClient.readyState === WebSocket.CONNECTING
        ) {
          existingClient.close(
            CLOSE_CODE_IPHONE_REPLACED,
            "Replaced by newer iPhone connection"
          );
        }
        session.clients.delete(existingClient);
      }

      session.clients.add(ws);
      console.log(
        `[relay] iPhone connected -> ${relaySessionLogLabel(sessionId)} `
        + `(${session.clients.size} client(s))`
      );
    }

    ws.on("message", (data) => {
      const msg = typeof data === "string" ? data : data.toString("utf-8");
      if (role === "mac" && applyMacRegistrationMessage(session, sessionId, msg)) {
        return;
      }

      if (role === "mac") {
        for (const client of session.clients) {
          if (client.readyState === WebSocket.OPEN) {
            client.send(msg);
          }
        }
      } else if (session.mac?.readyState === WebSocket.OPEN) {
        session.mac.send(msg);
      } else {
        // The relay cannot prove a buffered request really reached the bridge after
        // a reconnect, so fail fast with an explicit retry-required close instead
        // of silently dropping queued client work during a later flush.
        ws.close(CLOSE_CODE_MAC_ABSENCE_BUFFER_FULL, "Mac temporarily unavailable");
      }
    });

    ws.on("close", () => {
      if (role === "mac") {
        if (session.mac === ws) {
          session.mac = null;
          unregisterLiveMacSession(session.macRegistration, sessionId);
          console.log(`[relay] Mac disconnected -> ${relaySessionLogLabel(sessionId)}`);
          if (session.clients.size > 0) {
            scheduleMacAbsenceTimeout(sessionId, {
              macAbsenceGraceMs,
              setTimeoutFn,
              clearTimeoutFn,
            });
          } else {
            scheduleCleanup(sessionId, { setTimeoutFn });
          }
        }
      } else {
        session.clients.delete(ws);
        console.log(
          `[relay] iPhone disconnected -> ${relaySessionLogLabel(sessionId)} `
          + `(${session.clients.size} remaining)`
        );
      }
      scheduleCleanup(sessionId, { setTimeoutFn });
    });

    ws.on("error", (err) => {
      console.error(
        `[relay] WebSocket error (${role}, ${relaySessionLogLabel(sessionId)}):`,
        err.message
      );
    });
  });
}

function scheduleCleanup(sessionId, { setTimeoutFn = setTimeout } = {}) {
  const session = sessions.get(sessionId);
  if (!session) {
    return;
  }
  if (session.mac || session.clients.size > 0 || session.cleanupTimer || session.macAbsenceTimer) {
    return;
  }

  session.cleanupTimer = setTimeoutFn(() => {
    const activeSession = sessions.get(sessionId);
    if (
      activeSession
      && !activeSession.mac
      && activeSession.clients.size === 0
      && !activeSession.macAbsenceTimer
    ) {
      unregisterLiveMacSession(activeSession.macRegistration, sessionId);
      sessions.delete(sessionId);
      console.log(`[relay] ${relaySessionLogLabel(sessionId)} cleaned up`);
    }
  }, CLEANUP_DELAY_MS);
  session.cleanupTimer.unref?.();
}

function scheduleMacAbsenceTimeout(
  sessionId,
  {
    macAbsenceGraceMs,
    setTimeoutFn = setTimeout,
    clearTimeoutFn = clearTimeout,
  } = {}
) {
  const session = sessions.get(sessionId);
  if (!session || session.mac || session.macAbsenceTimer) {
    return;
  }

  session.macAbsenceTimer = setTimeoutFn(() => {
    const activeSession = sessions.get(sessionId);
    if (!activeSession) {
      return;
    }

    activeSession.macAbsenceTimer = null;
    activeSession.notificationSecret = null;
    unregisterLiveMacSession(activeSession.macRegistration, sessionId);
    closeSessionClients(activeSession, CLOSE_CODE_SESSION_UNAVAILABLE, "Mac disconnected");
    scheduleCleanup(sessionId, { setTimeoutFn });
  }, macAbsenceGraceMs);
  session.macAbsenceTimer.unref?.();

  if (session.cleanupTimer) {
    clearTimeoutFn(session.cleanupTimer);
    session.cleanupTimer = null;
  }
}

function clearMacAbsenceTimer(session, { clearTimeoutFn = clearTimeout } = {}) {
  if (!session?.macAbsenceTimer) {
    return;
  }

  clearTimeoutFn(session.macAbsenceTimer);
  session.macAbsenceTimer = null;
}

function canAcceptIphoneConnection(session) {
  if (!session) {
    return false;
  }

  if (session.mac?.readyState === WebSocket.OPEN) {
    return true;
  }

  // Lets the phone rejoin the same relay session while the Mac is still inside
  // the temporary-absence grace window instead of forcing a full disconnect flow.
  return Boolean(session.macAbsenceTimer);
}

function closeSessionClients(session, code, reason) {
  for (const client of session.clients) {
    if (client.readyState === WebSocket.OPEN || client.readyState === WebSocket.CONNECTING) {
      client.close(code, reason);
    }
  }
}

function relaySessionLogLabel(sessionId) {
  const normalizedSessionId = typeof sessionId === "string" ? sessionId.trim() : "";
  if (!normalizedSessionId) {
    return "session=[redacted]";
  }

  const digest = createHash("sha256")
    .update(normalizedSessionId)
    .digest("hex")
    .slice(0, 8);
  return `session#${digest}`;
}

// Resolves the current live relay session for a previously trusted Mac without exposing the session id publicly.
function resolveTrustedMacSession({
  now = Date.now(),
  ...request
} = {}) {
  const resolved = resolveTrustedRelayTarget({
    ...request,
    now,
  });
  usedResolveNonces.set(resolved.nonceKey, now + TRUSTED_SESSION_RESOLVE_SKEW_MS);
  return {
    ok: true,
    macDeviceId: resolved.macDeviceId,
    macIdentityPublicKey: resolved.liveSession.macIdentityPublicKey,
    displayName: resolved.liveSession.displayName || null,
    sessionId: resolved.liveSession.sessionId,
    resumeKey: resolved.liveSession.sessionId,
  };
}

// Resolves a trusted Mac into an opaque short-lived device-channel token instead of exposing the live session id.
function resolveTrustedDeviceConnection({
  now = Date.now(),
  ...request
} = {}) {
  const resolved = resolveTrustedRelayTarget({
    ...request,
    now,
  });
  usedResolveNonces.set(resolved.nonceKey, now + TRUSTED_SESSION_RESOLVE_SKEW_MS);
  return {
    ok: true,
    macDeviceId: resolved.macDeviceId,
    macIdentityPublicKey: resolved.liveSession.macIdentityPublicKey,
    displayName: resolved.liveSession.displayName || null,
    sessionId: resolved.liveSession.sessionId,
    deviceChannelTarget: issueDeviceChannelTarget(resolved.liveSession, { now }),
    connectionMode: "persistent_device_channel",
    resumeKey: resolved.liveSession.sessionId,
  };
}

function resolveTrustedRelayTarget({
  macDeviceId,
  phoneDeviceId,
  phoneIdentityPublicKey,
  timestamp,
  nonce,
  signature,
  now,
} = {}) {
  const normalizedMacDeviceId = normalizeNonEmptyString(macDeviceId);
  const normalizedPhoneDeviceId = normalizeNonEmptyString(phoneDeviceId);
  const normalizedPhoneIdentityPublicKey = normalizeNonEmptyString(phoneIdentityPublicKey);
  const normalizedNonce = normalizeNonEmptyString(nonce);
  const normalizedSignature = normalizeNonEmptyString(signature);
  const normalizedTimestamp = Number(timestamp);

  if (
    !normalizedMacDeviceId
    || !normalizedPhoneDeviceId
    || !normalizedPhoneIdentityPublicKey
    || !normalizedNonce
    || !normalizedSignature
    || !Number.isFinite(normalizedTimestamp)
  ) {
    throw createRelayError(400, "invalid_request", "The trusted-session resolve request is missing required fields.");
  }

  if (Math.abs(now - normalizedTimestamp) > TRUSTED_SESSION_RESOLVE_SKEW_MS) {
    throw createRelayError(401, "resolve_request_expired", "This trusted-session resolve request has expired.");
  }

  pruneUsedResolveNonces(now);
  const nonceKey = `${normalizedMacDeviceId}|${normalizedPhoneDeviceId}|${normalizedNonce}`;
  if (usedResolveNonces.has(nonceKey)) {
    throw createRelayError(409, "resolve_request_replayed", "This trusted-session resolve request was already used.");
  }

  const liveSession = liveSessionsByMacDeviceId.get(normalizedMacDeviceId);
  if (!liveSession || !hasActiveMacSession(liveSession.sessionId)) {
    throw createRelayError(404, "session_unavailable", "The trusted Mac is offline right now.");
  }

  if (
    liveSession.trustedPhoneDeviceId !== normalizedPhoneDeviceId
    || liveSession.trustedPhonePublicKey !== normalizedPhoneIdentityPublicKey
  ) {
    throw createRelayError(403, "phone_not_trusted", "This iPhone is not trusted for the requested Mac.");
  }

  const transcriptBytes = buildTrustedSessionResolveBytes({
    macDeviceId: normalizedMacDeviceId,
    phoneDeviceId: normalizedPhoneDeviceId,
    phoneIdentityPublicKey: normalizedPhoneIdentityPublicKey,
    nonce: normalizedNonce,
    timestamp: normalizedTimestamp,
  });
  if (!verifyTrustedSessionResolveSignature(
    normalizedPhoneIdentityPublicKey,
    transcriptBytes,
    normalizedSignature
  )) {
    throw createRelayError(403, "invalid_signature", "The trusted-session resolve signature is invalid.");
  }

  return {
    liveSession,
    macDeviceId: normalizedMacDeviceId,
    nonceKey,
  };
}

// Resolves the bootstrap metadata behind a short-lived manual pairing code.
function resolvePairingCode({
  code,
  now = Date.now(),
} = {}) {
  const normalizedCode = normalizeShortPairingCode(code);
  if (!normalizedCode) {
    throw createRelayError(400, "invalid_request", "The pairing code is missing or malformed.");
  }

  const registration = liveSessionsByPairingCode.get(normalizedCode);
  if (!registration || !hasActiveMacSession(registration.sessionId)) {
    throw createRelayError(404, "pairing_code_unavailable", "This pairing code is unavailable.");
  }

  if (!Number.isFinite(registration.pairingExpiresAt) || now > registration.pairingExpiresAt) {
    liveSessionsByPairingCode.delete(normalizedCode);
    throw createRelayError(410, "pairing_code_expired", "This pairing code has expired.");
  }

  if (
    !registration.macDeviceId
    || !registration.macIdentityPublicKey
    || !Number.isFinite(registration.pairingVersion)
  ) {
    throw createRelayError(409, "pairing_code_incomplete", "The bridge pairing metadata is incomplete.");
  }

  return {
    ok: true,
    v: registration.pairingVersion,
    sessionId: registration.sessionId,
    macDeviceId: registration.macDeviceId,
    macIdentityPublicKey: registration.macIdentityPublicKey,
    expiresAt: registration.pairingExpiresAt,
  };
}

// Exposes lightweight runtime stats for health/status endpoints.
function getRelayStats() {
  let totalClients = 0;
  let sessionsWithMac = 0;

  for (const session of sessions.values()) {
    totalClients += session.clients.size;
    if (session.mac) {
      sessionsWithMac += 1;
    }
  }

  return {
    activeSessions: sessions.size,
    sessionsWithMac,
    totalClients,
    pairingCodes: liveSessionsByPairingCode.size,
    deviceChannelTargets: deviceChannelTargets.size,
  };
}

// Lets the push-registration side verify that a session still belongs to a live Mac bridge.
function hasActiveMacSession(sessionId) {
  if (typeof sessionId !== "string" || !sessionId.trim()) {
    return false;
  }

  const session = sessions.get(sessionId.trim());
  return Boolean(session?.mac && session.mac.readyState === WebSocket.OPEN);
}

// Used by: relay/server.js push registration gate.
function hasAuthenticatedMacSession(sessionId, notificationSecret) {
  if (!hasActiveMacSession(sessionId)) {
    return false;
  }

  const session = sessions.get(sessionId.trim());
  return session?.notificationSecret === readHeaderString(notificationSecret);
}

function registerLiveMacSession(macRegistration) {
  if (!macRegistration?.macDeviceId) {
    return;
  }
  liveSessionsByMacDeviceId.set(macRegistration.macDeviceId, macRegistration);
  if (macRegistration.pairingCode && Number.isFinite(macRegistration.pairingExpiresAt)) {
    liveSessionsByPairingCode.set(macRegistration.pairingCode, macRegistration);
  }
}

function applyMacRegistrationMessage(session, sessionId, rawMessage) {
  const parsed = safeParseJSON(rawMessage);
  if (parsed?.kind !== "relayMacRegistration" || typeof parsed.registration !== "object") {
    return false;
  }

  unregisterLiveMacSession(session.macRegistration, sessionId);
  session.macRegistration = normalizeMacRegistration(parsed.registration, sessionId);
  registerLiveMacSession(session.macRegistration);
  return true;
}

function unregisterLiveMacSession(macRegistration, sessionId) {
  const macDeviceId = macRegistration?.macDeviceId;
  if (!macDeviceId) {
    return;
  }

  const existing = liveSessionsByMacDeviceId.get(macDeviceId);
  if (existing?.sessionId === sessionId) {
    liveSessionsByMacDeviceId.delete(macDeviceId);
  }

  const pairingCode = macRegistration?.pairingCode;
  if (pairingCode) {
    const existingPairingCode = liveSessionsByPairingCode.get(pairingCode);
    if (existingPairingCode?.sessionId === sessionId) {
      liveSessionsByPairingCode.delete(pairingCode);
    }
  }
}

function readMacRegistrationHeaders(headers, sessionId) {
  return normalizeMacRegistration({
    macDeviceId: readHeaderString(headers["x-mac-device-id"]),
    macIdentityPublicKey: readHeaderString(headers["x-mac-identity-public-key"]),
    displayName: readHeaderString(headers["x-machine-name"]),
    bridgeAddressingMode: readHeaderString(headers["x-bridge-addressing-mode"]),
    bridgeChannelType: readHeaderString(headers["x-bridge-channel-type"]),
    supportsTrustedDeviceConnect: readHeaderString(headers["x-supports-trusted-device-connect"]),
    supportsTrustedSessionResolve: readHeaderString(headers["x-supports-trusted-session-resolve"]),
    bridgeTransport: readHeaderString(headers["x-bridge-transport"]),
    secureProtocolVersion: readHeaderString(headers["x-secure-protocol-version"]),
    trustedPhoneDeviceId: readHeaderString(headers["x-trusted-phone-device-id"]),
    trustedPhonePublicKey: readHeaderString(headers["x-trusted-phone-public-key"]),
    pairingCode: readHeaderString(headers["x-pairing-code"]),
    pairingVersion: readHeaderString(headers["x-pairing-version"]),
    pairingExpiresAt: readHeaderString(headers["x-pairing-expires-at"]),
  }, sessionId);
}

function normalizeMacRegistration(registration, sessionId) {
  return {
    sessionId,
    macDeviceId: normalizeNonEmptyString(registration?.macDeviceId),
    macIdentityPublicKey: normalizeNonEmptyString(registration?.macIdentityPublicKey),
    displayName: normalizeNonEmptyString(registration?.displayName),
    bridgeAddressingMode: normalizeNonEmptyString(registration?.bridgeAddressingMode),
    bridgeChannelType: normalizeNonEmptyString(registration?.bridgeChannelType),
    supportsTrustedDeviceConnect: normalizeBoolean(registration?.supportsTrustedDeviceConnect),
    supportsTrustedSessionResolve: normalizeBoolean(registration?.supportsTrustedSessionResolve),
    bridgeTransport: normalizeNonEmptyString(registration?.bridgeTransport),
    secureProtocolVersion: normalizePositiveInteger(registration?.secureProtocolVersion),
    trustedPhoneDeviceId: normalizeNonEmptyString(registration?.trustedPhoneDeviceId),
    trustedPhonePublicKey: normalizeNonEmptyString(registration?.trustedPhonePublicKey),
    pairingCode: normalizeShortPairingCode(registration?.pairingCode),
    pairingVersion: normalizePositiveInteger(registration?.pairingVersion),
    pairingExpiresAt: normalizePositiveInteger(registration?.pairingExpiresAt),
  };
}

function issueDeviceChannelTarget(liveSession, { now = Date.now() } = {}) {
  pruneExpiredDeviceChannelTargets(now);
  const token = `${DEVICE_CHANNEL_TOKEN_PREFIX}${randomBytes(18).toString("base64url")}`;
  deviceChannelTargets.set(token, {
    macDeviceId: liveSession.macDeviceId,
    expiresAt: now + DEVICE_CHANNEL_TOKEN_TTL_MS,
  });
  return token;
}

function resolveIphoneTargetSessionId(requestedSessionId, now = Date.now()) {
  const normalizedSessionId = normalizeNonEmptyString(requestedSessionId);
  if (!normalizedSessionId.startsWith(DEVICE_CHANNEL_TOKEN_PREFIX)) {
    return normalizedSessionId;
  }

  pruneExpiredDeviceChannelTargets(now);
  const target = deviceChannelTargets.get(normalizedSessionId);
  if (!target || now >= target.expiresAt) {
    deviceChannelTargets.delete(normalizedSessionId);
    return "";
  }

  const macDeviceId = normalizeNonEmptyString(target.macDeviceId);
  if (!macDeviceId) {
    deviceChannelTargets.delete(normalizedSessionId);
    return "";
  }

  const liveSession = liveSessionsByMacDeviceId.get(macDeviceId);
  if (!liveSession || !hasActiveMacSession(liveSession.sessionId)) {
    return "";
  }

  return normalizeNonEmptyString(liveSession.sessionId);
}

function pruneExpiredDeviceChannelTargets(now) {
  for (const [token, target] of deviceChannelTargets.entries()) {
    if (!target || now >= target.expiresAt) {
      deviceChannelTargets.delete(token);
    }
  }
}

function buildTrustedSessionResolveBytes({
  macDeviceId,
  phoneDeviceId,
  phoneIdentityPublicKey,
  nonce,
  timestamp,
}) {
  return Buffer.concat([
    encodeLengthPrefixedUTF8(TRUSTED_SESSION_RESOLVE_TAG),
    encodeLengthPrefixedUTF8(macDeviceId),
    encodeLengthPrefixedUTF8(phoneDeviceId),
    encodeLengthPrefixedData(Buffer.from(phoneIdentityPublicKey, "base64")),
    encodeLengthPrefixedUTF8(nonce),
    encodeLengthPrefixedUTF8(String(timestamp)),
  ]);
}

function verifyTrustedSessionResolveSignature(publicKeyBase64, transcriptBytes, signatureBase64) {
  try {
    return verify(
      null,
      transcriptBytes,
      createPublicKey({
        key: {
          crv: "Ed25519",
          kty: "OKP",
          x: base64ToBase64Url(publicKeyBase64),
        },
        format: "jwk",
      }),
      Buffer.from(signatureBase64, "base64")
    );
  } catch {
    return false;
  }
}

function pruneUsedResolveNonces(now) {
  for (const [nonceKey, expiresAt] of usedResolveNonces.entries()) {
    if (now >= expiresAt) {
      usedResolveNonces.delete(nonceKey);
    }
  }
}

function encodeLengthPrefixedUTF8(value) {
  return encodeLengthPrefixedData(Buffer.from(value, "utf8"));
}

function encodeLengthPrefixedData(value) {
  const length = Buffer.allocUnsafe(4);
  length.writeUInt32BE(value.length, 0);
  return Buffer.concat([length, value]);
}

function base64ToBase64Url(value) {
  return String(value || "")
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/g, "");
}

function normalizeNonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function normalizeShortPairingCode(value) {
  if (typeof value !== "string") {
    return "";
  }

  const normalized = value
    .trim()
    .toUpperCase()
    .replace(/[\s-]+/g, "");
  if (
    normalized.length < SHORT_PAIRING_CODE_MIN_LENGTH
    || normalized.length > SHORT_PAIRING_CODE_MAX_LENGTH
    || !/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]+$/.test(normalized)
  ) {
    return "";
  }

  return normalized;
}

function normalizePositiveInteger(value) {
  const normalized = Number(value);
  return Number.isFinite(normalized) && normalized > 0 ? normalized : 0;
}

function normalizeBoolean(value) {
  if (value === true || value === "true" || value === "1" || value === 1) {
    return true;
  }

  if (value === false || value === "false" || value === "0" || value === 0) {
    return false;
  }

  return false;
}

function createRelayError(status, code, message) {
  return Object.assign(new Error(message), {
    status,
    code,
  });
}

function readHeaderString(value) {
  const candidate = Array.isArray(value) ? value[0] : value;
  return typeof candidate === "string" && candidate.trim() ? candidate.trim() : null;
}

function safeParseJSON(value) {
  if (typeof value !== "string" || !value.trim()) {
    return null;
  }

  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

module.exports = {
  setupRelay,
  getRelayStats,
  hasActiveMacSession,
  hasAuthenticatedMacSession,
  resolvePairingCode,
  resolveTrustedDeviceConnection,
  resolveTrustedMacSession,
};

// FILE: qr.js
// Purpose: Prints the bridge pairing payload as both QR and a short terminal-friendly pairing code.
// Layer: CLI helper
// Exports: SHORT_PAIRING_CODE_ALPHABET, SHORT_PAIRING_CODE_LENGTH, createShortPairingCode, printQR
// Depends on: crypto, qrcode-terminal

const { createHash, randomBytes } = require("crypto");
const qrcode = require("qrcode-terminal");

const SHORT_PAIRING_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const SHORT_PAIRING_CODE_LENGTH = 10;

// Generates a short-lived human-friendly pairing token for reconnect flows.
function createShortPairingCode({
  length = SHORT_PAIRING_CODE_LENGTH,
  randomBytesImpl = randomBytes,
} = {}) {
  const resolvedLength = Number.isInteger(length) && length > 0 ? length : SHORT_PAIRING_CODE_LENGTH;
  const bytes = randomBytesImpl(resolvedLength);
  let code = "";
  for (let index = 0; index < resolvedLength; index += 1) {
    code += SHORT_PAIRING_CODE_ALPHABET[bytes[index] % SHORT_PAIRING_CODE_ALPHABET.length];
  }
  return code;
}

function normalizePairingSession(pairingSessionOrPayload) {
  if (pairingSessionOrPayload?.pairingPayload) {
    return {
      pairingPayload: pairingSessionOrPayload.pairingPayload,
      pairingCode: typeof pairingSessionOrPayload.pairingCode === "string"
        ? pairingSessionOrPayload.pairingCode.trim()
        : "",
    };
  }

  return {
    pairingPayload: pairingSessionOrPayload,
    pairingCode: "",
  };
}

function fingerprintSessionId(sessionId) {
  const value = typeof sessionId === "string" ? sessionId.trim() : "";
  if (!value) {
    return "unavailable";
  }

  return `sha256:${createHash("sha256").update(value).digest("hex").slice(0, 12)}`;
}

function printQR(pairingSessionOrPayload, { consoleImpl = console, qrcodeImpl = qrcode } = {}) {
  const { pairingPayload, pairingCode } = normalizePairingSession(pairingSessionOrPayload);
  const payload = JSON.stringify(pairingPayload);

  consoleImpl.log("\nScan this QR with the iPhone:\n");
  qrcodeImpl.generate(payload, { small: true });
  if (pairingCode) {
    consoleImpl.log("Or paste this pairing code in the iPhone app:\n");
    consoleImpl.log(pairingCode);
  }
  consoleImpl.log(`\nPairing Session: ${fingerprintSessionId(pairingPayload.sessionId)}`);
  consoleImpl.log(`Device ID: ${pairingPayload.macDeviceId}`);
  consoleImpl.log(`Expires: ${new Date(pairingPayload.expiresAt).toISOString()}\n`);
}

module.exports = {
  SHORT_PAIRING_CODE_ALPHABET,
  SHORT_PAIRING_CODE_LENGTH,
  createShortPairingCode,
  fingerprintSessionId,
  printQR,
};

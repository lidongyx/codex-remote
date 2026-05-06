// FILE: qr.test.js
// Purpose: Verifies pairing codes stay human-sized and QR printing avoids raw session leaks.
// Layer: Unit Test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/qr

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  SHORT_PAIRING_CODE_ALPHABET,
  SHORT_PAIRING_CODE_LENGTH,
  createShortPairingCode,
  printQR,
} = require("../src/qr");

test("createShortPairingCode emits a short human-friendly token", () => {
  const code = createShortPairingCode({
    randomBytesImpl() {
      return Buffer.from([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    },
  });

  assert.equal(code.length, SHORT_PAIRING_CODE_LENGTH);
  assert.match(code, new RegExp(`^[${SHORT_PAIRING_CODE_ALPHABET}]+$`));
});

test("printQR logs a session fingerprint instead of the raw session id", () => {
  const logs = [];
  const qrcodeCalls = [];
  const pairingPayload = {
    relay: "ws://127.0.0.1:9000/relay",
    sessionId: "session-secret-123",
    macDeviceId: "mac-device-7",
    expiresAt: "2026-04-22T12:00:00.000Z",
  };
  printQR(
    {
      pairingPayload,
      pairingCode: "ABCDEFGHJK",
    },
    {
      consoleImpl: {
        log(message) {
          logs.push(String(message));
        },
      },
      qrcodeImpl: {
        generate(payload, options) {
          qrcodeCalls.push({ payload, options });
        },
      },
    }
  );

  assert.equal(qrcodeCalls.length, 1);
  assert.equal(qrcodeCalls[0].payload, JSON.stringify(pairingPayload));
  assert.deepEqual(qrcodeCalls[0].options, { small: true });
  assert.equal(logs.some((message) => message.includes(pairingPayload.sessionId)), false);
  assert.equal(logs.some((message) => message.includes("Session ID: session-…")), true);
  assert.equal(logs.some((message) => message.includes("Device ID: mac-device-7")), true);
  assert.equal(logs.some((message) => message.includes("ABCDEFGHJK")), true);
});

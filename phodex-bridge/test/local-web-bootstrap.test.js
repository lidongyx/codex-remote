// FILE: local-web-bootstrap.test.js
// Purpose: Verifies the local Web pairing bootstrap helper.
// Layer: Unit test
// Depends on: node:test, node:assert/strict, ../src/local-web-bootstrap

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  BOOTSTRAP_PATH,
  createLocalWebBootstrapServer,
  normalizeLocalWebBootstrapConfig,
} = require("../src/local-web-bootstrap");

test("local Web bootstrap serves the current pairing payload without caching", async () => {
  const pairingPayload = {
    v: 2,
    relay: "ws://127.0.0.1:9000/relay",
    sessionId: "session-local-web",
    macDeviceId: "mac-local-web",
    macIdentityPublicKey: "mac-key",
    expiresAt: 123456,
  };
  const bootstrap = createLocalWebBootstrapServer({
    host: "127.0.0.1",
    port: 0,
    pairingSession: {
      pairingPayload,
      pairingCode: "12345678",
    },
    logger: silentLogger(),
  });

  try {
    await bootstrap.ready;
    const response = await fetch(`http://${bootstrap.host}:${bootstrap.port}${BOOTSTRAP_PATH}`);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.equal(response.headers.get("access-control-allow-origin"), "*");
    assert.deepEqual(await response.json(), {
      ok: true,
      pairingPayload,
      pairingCode: "12345678",
    });
  } finally {
    bootstrap.close();
  }
});

test("local Web bootstrap can refresh pairing payloads per request", async () => {
  let expiresAt = 1000;
  const bootstrap = createLocalWebBootstrapServer({
    host: "127.0.0.1",
    port: 0,
    getPairingSession() {
      expiresAt += 1000;
      return {
        pairingPayload: {
          v: 2,
          relay: "ws://127.0.0.1:9000/relay",
          sessionId: "session-local-web",
          macDeviceId: "mac-local-web",
          macIdentityPublicKey: "mac-key",
          expiresAt,
        },
        pairingCode: "12345678",
      };
    },
    logger: silentLogger(),
  });

  try {
    await bootstrap.ready;
    const firstResponse = await fetch(`http://${bootstrap.host}:${bootstrap.port}${BOOTSTRAP_PATH}`);
    const secondResponse = await fetch(`http://${bootstrap.host}:${bootstrap.port}${BOOTSTRAP_PATH}`);
    assert.equal((await firstResponse.json()).pairingPayload.expiresAt, 2000);
    assert.equal((await secondResponse.json()).pairingPayload.expiresAt, 3000);
  } finally {
    bootstrap.close();
  }
});

test("local Web bootstrap can be disabled", () => {
  const bootstrap = createLocalWebBootstrapServer({ enabled: false });
  assert.equal(bootstrap.port, 0);
  assert.doesNotThrow(() => bootstrap.close());
});

test("normalizeLocalWebBootstrapConfig keeps loopback defaults", () => {
  assert.deepEqual(normalizeLocalWebBootstrapConfig({}), {
    enabled: true,
    host: "127.0.0.1",
    port: 8787,
  });
  assert.deepEqual(normalizeLocalWebBootstrapConfig({
    REMODEX_WEB_BOOTSTRAP_ENABLED: "false",
    REMODEX_WEB_BOOTSTRAP_HOST: "0.0.0.0",
    REMODEX_WEB_BOOTSTRAP_PORT: "9099",
  }), {
    enabled: false,
    host: "0.0.0.0",
    port: 9099,
  });
});

function silentLogger() {
  return {
    log() {},
    warn() {},
  };
}

// FILE: local-web-bootstrap.js
// Purpose: Serves the current local Web pairing bootstrap payload for browser clients.
// Layer: CLI helper
// Exports: createLocalWebBootstrapServer, normalizeLocalWebBootstrapConfig
// Depends on: http

const http = require("http");

const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 8787;
const BOOTSTRAP_PATH = "/local-web/bootstrap";

function createLocalWebBootstrapServer({
  pairingSession,
  getPairingSession = null,
  host = DEFAULT_HOST,
  port = DEFAULT_PORT,
  enabled = true,
  logger = console,
  createServerImpl = http.createServer,
} = {}) {
  if (!enabled) {
    return createNoopServer();
  }

  const normalizedHost = normalizeHost(host);
  const normalizedPort = normalizePort(port);
  let resolveReady;
  const ready = new Promise((resolve) => {
    resolveReady = resolve;
  });
  const server = createServerImpl((req, res) => {
    const pathname = safePathname(req.url);
    if (req.method === "OPTIONS" && pathname === BOOTSTRAP_PATH) {
      writeCorsHeaders(res);
      res.writeHead(204);
      res.end();
      return;
    }

    if (req.method !== "GET" || pathname !== BOOTSTRAP_PATH) {
      writeJSON(res, 404, { ok: false, error: "Not found" });
      return;
    }

    const currentPairingSession = typeof getPairingSession === "function"
      ? getPairingSession()
      : pairingSession;
    writeJSON(res, 200, {
      ok: true,
      pairingPayload: currentPairingSession?.pairingPayload || null,
      pairingCode: currentPairingSession?.pairingCode || null,
    });
  });

  let listening = false;
  server.on?.("error", (error) => {
    logger.warn?.(`[remodex] local Web bootstrap unavailable: ${error.message}`);
  });
  server.listen(normalizedPort, normalizedHost, () => {
    listening = true;
    resolveReady?.();
    logger.log?.(`[remodex] local Web bootstrap listening on http://${normalizedHost}:${normalizedPort}${BOOTSTRAP_PATH}`);
  });

  return {
    host: normalizedHost,
    get port() {
      const address = server.address?.();
      return address && typeof address === "object" && Number.isFinite(address.port)
        ? address.port
        : normalizedPort;
    },
    path: BOOTSTRAP_PATH,
    ready,
    close() {
      if (listening) {
        server.close?.();
      }
    },
  };
}

function normalizeLocalWebBootstrapConfig(env = process.env) {
  const enabled = !isExplicitFalse(env.REMODEX_WEB_BOOTSTRAP_ENABLED);
  return {
    enabled,
    host: normalizeHost(env.REMODEX_WEB_BOOTSTRAP_HOST || DEFAULT_HOST),
    port: normalizePort(env.REMODEX_WEB_BOOTSTRAP_PORT || DEFAULT_PORT),
  };
}

function createNoopServer() {
  return {
    host: "",
    port: 0,
    path: BOOTSTRAP_PATH,
    close() {},
    ready: Promise.resolve(),
  };
}

function writeJSON(res, statusCode, payload) {
  writeCorsHeaders(res);
  res.writeHead(statusCode, { "content-type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(payload));
}

function writeCorsHeaders(res) {
  res.setHeader("access-control-allow-origin", "*");
  res.setHeader("access-control-allow-methods", "GET, OPTIONS");
  res.setHeader("access-control-allow-headers", "content-type");
  res.setHeader("cache-control", "no-store");
}

function safePathname(rawUrl) {
  try {
    return new URL(rawUrl || "/", "http://127.0.0.1").pathname;
  } catch {
    return "/";
  }
}

function normalizeHost(value) {
  const normalized = typeof value === "string" ? value.trim() : "";
  return normalized || DEFAULT_HOST;
}

function normalizePort(value) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed >= 0 && parsed <= 65535 ? parsed : DEFAULT_PORT;
}

function isExplicitFalse(value) {
  return ["0", "false", "no", "off"].includes(String(value || "").trim().toLowerCase());
}

module.exports = {
  BOOTSTRAP_PATH,
  createLocalWebBootstrapServer,
  normalizeLocalWebBootstrapConfig,
};

# Remodex Web

Local-first browser client for connection mode 1: relay + bridge + Web UI.

See the full guide in [`../Docs/WEB.md`](../Docs/WEB.md) and the Chinese guide in [`../Docs/WEB.zh-CN.md`](../Docs/WEB.zh-CN.md).

## Local dev

```sh
npm install --prefix web
npm run web:dev
```

Start the existing local relay and bridge separately:

```sh
./run-local-remodex.sh
```

The Web UI first tries to read the local bridge bootstrap endpoint at `http://127.0.0.1:8787/local-web/bootstrap`. If it is unavailable, paste the bridge QR pairing payload JSON into the Web UI. The browser connects to `/relay/:sessionId?role=iphone`, completes the same secure handshake used by the iOS app, then sends JSON-RPC through encrypted envelopes.

## Cloudflare Tunnel

The recommended remote shape is one HTTPS origin protected by Cloudflare Access:

- `https://codex.example.com/` -> Web UI
- `wss://codex.example.com/relay/:sessionId?role=iphone` -> local relay
- `https://codex.example.com/local-web/bootstrap` -> bridge bootstrap endpoint

Use the compose file from this directory:

```sh
CLOUDFLARE_TUNNEL_TOKEN=... docker compose -f docker-compose.cloudflare.yml up --build
```

Do not run the tunnel without Cloudflare Access or another authentication layer. This UI controls your local Codex runtime.

Bridge bootstrap env overrides:

- `REMODEX_WEB_BOOTSTRAP_ENABLED=false` disables the endpoint.
- `REMODEX_WEB_BOOTSTRAP_HOST=127.0.0.1` keeps the default loopback binding.
- `REMODEX_WEB_BOOTSTRAP_PORT=8787` changes the local bootstrap port.

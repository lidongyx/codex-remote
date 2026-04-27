# Remodex Web

Remodex Web is a local-first browser client for connection method 1. It uses the same relay + bridge pairing shape as the iOS app, but renders the remote Codex experience in a browser.

## What Runs Where

- The Web UI is served by Vite in development or by the `web/` Docker image in remote setups.
- Codex execution, file access, shell commands, and Git operations still run on the local bridge host.
- The browser connects to the relay as a remote UI and sends encrypted JSON-RPC messages through the existing secure transport.
- The bridge exposes a local bootstrap endpoint so the browser can pair without manually pasting QR JSON when it is running on the same host.

## Local Development

Install dependencies once:

```sh
npm install --prefix web
```

Start the existing local relay and bridge:

```sh
./run-local-remodex.sh
```

Start the Web UI:

```sh
npm run web:dev
```

Open:

```text
http://127.0.0.1:5173/
```

The Web UI first tries `http://127.0.0.1:8787/local-web/bootstrap`. If that endpoint is not available, paste the bridge QR pairing payload JSON into the connection box.

## Basic Web Usage

1. Start the relay and bridge from this repository.
2. Open the Web UI.
3. Let the UI auto-pair from the local bootstrap endpoint, or paste the pairing payload.
4. Open an existing thread, create a new chat, or create a project from a local folder.
5. Send prompts from the composer. The composer supports text, images, text files, model selection, reasoning effort, plan mode, access mode, and local skill selection when the runtime supports it.

On phones, the project/channel list is a slide-out menu opened from the button at the left of the thread title.

## Remote Access With Cloudflare Tunnel, A Domain, And Docker

This setup keeps Remodex local-first: Docker serves the Web UI and `cloudflared` exposes the local Web UI, relay, and bridge bootstrap endpoint through your Cloudflare-managed domain. It does not move Codex execution to Cloudflare.

### Prerequisites

- A domain in Cloudflare DNS.
- A Cloudflare Tunnel created in the Cloudflare Dashboard.
- Cloudflare Access or another authentication layer protecting the public hostname.
- Docker with Compose.
- The local relay and bridge running on the host.

Cloudflare references:

- [Cloudflare Tunnel getting started](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/)
- [Run cloudflared in Docker](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/deployment-guides/docker/)
- [Tunnel public hostnames](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/routing-to-tunnel/)
- [Cloudflare Access applications](https://developers.cloudflare.com/cloudflare-one/applications/)

### 1. Start The Local Relay And Bridge

From the repository root:

```sh
./run-local-remodex.sh
```

Keep this running. The relay listens on `9000`, and the bridge bootstrap endpoint listens on `8787` by default.

### 2. Create A Remotely Managed Tunnel

In the Cloudflare Dashboard:

1. Go to Zero Trust.
2. Create a Tunnel.
3. Choose the `cloudflared` connector.
4. Copy the generated tunnel token.
5. Add a public hostname such as `codex.example.com`.

Configure public hostname routes in this order:

```text
codex.example.com/relay*       -> http://host.docker.internal:9000
codex.example.com/local-web/*  -> http://host.docker.internal:8787
codex.example.com              -> http://web:8080
```

If your dashboard separates host and path, use the same hostname for each route and put `/relay*` and `/local-web/*` in the path field. The root route should point to the Docker service named `web`.

### 3. Protect The Hostname

Before starting the tunnel, create a Cloudflare Access application for the public hostname. Limit access to your account, email domain, identity provider group, or another private policy.

Do not expose this UI as an unauthenticated public website. It controls a local Codex runtime.

### 4. Run Docker Compose

Create `web/.env` locally:

```sh
CLOUDFLARE_TUNNEL_TOKEN=replace-with-your-token
```

Start the Web container and tunnel from the repository root:

```sh
docker compose -f web/docker-compose.cloudflare.yml --env-file web/.env up --build
```

Then open your protected domain:

```text
https://codex.example.com/
```

### 5. Verify The Flow

1. Confirm Cloudflare Access asks you to authenticate.
2. Confirm the Web UI loads after authentication.
3. Confirm the status changes to connected.
4. Open or create a thread and send a small prompt.
5. Keep the local Mac awake while turns are running.

### 6. Operational Notes

- Do not commit `.env`, tunnel tokens, pairing payloads, relay session IDs, or private domains.
- Rotate the tunnel token if it is exposed.
- Prefer a dedicated subdomain for the Web UI.
- If Docker runs on Linux and `host.docker.internal` is unavailable, keep the `host-gateway` mapping in `web/docker-compose.cloudflare.yml` or replace the service targets with the host LAN IP.
- If the browser cannot connect to the relay, check that the `/relay*` route points at the relay origin and that WebSocket traffic is allowed through the tunnel.


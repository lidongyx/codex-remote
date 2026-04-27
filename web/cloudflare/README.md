# Cloudflare Tunnel for Remodex Web

For the full English guide, see [`../../Docs/WEB.md`](../../Docs/WEB.md). For Chinese, see [`../../Docs/WEB.zh-CN.md`](../../Docs/WEB.zh-CN.md).

Recommended setup:

1. Create a remotely-managed Cloudflare Tunnel in the Cloudflare Dashboard.
2. Add a public hostname such as `codex.example.com`.
3. Protect it with Cloudflare Access before exposing the Web UI.
4. Set `CLOUDFLARE_TUNNEL_TOKEN` in a local `.env` file.
5. Run `docker compose -f docker-compose.cloudflare.yml --env-file .env up --build` from `web/`.

Suggested public hostname routes:

- `codex.example.com` -> `http://web:8080`
- `codex.example.com/relay` -> `http://host.docker.internal:9000/relay`
- `codex.example.com/local-web/*` -> `http://host.docker.internal:8787`

Do not commit real tunnel tokens, credentials, domains, pairing payloads, or relay session IDs.

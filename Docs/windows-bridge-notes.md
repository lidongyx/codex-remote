# Windows Bridge Notes

This project is still Mac-first, but the bridge can run on Windows for the core pairing and relay flow.

## What Works

- Running the bridge in the foreground with `npm run bridge:up` or `npm run bridge:run`
- Launching `codex app-server` through the Windows-aware bridge path
- QR pairing from the iPhone app
- Relay-based transport and trusted-device state persisted under `~/.remodex`

## What To Avoid

- Do not use `./run-local-remodex.sh` on Windows. That script is written for the local Mac workflow.
- Do not assume the macOS launch agent commands apply. `bridge:start`, `bridge:restart`, `bridge:stop`, and `bridge:status` are meant for the macOS service flow.
- Do not assume Mac-only desktop features will work on Windows.

## Recommended Windows Flow

1. Install Node.js 18+ and make sure `codex` is available in `PATH`.
2. Start a relay that your iPhone can reach.
3. Set `REMODEX_RELAY` to that relay URL.
4. Start the bridge in the foreground:

```sh
REMODEX_RELAY="ws://<your-host>:9000/relay" npm run bridge:up
```

5. Keep that terminal open while pairing and while the phone is connected.

## Operational Caveats

- The built-in background daemon path is currently macOS-only.
- If you want the bridge to survive logouts, reboots, or terminal closes on Windows, you need your own process manager or service wrapper.
- If you restart the bridge with a fresh pairing session, re-scan the newest QR or pairing code.

## Related Docs

- [README.md](../README.md)
- [Docs/self-hosting.md](self-hosting.md)
- [Docs/windows-bridge-notes.zh-CN.md](windows-bridge-notes.zh-CN.md)

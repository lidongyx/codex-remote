# Codex Remote

For a Simplified Chinese version of this guide, see [README.zh-CN.md](README.zh-CN.md).

Codex Remote is a local-first workspace for controlling Codex from iPhone while keeping execution, git operations, and repository access on your own Mac.

This repository focuses on local and self-hosted workflows. It does not assume a hosted production service or hardcoded public endpoint.

> Note
> The repository name is `codex-remote`, while some app names, CLI commands, package names, bundle identifiers, and internal paths still use `remodex` or `phodex`. Those compatibility names remain in place during the ongoing rename.

## Overview

This repository currently contains:

- an iOS client in `CodexMobile/`
- a local Node.js bridge in `phodex-bridge/`
- a self-hostable relay in `relay/`
- root maintenance scripts in `package.json`
- a local bootstrap script in `./run-local-remodex.sh`

The intended flow is simple:

1. Start the local relay and bridge on your Mac.
2. Build the iOS app from source.
3. Pair the iPhone with the Mac by scanning the QR code.
4. Use the phone as a remote Codex client while the Mac remains the execution host.

## Prerequisites

- macOS for the primary local workflow
- Node.js 18+
- [Codex CLI](https://github.com/openai/codex) installed and available in `PATH`
- Xcode 16+ if you want to build the iOS app from source
- an iPhone for on-device pairing and testing

## Quick Start

Install Node dependencies for the bridge and relay:

```sh
npm run bootstrap:node
```

Build the iOS app from source:

```sh
cd CodexMobile
open CodexMobile.xcodeproj
```

In Xcode:

1. Select your signing team.
2. Build the `CodexMobile` target onto your device.

Start the local development stack from the repository root:

```sh
./run-local-remodex.sh
```

You can also use the root scripts directly:

```sh
npm run dev:relay
npm run dev:bridge
npm run dev:local
```

For bridge lifecycle commands, use the repo-local CLI wrapper instead of a globally installed `remodex` package:

```sh
npm run bridge:status
npm run bridge:up
```

Windows note:

- If your bridge host is Windows, use `npm run bridge:up` or `npm run bridge:run` instead of `./run-local-remodex.sh`.
- The Windows bridge path is currently foreground-only. The macOS launch agent and related service-management commands do not apply there.
- Pairing and relay routing can still work on Windows, but you must manage process persistence yourself.
- See [Docs/windows-bridge-notes.md](Docs/windows-bridge-notes.md) for the detailed Windows setup notes.

After startup:

1. Open the app on your iPhone.
2. Scan the QR code shown in the terminal from inside the app.
3. Start a thread and verify that Codex responses stream back through your Mac.

If you only want to run the bridge manually:

```sh
cd phodex-bridge
npm install
REMODEX_RELAY="ws://<your-host>:9000/relay" npm start
```

You can also invoke the same bridge CLI from the repository root without installing any external global package:

```sh
REMODEX_RELAY="ws://<your-host>:9000/relay" npm run bridge:up
```

## Using The Source Bridge With A Self-Hosted Relay

When you are debugging pairing or reconnect behavior against your own relay, prefer launching the bridge from this repository instead of using a globally installed `remodex` package.

The repository already contains the bridge npm package in `phodex-bridge/`, and the root wrapper `./scripts/remodex-local.js` exposes it as a first-class repo command. For normal repo workflows, users do not need to install an external `remodex` package.

Use:

```sh
REMODEX_RELAY="wss://relay.example.com/relay" npm run bridge:up
```

That command does all of the following:

- writes the relay URL into `~/.remodex/daemon-config.json`
- refreshes `~/.remodex/pairing-session.json`
- rewrites the macOS launch agent to point at `./phodex-bridge/bin/remodex.js`
- prints a fresh QR code and pairing code for the current bridge session

Important:

- Do **not** use a plain global `remodex up` while validating local bridge changes.
- A global install rewrites the launch agent back to `/usr/local/lib/node_modules/remodex/bin/remodex.js`, which means you are no longer running the bridge code from this repository.

You can verify which bridge the launch agent is using with:

```sh
launchctl print gui/$(id -u)/com.remodex.bridge | sed -n '1,30p'
```

The `arguments` block should point at the source checkout when you are testing local bridge changes:

```text
/Users/<you>/Documents/codex-remote/phodex-bridge/bin/remodex.js
```

If you need to pair again, generate a fresh QR or pairing code from the same source-bridge command above and scan that exact session. Every new `up` run creates a new pairing session, so older codes should be treated as expired.

## Repository Layout

```text
.
├── CodexMobile/          iOS app source and Xcode project
├── phodex-bridge/        local Node.js bridge and CLI entrypoint
├── relay/                self-hostable WebSocket relay
├── Docs/                 project notes and supplementary docs
├── package.json          root scripts for bridge and relay maintenance
└── run-local-remodex.sh  local launcher for relay + bridge
```

## Project Status

- This is still an actively evolving codebase.
- Local-first behavior is the priority.
- Some naming and compatibility details are still being migrated from upstream.

## Acknowledgements

This project builds on the open-source work of [`remodex`](https://github.com/Emanuele-web04/remodex) by Emanuele Di Pietro.

Many design decisions, transport ideas, and parts of the implementation originated from that upstream project. This repository is not just a rebranded copy, but it clearly benefits from that earlier work. Thanks to the original author and contributors.

If you fork, redistribute, or continue adapting this codebase, keep the applicable upstream copyright and license notices intact.

## License

This repository is distributed under the ISC license. See [LICENSE](LICENSE).

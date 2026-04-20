# Version 2.0 Workspace

This directory is an isolated V2 workspace for a clean-slate redesign.

It contains:

- `CodexMobile/`
  - A direct copy of the current iOS codebase snapshot.
- `phodex-bridge/`
  - A direct copy of the current bridge codebase snapshot.
- `relay/`
  - A direct copy of the current relay codebase snapshot.
- `V2_ARCHITECTURE.md`
  - The clean-slate V2 architecture proposal.
- `V2_REMOTE_FIRST_REQUIREMENTS.md`
  - The non-negotiable product constraints for the remote-first redesign.
- `V2_IMPLEMENTATION_ROADMAP.md`
  - The concrete execution plan for turning V2 into code.

Rules for this workspace:

- No backward-compatibility requirement with the current shipping stack.
- No obligation to preserve the current local relay + Node bridge topology.
- Performance and architectural clarity take priority over incremental migration cost.
- V2 is remote-first.
- The primary product goal is internet-scale remote control of Codex running on a distant Mac.
- Installation and day-1 usability matter as much as transport performance.
- The default V2 transport path should not require the user to install a private overlay network.
- Private overlay networking in the Tailscale / Headscale / WireGuard class is an optional acceleration path, not the default product assumption.
- Current production-like code outside this folder stays untouched.

Snapshot intent:

- Keep the current implementation available for comparison.
- Make V2 design and implementation work self-contained.
- Avoid contaminating the existing shipping path while V2 is being designed.

## Current Status

V2 is not finished.

Already implemented:

- Rust workspace in this folder
- first-pass protocol schema drafts in `proto/`
- `codex-relay-rs` executable skeleton
- `codexd` executable skeleton
- relay-backed presence registration and session resolve
- liveness-aware session invalidation when the Mac daemon disconnects
- relay-backed protobuf application request / response flow
- placeholder remote run lifecycle:
  - session resume
  - thread list
  - run start
  - reasoning delta
  - assistant delta
  - run completion

Not implemented yet:

- iOS V2 client integration
- final binary application protocol
- real Codex runtime integration
- final trust bootstrap flow
- final reconnect / catch-up product behavior

## Current Dev Run

You can run the current V2 relay + daemon skeleton locally:

```sh
cd "version 2.0"
./scripts/dev-up.sh
```

In another terminal:

```sh
cd "version 2.0"
./scripts/dev-smoke.sh
```

What this validates today:

- relay process is alive
- daemon process is alive
- daemon registered remote presence with the relay
- relay can resolve the current live remote session for the daemon
- a phone-side probe can connect through the relay and receive protobuf session responses
- a phone-side probe can start a placeholder remote run and receive streamed run lifecycle events

The scripts are for development only.

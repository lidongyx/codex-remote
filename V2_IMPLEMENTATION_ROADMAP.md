# V2 Implementation Roadmap

## Objective

Turn the V2 architecture into code from the repository root without bringing back the retired duplicate legacy tree.

## Phase 0: Freeze The Legacy Snapshot

Done in this workspace:

- copied `CodexMobile/`
- copied `phodex-bridge/`
- copied `relay/`

Next rule:

- legacy copies stay readable for reference
- all new V2 code goes into new top-level V2-specific directories

## Phase 1: Define The New Protocol

Deliverables:

- `proto/transport.proto`
- `proto/session.proto`
- `proto/thread.proto`
- `proto/run.proto`

Decisions to lock:

- protobuf or equivalent typed binary schema
- binary frames over WSS binary messages
- resumable event-log sequence model
- explicit catch-up requests and responses
- relay-backed remote presence model
- optional direct acceleration negotiation hooks

Exit criteria:

- every current mobile-visible state has a protocol representation
- no JSON-RPC dependency remains in the mobile transport contract

## Phase 2: Build `codex-relay-rs`

Deliverables:

- `codex-relay-rs/Cargo.toml`
- remote presence registry
- trusted-device resolve
- binary frame forwarding
- reconnect session registry
- optional push sidecar

Suggested approach:

- study `missuo/remodex-relay`
- reuse ideas where they match the V2 target
- do not inherit old protocol constraints unnecessarily

Exit criteria:

- relay can maintain remote presence for live Macs
- relay can rebind a trusted iPhone to the live Mac
- relay memory and backpressure are measurable and bounded

## Phase 3: Build `codexd`

Deliverables:

- `codexd/Cargo.toml`
- daemon bootstrap
- config loading
- trust store
- runtime supervisor
- persistent outbound relay session
- reconnect session state
- event log

Initial modules:

- `config`
- `relay_client`
- `transport`
- `pairing`
- `trust_store`
- `session_registry`
- `runtime_supervisor`

Exit criteria:

- daemon starts reliably on Mac
- daemon stays present remotely through the relay
- daemon can authenticate and stream to one client

## Phase 4: Build Pairing And Remote Reconnect

Deliverables:

- one-time QR trust bootstrap
- trusted-device reconnect without rescanning
- remote presence lookup
- reconnect token and session resume flow

Behavior goals:

- app can reconnect to a distant Mac without rescanning
- route changes do not force re-pair
- long idle time does not destroy the user’s ability to resume

Exit criteria:

- iPhone can reconnect to a remote Mac across the internet
- reconnect works after app relaunch and after temporary disconnect

## Phase 5: Implement Event Stream And Catch-Up

Deliverables:

- daemon event log
- per-thread watermarks
- catch-up APIs over the new protocol
- mobile timeline reducer for typed deltas

Rules:

- no rollout polling on the primary path
- no heavyweight reopen path as the default
- reconnect asks for deltas since known sequence

Exit criteria:

- opening recent active threads does not require a full heavy snapshot
- Stop / running state comes from event truth, not heuristics

## Phase 6: Runtime Integration

Deliverables:

- Codex runtime supervisor in `codexd`
- structured runtime event mapping
- low-copy streaming path

Targets:

- bounded buffering
- deterministic child-process lifecycle
- efficient delta propagation

Exit criteria:

- a real thread can be started from iPhone through `codexd`
- thinking, tool output, and completion stream through V2 end to end

## Phase 7: Desktop Features

Deliverables:

- continue on Mac
- wake display
- keep-awake preference
- thread handoff metadata

These should be daemon-owned APIs, not ad hoc bridge-side sidecars.

Exit criteria:

- existing desktop affordances work through the new daemon

## Phase 8: Optional Direct Acceleration

Deliverables:

- overlay-direct capability advertisement
- direct-path negotiation
- safe fallback back to relay path

Important rule:

- this phase is optimization, not prerequisite
- the default product path must already be excellent before this starts

Exit criteria:

- advanced users can opt into direct acceleration
- relay-backed path remains the baseline and fallback

## Phase 9: Performance Work

Measure at each phase.

Required benchmark families:

- relay-backed cold connect
- relay-backed warm reconnect
- relay-backed reconnect after long idle
- first assistant delta latency over WAN
- active streaming CPU usage on Mac
- idle daemon memory
- relay session memory
- catch-up reopen latency for large threads

Optimization priorities:

1. eliminate redundant serialization
2. minimize main-thread decoding work on iOS
3. optimize reconnect and catch-up before chasing direct-path transport wins
4. use bounded queues everywhere

## Phase 10: Remove Legacy Dependencies Inside V2

At this point V2 should stop depending on copied legacy code except as behavioral reference.

Delete or stop using inside V2:

- legacy bridge modules
- legacy relay modules
- legacy JSON-RPC mobile transport path
- rollout live mirror primary dependency

## Directory Target

Recommended target structure:

```text
.
├── README.md
├── V2_ARCHITECTURE.md
├── V2_REMOTE_FIRST_REQUIREMENTS.md
├── V2_IMPLEMENTATION_ROADMAP.md
├── CodexMobile/              current iOS app tree
├── phodex-bridge/            transitional bridge/runtime tree
├── relay/                    transitional Node relay tree
├── proto/                    protobuf schemas
├── codexd/                   Rust daemon
├── codex-relay-rs/           Rust relay
└── mobile-ios/               Swift package / extracted V2 client transport
```

## Immediate Next Build Steps

If implementation starts now, the correct order is:

1. evolve `proto/`
2. evolve `codex-relay-rs/`
3. evolve `codexd/`
4. define the handshake, reconnect, and catch-up schema
5. stand up a minimal Rust relay
6. stand up a minimal Rust daemon with persistent relay presence
7. build a tiny iOS V2 test client path before migrating the full UI

This order reduces architecture risk before UI migration cost explodes.

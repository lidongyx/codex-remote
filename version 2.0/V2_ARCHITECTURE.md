# Codex Remote V2 Architecture

## Goal

Build a new architecture for iPhone <-> Mac Codex control that is optimized for:

- robust remote access across the public internet
- strong reconnect behavior after app switching, long idle time, or transient network loss
- low end-to-end latency within the constraints of WAN routing
- low steady-state CPU and memory overhead
- simple installation and low setup friction
- clean, explicit state management

This document intentionally ignores compatibility with the current system.

## Product Direction

V2 is remote-first.

The core use case is:

- the user is on an iPhone
- the Mac is somewhere else
- Codex is running on that distant Mac
- the user wants to reconnect and continue quickly from anywhere

That changes the architecture priorities.

The design center is no longer:

- same room
- same Wi-Fi
- same-LAN discovery

The design center is:

- remote reachability
- reconnect resilience
- simple setup

## Hard V2 Decisions

These are not tentative. They are the baseline assumptions for V2.

1. The current Node.js bridge topology is retired for V2.
2. The product is remote-first, not same-LAN-first.
3. The primary V2 path is relay-backed remote connectivity, not proximity-based direct discovery.
4. WebSocket + JSON-RPC + encrypted JSON envelope layering is retired as the primary application protocol.
5. QR is retained for trust bootstrap, but retired as the normal reconnect locator.
6. The current reconnect state spread across View, ViewModel, and service layers is retired.
7. Rust becomes the primary systems language for relay and daemon core.
8. Private overlay networks are optional optimization paths, not mandatory product dependencies.

## Why WSS Should Be The Default

For this product, `WSS` is the best default transport substrate.

Reasons:

- outbound-only connectivity from both iPhone and Mac is easy to deploy
- avoids requiring inbound public ports on the Mac
- works well behind NAT and typical home networks
- simple reverse proxy story
- straightforward iOS integration
- lower installation friction than requiring Tailscale-class software

For your stated product goals, those advantages matter more than squeezing out the last transport-level latency win.

## WSS Versus Private Overlay Networks

### WSS drawbacks

`WSS` does have real limitations:

- it rides on TCP, so head-of-line blocking is worse than QUIC
- if a relay is in the hot path, there is an extra hop
- text-heavy protocols over WSS waste CPU and bytes
- direct WSS to a home Mac is awkward unless the user exposes a stable public endpoint

But those are not severe enough to disqualify it as the default for this product.

### Private overlay advantages

A private overlay such as Tailscale / Headscale / WireGuard can improve:

- latency
- route stability
- direct peer reachability without public port exposure
- addressing simplicity for advanced users

### Private overlay disadvantages

A private overlay also adds:

- another product the user must install and understand
- account and device enrollment friction
- extra failure modes outside this app
- a worse day-1 setup story for mainstream users

### V2 conclusion

For V2:

- `WSS + relay + persistent daemon presence` should be the default path
- private overlay direct mode should be optional and additive

That gives the best balance of:

- remote usability
- reconnect reliability
- install simplicity

## V2 System Shape

V2 has two runtime roles:

1. `codexd`
   - A Rust daemon running on the Mac.
   - Owns trust state, Codex runtime supervision, thread event streaming, catch-up log persistence, remote presence, reconnect session state, desktop wake/handoff hooks, and optional direct-path negotiation.
2. `codex-relay-rs`
   - A Rust remote relay and rendezvous service.
   - It is part of the default V2 architecture, not an optional afterthought.

The iPhone app becomes a client of `codexd` through the relay-backed session model, not of "relay plus bridge plus compatibility glue".

## Transport Strategy

### Default path

Default path:

1. `codexd` on the Mac opens and maintains an outbound authenticated session to the relay
2. the iPhone app opens an outbound authenticated session to the relay
3. the relay binds the trusted iPhone to the live Mac daemon
4. application payloads stay end-to-end encrypted between iPhone and `codexd`

This default path should use:

- WSS for the connection substrate
- binary frames, not text JSON messages
- protobuf or a similarly compact typed schema

### Optional accelerated path

Optional direct acceleration path:

1. iPhone resolves the remote Mac through relay rendezvous
2. if a configured direct path exists and passes policy checks, the peers upgrade to direct transport
3. otherwise the relay path remains active

Candidate direct paths:

- private overlay direct route
- user-configured public direct route

These are optimization layers, not primary product assumptions.

## Discovery And Pairing

### Remote route resolution

V2 should resolve a remote Mac through relay-mediated remote presence, not through same-LAN discovery.

`codexd` should advertise:

- daemon version
- supported protocol version
- machine name
- peer id
- trust identity
- current route candidates
- last-seen capability set

Route candidates can include:

- relay session target
- overlay identity or address
- optional public direct endpoint

The iPhone should rank those candidates and choose the best viable path automatically.

### Pairing model

QR is retained only as a trust bootstrap tool.

The QR should carry:

- daemon static identity public key
- one-time pairing token
- protocol version
- relay bootstrap metadata
- optional overlay identity metadata

What the QR should not carry as a long-lived reconnect dependency:

- a permanently reused direct host URL
- a live relay session id
- a reconnect target the app depends on every time

### Trust model

Retain the security goal, but simplify implementation:

- Mac has a long-lived static identity key
- iPhone has a long-lived device identity key
- pairing establishes mutual trust
- subsequent sessions authenticate with those identities

The important semantic goal stays the same:

- first scan bootstraps trust
- later reconnects happen without rescanning

## Protocol Shape

### Retire JSON-RPC as the mobile wire protocol

The current stack pays too much overhead:

- encode JSON-RPC
- wrap it in another JSON envelope
- parse repeatedly
- reconstruct state from coarse RPC calls

V2 should use typed binary messages over WSS binary frames.

Suggested protocol families:

- session control
- trust / pairing
- route resolution
- thread list
- thread summary
- run lifecycle
- reasoning delta
- tool execution delta
- catch-up snapshot
- wake / desktop commands

### Event log first, snapshot second

The current system still depends too much on heavyweight reads and replay heuristics.

V2 should be event-log driven:

1. every daemon-originated event gets a monotonic global sequence
2. every thread also has a per-thread sequence
3. the iPhone persists watermarks
4. reconnect asks for deltas since known sequences
5. snapshots exist only for cold repair

That removes the need for:

- rollout-tail primary recovery
- heuristic running-state reconstruction
- reopen-heavy `thread/read` flows

## Catch-Up And Timeline

### Current weakness to eliminate

Reconnect correctness currently depends on too many truth sources:

- live notifications
- replay cursors
- `thread/read`
- `thread/resume`
- rollout mirroring
- fallback active-turn inference

### V2 rule

There must be exactly two truth sources:

1. live daemon event stream
2. daemon event log catch-up

No file-polling reconstruction should be on the primary path.

## State Management

### Current class of problem

Connection truth is currently spread across:

- socket state
- secure session state
- reconnect flags
- scanner takeover flags
- running thread fallbacks
- thread/read repair logic

### V2 coordinator

The mobile side should have one explicit connection state machine:

- `idle`
- `pairing`
- `resolving_remote_presence`
- `connecting_relay`
- `connected_relay`
- `attempting_direct_upgrade`
- `connected_direct`
- `catching_up`
- `degraded`
- `reconnecting`
- `rekey_required`
- `trust_revoked`

And one explicit run-state machine per thread:

- `idle`
- `starting`
- `streaming`
- `finishing`
- `completed`
- `failed`
- `stopped`

The UI reads derived state only.

## Mac Daemon Design

`codexd` should absorb the current bridge responsibilities and remove cross-process churn where possible.

Responsibilities:

- Codex runtime supervision
- trust store
- pairing workflow
- persistent remote presence
- relay session management
- optional direct route advertisement
- thread and run event stream
- catch-up log persistence
- desktop handoff
- wake display commands
- local workspace / git integration
- push notification orchestration for remote mode

Implementation stance:

- Rust async runtime with Tokio
- bounded channels only
- long-lived tasks only where required
- no unbounded replay structures

## Relay Design

### Why Rust relay is correct for V2

The relay is a systems component with:

- high connection concurrency
- simple but hot routing paths
- strict backpressure needs
- memory profile sensitivity
- remote presence correctness requirements

That makes Rust a better fit than Node for V2.

### External reference

The referenced project `missuo/remodex-relay` is a useful reference because it already proves:

- `tokio`
- `axum`
- Rust rate limiting
- Rust WebSocket relay path
- Rust APNs push path

But it is not yet a V2 end state.

Observed gaps relative to this repo's feature needs:

- no `trusted/device/connect` endpoint
- no pairing-code resolve endpoint
- no opaque reconnect path matching current app behavior
- still WebSocket-first in a way that tracks the old protocol too closely

So V2 should treat that repo as a code reference, not as the finished architecture.

### V2 relay target

V2 relay should support:

- remote rendezvous
- trusted-device resolution
- route candidate distribution
- binary frame forwarding
- strict per-session memory caps
- explicit backpressure signaling
- optional push sidecar behavior
- detailed per-session metrics

## Security

V2 should preserve the security bar while simplifying the wire protocol.

Requirements:

- end-to-end encryption between iPhone and Mac daemon
- relay cannot see plaintext prompts or code
- replay protection
- trust revocation
- rekey support
- short-lived pairing tokens

Possible approach:

- Noise-based authenticated handshake
- or mutually authenticated TLS profile
- session resumption tied to trusted identities
- monotonic counters or per-stream sequence tracking

Keep the security guarantees, not the current JSON representation.

## Performance Targets

V2 should be measured against explicit targets.

Suggested initial targets:

- warm relay reconnect after foreground return: within one reconnect handshake plus catch-up
- long-idle reconnect without rescanning: reliable and automatic
- first visible assistant delta after turn start: transport overhead kept to roughly one RTT budget on a good WAN path
- p99 relay memory per idle session: bounded and measurable
- reopen latency for recent active chats: under 150 ms after connection is already restored

## Files And Payloads

Large payload behavior should be redesigned.

Rules:

1. large images and diffs do not share a stream with control traffic
2. compression is explicit
3. chunking is explicit
4. catch-up can request metadata first and bodies second

Suggested choices:

- protobuf metadata
- zstd compression for replay batches
- dedicated binary streams for attachments and large tool output

## What V2 Deletes

V2 explicitly deletes these ideas from the primary architecture:

- separate local relay process as a mandatory dependency
- same-LAN-first discovery as a core requirement
- QR as the normal reconnect locator
- JSON-RPC as the mobile wire format
- rollout-file polling as a primary catch-up source
- reconnect truth spread across multiple UI layers
- text-framed secure envelopes
- compatibility shims for old parameter naming and old transport shapes

## Recommended V2 Codebase Split

Inside this `version 2.0` workspace, the long-term target should become:

- `mobile-ios/`
  - iOS app, new remote client
- `codexd/`
  - Rust Mac daemon
- `codex-relay-rs/`
  - Rust relay
- `proto/`
  - shared protobuf schemas
- `docs/`
  - protocol, pairing, reconnect, and performance specs

The copied legacy directories are only reference material.

## Recommendation

If we are optimizing for the best product fit rather than smallest migration:

1. Build `codex-relay-rs` early, not late.
2. Build `codexd` as a persistent remote daemon in Rust.
3. Make `WSS + relay + binary protocol + resumable event log` the default path.
4. Treat private overlay direct mode as an optional acceleration path.
5. Treat same-LAN as incidental, not central.

# V2 Remote-First Requirements

## Product Truth

The app exists to let a user control Codex running on a Mac that may be very far away.

That means:

- the primary scenario is not "same room"
- the primary scenario is not "same Wi-Fi"
- the primary scenario is not "temporary local pairing demo"

The primary scenario is:

- the user is on an iPhone
- the Mac is somewhere else
- the Mac is online
- the user wants to operate Codex remotely with low latency and reliable reconnect

## Non-Negotiable Requirements

1. After first trust bootstrap, the user must be able to reconnect from anywhere.
2. The system must not assume physical proximity to the Mac.
3. The system must not depend on same-LAN discovery as the main product path.
4. The default setup must not require the user to install a private overlay network.
5. A relay-backed remote path must always exist.
6. The app must reconnect automatically after app switching, idle time, and transient network loss.
7. The install path for App, relay, and daemon must stay simple.
8. Advanced users may opt into direct acceleration paths such as Tailscale / Headscale / WireGuard-class overlays.

## Route Priority

V2 should prefer routes in this order:

1. relay-backed default remote path
2. optional direct remote acceleration path when explicitly configured and proven better

This is the correct tradeoff for this product because:

- relay-backed WSS is the simplest universal setup
- outbound-only connectivity is easy for both Mac and iPhone
- advanced direct routing can be layered on later without making first install harder

## What This Rules Out

These approaches are misaligned with the product:

- designing the stack around same-Wi-Fi discovery first
- requiring Tailscale-class software for normal use
- requiring a fresh QR scan whenever the route changes
- making reconnect depend on a LAN host baked into the QR
- optimizing only for minimum theoretical latency while hurting setup simplicity

## Correct V2 Framing

The correct framing is:

- remote-first control plane
- relay-backed default transport
- remote-first reconnect
- resumable session model
- optional direct acceleration

If a design choice improves theoretical transport latency but makes installation, reconnect, or remote reachability worse, it is the wrong default for V2.

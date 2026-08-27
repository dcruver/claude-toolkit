---
type: Class
title: RouteRegistry
description: Resolves and caches IntegrationRoute definitions by matrix room id.
resource: /src/route/RouteRegistry.java
tags: [routing, cache]
status: stable
generated:
  by: claude-code/opus-5
  at: 2026-08-26T14:02:11Z
verified:
  - by: process:okf/0.2
    at: 2026-08-26T15:00:00Z
  - by: human:dcruver
    at: 2026-08-26T16:40:00Z
stale_after: 2026-11-24T00:00:00Z
sources:
  - resource: https://example.invalid/DON-86
    id: don-86
    title: Move kairos-agent into integration/
code:
  language: java
  symbol: com.kairos.route.RouteRegistry
  kind: class
  visibility: public
  lines: [8, 19]
  signature: "public final class RouteRegistry implements RouteSource"
  extends: []
  implements: ["/src/route/RouteSource"]
  members:
    - {name: register, signature: "public void register(Route)", lines: [11, 13]}
    - {name: resolve, signature: "public Optional<Route> resolve(String)", lines: [15, 18]}
  fan_in: 14
  tier: 2
  content_hash: "sha256:e36b6b992dae1387b2cc894187355b3556b3ca483e4670efa7283ce08c88fa19"
  commit: "0b94c63"
---

# Responsibilities

Holds the registered routes for a deployment and answers which one serves a
given matrix room.

# Collaborators

- [RouteSource](/src/route/RouteSource) — the interface this satisfies.

# Methods

## public void register(Route)

Adds a route, replacing any route already registered for the same room.

## public Optional<Route> resolve(String)

Returns the route for a room, or empty when none is registered.

---
type: Class
title: Router
description: Chooses the handler for an inbound request path.
resource: /src/kitchen/Router.java
tags: [routing]
status: stable
generated:
  by: claude-code/opus-5
  at: 2026-08-26T14:02:11Z
code:
  language: java
  symbol: com.example.kitchen.Router
  kind: class
  visibility: public
  lines: [6, 26]
  signature: "public final class Router"
  members:
    - {name: add, signature: "public void add(String, Handler)", lines: [14, 16]}
    - {name: route, signature: "public Handler route(String)", lines: [18, 21]}
    - {name: size, signature: "public int size()", lines: [23, 25]}
  tier: 1
  content_hash: "sha256:a8333c1eb70ab7901dbaa5e04ff81994d438e05c414870972b38932b4bcfc698"
  commit: "0b94c63"
---

# Responsibilities

Holds the handlers registered for a deployment and answers which one serves a
given request path.

# Collaborators

- [RouteKey](/src/kitchen/RouteKey) — the key a caller builds a path from.

# Methods

## public void add(String, Handler)

Registers a handler, replacing any handler already registered for the same
path.

## public Handler route(String)

Returns the handler registered for a path, or the fallback the router was
built with when no handler is registered for it.

## public int size()

How many paths are registered. Counts paths and not handlers: one handler
registered under two paths counts twice.

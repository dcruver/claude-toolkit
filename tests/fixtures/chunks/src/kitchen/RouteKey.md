---
type: Record
title: RouteKey
description: The path and verb a handler is registered under.
resource: /src/kitchen/RouteKey.java
status: stable
generated:
  by: claude-code/opus-5
  at: 2026-08-26T14:02:11Z
verified:
  - by: human:dcruver
    at: 2026-08-26T16:40:00Z
code:
  language: java
  symbol: com.example.kitchen.RouteKey
  kind: record
  visibility: public
  lines: [3, 3]
  signature: "public record RouteKey(String path, String verb)"
  tier: 1
  content_hash: "sha256:8fc80abe12c00b8bf4b265779b018f2aef837d5280d24d2d01f8ace8c8efa080"
---

# Responsibilities

Identifies one registered route, so two routes differing only in verb are two
keys and not one.

# Schema

| Field | Type | Notes |
|---|---|---|
| `path` | `String` | The request path, leading slash included. |
| `verb` | `String` | The HTTP method, upper case. |

Both components are required; neither may be null.

# Examples

A key as it is spelled in the route table:

```json
{"path": "/health", "verb": "GET"}
```

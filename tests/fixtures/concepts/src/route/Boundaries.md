---
type: Record
title: Boundaries
description: A deliberately awkward block — every line in it that looks like a field the shell reads is one the shell must not read. Not a template.
sources:
  - resource: https://example.invalid/DON-91
    id: don-91
    title: Give Route its own accessors
    status: proposed
    at: 2019-04-02T00:00:00Z
resource: /src/route/Boundaries.java  # a trailing comment is not part of a path
generated:
  window:
    at: 2019-04-02T00:00:00Z
  by: claude-code/opus-5
  at: 2026-08-26T14:02:11Z
verified:
- at: 2026-08-27T09:00:00Z
  by: process:okf/0.2
  context:
    at: 2001-01-01T00:00:00Z
- by: human:dcruver
  context:
    at: 2002-01-01T00:00:00Z
  evidence:
    - at: 2003-01-01T00:00:00Z
  at: 2026-08-27T10:00:00Z
- by: process:okf/0.2
- at: 2026-08-27T11:00:00Z
  at: 2026-08-27T12:00:00Z
  by: process:okf/0.2
code:  # a comment does not stop a bare header opening its block
  members:
    - {name: symbol, signature: "public String symbol()", lines: [4, 4]}
    - {name: language, signature: "public String language()", lines: [4, 4]}
    - {name: tier, signature: "public int tier()", lines: [4, 4]}
  supersedes:
    symbol: com.kairos.route.OldBoundaries
    tier: 3
    language: kotlin
    content_hash: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
  language: java
# a whole-line comment is not a top-level key, so it does not end this block
  content_hash: "sha256:52f70d8e08c013253274deae575fa6f3e725ed5bd9ae6705c4b15714b9119645"  # regenerate after the refactor
status: stable
tier: 99
symbol: not.the.code.symbol
status: draft
review:
  symbol: still.not.the.code.symbol
  tier: 7
  language: kotlin
  at: 2001-01-01T00:00:00Z
  by: nobody@example.invalid
---

# Responsibilities

Carries a route's symbol and language, which is why its members are named after
OKF's own fields.

---
type: Class
title: Fenced
description: A deliberately awkward body — every line in it that looks like a SPEC.md §4 heading is one the splitter must not cut on. Not a template.
resource: /src/kitchen/Fenced.java
status: draft
generated:
  by: claude-code/opus-5
  at: 2026-08-26T14:02:11Z
code:
  language: java
  symbol: com.example.kitchen.Fenced
  kind: class
  visibility: public
  signature: "public final class Fenced"
  members:
    - {name: render, signature: "public String render()", lines: [4, 6]}
  tier: 1
  content_hash: "sha256:f4cba5a57e03a82d04f5a7fb835c6f02bf456c87d03cb5596ce64571ab77dbd5"
---

# Responsibilities

Returns one fenced block, verbatim, which is why this concept quotes so many
of them.

# Collaborators

- [Router](/src/kitchen/Router) — quotes the block back, which is why this
  bullet carries it indented under itself:

  ~~~markdown
  # Schema

  ## public String stillNotAMethod()
  ~~~

Markdown lets a fence itself sit up to three spaces in, and what is inside one
is content wherever it starts — including at column 0:

   ```markdown
# Schema

## public String alsoNotAMethod()
   ```

# Methods

## public String render()

The block it returns, as it comes back:

```markdown
# Schema

## public String notAMethod()
```

Everything between those fences is a string, not a heading.

# Examples

The same block again, fenced with tildes so that a backtick fence inside it is
content too, and closed by a longer run than the one that opened it:

~~~
# Methods

```
# Schema
```
~~~~~

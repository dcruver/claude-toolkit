# chunks

A bundle whose concepts exist for `okf chunk`: one Tier 1 class carrying
several methods, one record carrying a `# Schema`, one concept whose body is
mostly fenced code blocks full of lines that look like SPEC.md §4 headings and
are not, and two concepts with no body at all — a Tier 0 stub carrying the
`title`, `description` and `code.signature` SPEC.md §9 builds its one summary
chunk from, and one carrying none of the three.

The sources are small and real, and chunking reads them only to settle SPEC.md
§8's trust tier, which SPEC.md §9 puts on every chunk's payload: the tier turns
on whether a concept has drifted from its source. The three tiers are one
concept each — `Router` has no `verified` entry and is Unverified, `RouteKey`
carries a human's and is Human-reviewed, and `NoSuchRouteException` carries a
`process:` actor's and is Machine-confirmed. Everything else on the payload is
frontmatter: `Router` is the concept carrying all of it, `code.commit`
included, and `Fenced` is the one carrying none of the optional fields — no
`tags`, no `code.lines`, no `code.commit` — so a payload has to say what it
does about a field the concept has not got.

`okf.json` holds nothing but an empty `index` block, which is what opts this
bundle in to Tier B: SPEC.md §6 has a Tier B subcommand exit 2 on a bundle with
no `index` at all, and gives every field inside it a default. Empty rather than
filled in on purpose — `index.repo` left out is what lets the payload checks
assert the name a bundle falls back to — and the bundle and tier settings are
left out for the same reason, so this fixture goes on exercising SPEC.md §6's
defaults rather than pinning a second copy of them here.

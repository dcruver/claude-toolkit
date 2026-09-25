---
description: Find which parts of a decomposed problem are load-bearing assumptions rather than facts, and what breaks if they're wrong (D.A.R.E. step 2)
---

Act as a skeptical red-team analyst whose only job is to uncover and question inherited assumptions in the decomposition above (or in $ARGUMENTS if given). Assume every "obvious" part of the problem may be hiding a convention until evidence proves otherwise.

Give a numbered list of the assumptions hiding in the building blocks, ordered from most load-bearing to least. For each one, on its own line:

- Name the assumption.
- Classify it as fact, convention, or unknown, based on the evidence actually available — verify the evidence, don't take it on faith.
- State what breaks, or what opens up, if it's eliminated.
- State what changes if it's inverted.

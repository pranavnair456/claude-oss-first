# Third-party components

<!--
The project's provenance ledger. One row per component, added *before* the
component lands, not after. Adapted from the LICENSES.md pattern: a table
whose "Commercial" column is a gate, and whose "Blocked" status means do not
import it.

Keep this as one file. A second ledger somewhere else is how a component ends
up in neither.
-->

This is a commercial product. Every library, model, weight file and bundled
binary is recorded here before it is adopted, with its licence and whether
commercial use is permitted. **Blocked** means do not import it.

| Component | Use | Upstream | Pinned | License | Commercial | Vetted | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| example-lib | what it does here | github.com/owner/repo | v1.2.3 / `abc1234` | MIT | Yes | 2026-01-01 PASS | In use; replaced the hand-written X |
| example-weights | which model path | github.com/owner/repo | `nmp.onnx`, 230 444 B, sha256 `2c3c…` | Apache-2.0 (code **and** weights) | Yes | 2026-01-01 PASS | In use; sha256 checked at load |
| example-blocked | what it would have done | github.com/owner/repo | — | CC BY-NC 4.0 | **No** | 2026-01-01 DENY | **Blocked** pending a permissively licensed alternative |

Before any weight file or vendored artifact lands in the repo or the cache, add
it here with a link to its licence text.

## How a component gets added

1. `/oss-scout` — is it needed at all, and is there something better?
2. `/oss-vet` — quarantine clone and the security suite. A `deny` licence or a
   FAIL verdict ends it here.
3. `/oss-adopt` — wire it in, delete what it replaces, verify with the full
   gate, then add the row above.

A `review` licence with no recorded decision is an open question, not an
approval. Run `collect-licenses.py --against` against this file to check it
still matches the resolved dependency set.

## Licence notes that decide things

Record the reasoning, not just the identifier, wherever the answer depends on
how the component is used:

- **Code and weights are graded separately.** Permissive code does not grant
  rights to the checkpoints, and the checkpoints are what ships. Where upstream
  is silent on weights, say so explicitly as an accepted risk rather than
  leaving the row implying a grant that was never made.
- **LGPL** is fine dynamically linked and a problem statically linked into a
  shipped binary. State which applies.
- **GPL** run on your own server is use, not distribution. Shipping a binary
  containing it is distribution. Invoking it as a separate executable over a
  pipe is not linking. State which situation this is.
- **Attribution** is an obligation even under MIT. Say where the notice ships.

## Server-side and bundled dependencies

Where the hosted images or a packaged desktop app pull in something the
lockfiles do not describe — a system binary, a base image, a proprietary
runtime redistributable — record it here too, with the obligation that attaches
to *distributing* it as opposed to *using* it.

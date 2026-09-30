---
description: Find, vet and adopt existing open source for a capability instead of building it
argument-hint: what you need (e.g. "permissively licensed downbeat tracker")
---

Run the full OSS-first pipeline for: **$ARGUMENTS**

Work through all four stages in order, using the `oss-scout`, `oss-vet` and
`oss-adopt` skills. Do not skip ahead, and stop at any stage whose verdict says
stop.

1. **Scout** — `oss-scout`. Search read-only, score candidates, and return an
   explicit build-vs-adopt call. Nothing is cloned in this stage.
2. **Vet** — `oss-vet`, for the chosen candidate only. Quarantine clone, then
   the security suite. A FAIL ends the pipeline; a REVIEW needs findings read
   and a decision stated before continuing.
3. **Adopt** — `oss-adopt`, only if stage 2 cleared. Wire it in, delete what it
   replaces, verify with the project's own full test gate, and record
   provenance in the project ledger.

If the honest answer is "build it", say so at stage 1 with the reason, and stop.
That is a successful outcome, not a failed search.

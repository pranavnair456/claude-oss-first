---
description: Wire a vetted component into the project, verify it, and record its provenance
argument-hint: owner/repo or quarantine path, plus what it should replace
---

Use the `oss-adopt` skill for: **$ARGUMENTS**

Confirm the component has cleared `oss-vet` first. Then decide
dependency-vs-vendor and say why, wire it behind the seam the project already
uses, and delete the code it replaces.

Verify with the project's own full gate — not just a new test — and paste the
output. Then append the provenance row (upstream URL, pinned commit, sha256 for
any binary, licence, commercial verdict, vet date, what it replaced) to the
project's existing ledger.

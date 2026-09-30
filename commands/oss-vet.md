---
description: Quarantine-clone a repo and run the free security suite over it
argument-hint: owner/repo [ref], or a path already in quarantine
---

Use the `oss-vet` skill on: **$ARGUMENTS**

Clone into the quarantine at `~/.claude/oss-sandbox` with
`scripts/sandbox-clone.sh`, then run `scripts/security-scan.sh` over it.

Nothing in quarantine is built, installed or executed — a hook enforces this.
If a check could not run, say so: a skipped check is not a pass.

Report the verdict first, then the findings that drove it, then a one-line
recommendation. For a REVIEW, say which findings are real and which are noise,
with your reasoning.

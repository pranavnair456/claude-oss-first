---
description: Research existing open source for a capability, read-only, no cloning
argument-hint: the capability you need, or an owner/repo to score
---

Use the `oss-scout` skill to research: **$ARGUMENTS**

Read-only. Nothing is cloned and nothing is written to disk — use `gh api` to
read READMEs, licences and manifests directly.

If the argument looks like `owner/repo`, score those repos. Otherwise treat it
as a capability description and search for candidates.

End with a build-vs-adopt recommendation, what adopting would replace, and one
line on why each rejected candidate lost.

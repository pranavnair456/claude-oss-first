---
name: oss-adopt
description: Use after a repo or package has cleared oss-vet and is being wired into a project - integrating a library, vendoring or porting upstream code, adding a dependency, or bundling model weights. Decides vendor-vs-dependency, wires it to the real stack, verifies end to end with the project's own test gate, and records provenance (upstream URL, pinned commit, sha256, licence, what it replaced) in the project ledger. Triggers on "add this dependency", "integrate this library", "vendor this code", "wire it in", "adopt".
---

# OSS adopt

Stage 4 of four. Vetting said the code is safe to use; this stage makes it
part of the project and leaves a record of how it got there.

**Precondition:** `oss-vet` returned PASS, or returned REVIEW and the findings
were read and a decision recorded. Never adopt on an unread REVIEW, and never
adopt a FAIL.

## Step 1 — Dependency or vendored code?

Take the dependency by default. Vendoring is a commitment to maintain a fork.

Vendor only when one of these is true, and say which:

- You need a few functions out of a large tree and do not want the tail.
- Upstream is unmaintained, so there are no updates to miss.
- The package is not published to any registry.
- You have to modify it to fit, and the modification is not upstreamable.

If you vendor, then: copy only what is used, keep the upstream licence text
alongside it, and **put attribution in the module docstring of every ported
file** naming the upstream file it came from. A reader who opens one file
should learn its provenance without leaving it.

If you take the dependency, pin it. A floating range is a decision to accept
whatever upstream ships next.

## Step 2 — Wire it to the stack that exists

Read the surrounding code first and match it. Specifically:

- Put it behind the seam the project already uses for this kind of thing
  (a backend registry, a strategy interface, an adapter) rather than importing
  it at a dozen call sites.
- **Keep a fallback if the project has fallbacks.** Heavy or optional
  dependencies usually earn an import inside the function rather than at module
  scope, so an install without the extra still runs.
- Match the error handling, logging and typing conventions of the module you
  are editing.
- Delete the code this replaces. An adoption that leaves the hand-written
  version behind has added a dependency and removed nothing.

## Step 3 — Verify end to end, and only then claim it works

In this order:

1. **The project's own full gate** — lint, types, tests, whatever CI runs. Not
   just the new test. Run it and read the output.
2. **A test that fails without the new component.** If nothing breaks when it
   is removed, it is not wired in.
3. **The real path, not just the unit test.** Run the app or the pipeline on
   real input and check the output is right, not merely non-crashing.
4. **A security scan of the resulting diff**, not just the upstream repo: a new
   dependency brings a new transitive set.
5. For anything shipped: confirm the licence obligations are actually
   discharged — notice files present, dynamic linking preserved where the
   licence requires it.

State results with the command output. "Tests pass" without having run them is
the failure mode this step exists to prevent.

## Step 4 — Record the provenance

Append a row to the project's ledger (`LICENSES.md`, `THIRD_PARTY.md`, or
whatever it uses — find it, do not invent a second one). The row needs:

| Field | Why |
|---|---|
| Component and what it is used for | so a reader knows why it is here |
| Upstream URL | so the primary source is checkable |
| Pinned version, tag or commit sha | so "which one" has an answer |
| sha256 and byte count, for any binary or weight | so the file can be verified at load |
| Licence, and the weights licence separately | because they differ |
| Commercial use permitted: yes / no | the question that actually blocks things |
| Vet date and verdict | so staleness is visible |
| What it replaced | the don't-rebuild rule, made auditable |

For anything substantial, also write an adoption record from
`${CLAUDE_PLUGIN_ROOT}/templates/adoption-record.md`: what was evaluated, what
was taken, **what was deliberately not taken**, and the deviations from
upstream. The "not adopted" list is the part future readers need most.

Use `${CLAUDE_PLUGIN_ROOT}/templates/notice.md` for a vendored artifact, and
`${CLAUDE_PLUGIN_ROOT}/scripts/collect-licenses.py --against <ledger>` to check
the ledger still matches the resolved dependency set afterwards.

## Step 5 — Release the quarantine

Once the ledger row exists and the hashes are recorded, the quarantined clone
is disposable. Say so; leave deleting it to the user.

## Red flags

| Thought | Reality |
|---|---|
| "I'll add the ledger row later" | Later is never. The row is part of the change. |
| "Tests probably pass" | Run them. Paste the output. |
| "I'll vendor it, simpler" | It is simpler today and a fork forever. Justify it. |
| "The old implementation can stay for now" | Then you added a dependency for nothing. |
| "MIT, nothing to discharge" | Attribution is still an obligation. Weights are still separate. |
